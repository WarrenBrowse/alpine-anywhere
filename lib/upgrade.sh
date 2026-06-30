#!/bin/sh
# upgrade.sh - A/B upgrade management for alpine-anywhere
#
# Atomic upgrades for the raw-partition squashfs A/B layout (see docs/BOOT.md):
#   sda1  boot       - vmlinuz-A/B, initramfs-A/B, current_slot, slots.meta, and
#                      the bootloader config(s): extlinux.conf (BIOS) + grub/
#                      (UEFI) on x86; config.txt/cmdline.txt on RPi
#   sda2  slot A     - raw squashfs root image
#   sda3  slot B     - raw squashfs root image
#   sda4  data       - persistent overlay (optional)
#   (last) esp       - FAT EFI System Partition, x86 UEFI only
#
# Upgrade flow: build new image -> write to the INACTIVE slot -> point the
# bootloader at it -> reboot. The previous slot is preserved for rollback.
#
# Depends on functions from install.sh (sourced before this file):
#   slot_to_partnum, get_part_dev, place_slot_kernel, install_boot_config,
#   generate_system_squashfs, DETECTED_PLATFORM

# =============================================================================
# Constants
# =============================================================================

BOOT_MNT="/mnt/aa-boot"
# A slot that boots into the OS but fails to reach the verified/healthy state
# rolls back after this many unverified boots. 1 = give it a single retry then
# roll back (a healthy slot self-verifies on its first boot, count 0->1->reset).
MAX_BOOT_ATTEMPTS=1

# Append a timestamped line to the persistent A/B log on the boot partition
# (requires BOOT_MNT mounted). Also echoes to stderr. This is the breadcrumb
# trail for debugging boots/upgrades/rollbacks after the fact.
aa_log() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null) || ts="up$(cut -d. -f1 /proc/uptime 2>/dev/null)s"
    echo "aa[$ts] $*" >&2
    if [ -d "$BOOT_MNT" ]; then
        echo "[$ts] $*" >> "${BOOT_MNT}/aa.log" 2>/dev/null
        sync 2>/dev/null || true
    fi
}

# =============================================================================
# Disk / boot partition discovery
# =============================================================================

# Strip the partition suffix from a device path:
#   /dev/sda3 -> /dev/sda   /dev/nvme0n1p3 -> /dev/nvme0n1   /dev/mmcblk0p3 -> /dev/mmcblk0
strip_partition() {
    case "$1" in
        *p[0-9])      echo "${1%p[0-9]}" ;;
        *p[0-9][0-9]) echo "${1%p[0-9][0-9]}" ;;
        *[0-9])       echo "$1" | sed 's/[0-9]*$//' ;;
        *)            echo "$1" ;;
    esac
}

# Device the running system was booted from (root=... in the kernel cmdline).
# x86_64 slots boot with root=PARTUUID=..., which busybox cannot resolve to a
# /dev node (no PARTUUID support) — strip_partition on the raw tag would yield
# garbage and mount_boot then fails. The running immutable root IS a squashfs
# mounted from the slot partition, so its source is the real device we booted;
# use that for any tag-style (or absent) root. Paths are overridable for tests.
get_root_device() {
    local cmdline="${AA_CMDLINE_FILE:-/proc/cmdline}" mounts="${AA_MOUNTS_FILE:-/proc/mounts}" r s
    r=$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' "$cmdline" 2>/dev/null | head -n1)
    case "$r" in
        ""|PARTUUID=*|UUID=*|LABEL=*)
            s=$(awk '$3=="squashfs"{print $1; exit}' "$mounts" 2>/dev/null)
            [ -n "$s" ] && { echo "$s"; return; }
            s=$(findmnt -no SOURCE /media/root-ro 2>/dev/null)
            [ -n "$s" ] && { echo "$s"; return; }
            ;;
    esac
    echo "$r"
}

# Whole disk that holds the install (derived from the running root device)
get_boot_disk() {
    local rootdev
    rootdev=$(get_root_device)
    [ -n "$rootdev" ] || rootdev=$(findmnt -no SOURCE /media/root-ro 2>/dev/null)
    [ -n "$rootdev" ] || die "Cannot determine root device from cmdline"
    strip_partition "$rootdev"
}

# Is $BOOT_MNT currently a mountpoint? (busybox-safe, no `mountpoint` dependency)
boot_is_mounted() {
    grep -q " ${BOOT_MNT} " /proc/mounts 2>/dev/null
}

# Mount the FAT boot partition (partition 1) at $BOOT_MNT
mount_boot() {
    local disk part1
    disk=$(get_boot_disk)
    part1=$(get_part_dev "$disk" 1)
    mkdir -p "$BOOT_MNT"
    if ! boot_is_mounted; then
        mount "$part1" "$BOOT_MNT" || die "Cannot mount boot partition $part1"
    fi
}

umount_boot() {
    sync
    if boot_is_mounted; then umount "$BOOT_MNT" || true; fi
}

# =============================================================================
# Slot Management
# =============================================================================

# Currently active slot. The running root device is authoritative; the
# current_slot marker file is only a fallback (e.g. when run off-device).
get_current_slot() {
    local disk root
    disk=$(get_boot_disk 2>/dev/null) || disk=""
    root=$(get_root_device)

    if [ -n "$disk" ] && [ -n "$root" ]; then
        if [ "$root" = "$(get_part_dev "$disk" 2)" ]; then echo A; return; fi
        if [ "$root" = "$(get_part_dev "$disk" 3)" ]; then echo B; return; fi
    fi
    cat "${BOOT_MNT}/current_slot" 2>/dev/null || echo A
}

get_inactive_slot() {
    if [ "$(get_current_slot)" = "A" ]; then echo B; else echo A; fi
}

# =============================================================================
# Slot metadata (KEY=VALUE in $BOOT_MNT/slots.meta, keys SLOT_<slot>_<NAME>)
# =============================================================================

get_slot_meta() {
    local slot="$1" key="$2"
    grep "^SLOT_${slot}_${key}=" "${BOOT_MNT}/slots.meta" 2>/dev/null | cut -d= -f2-
}

set_slot_meta() {
    local slot="$1" key="$2" value="$3"
    local meta="${BOOT_MNT}/slots.meta"
    local full="SLOT_${slot}_${key}"
    touch "$meta"
    # Rebuild the whole file in one pass and write it atomically (tmp+fsync+
    # rename+dir sync). The previous "grep -v > tmp; mv; then >> append" had a
    # window where a crash between the mv and the append lost the key entirely,
    # and never fsync'd - dangerous on the FAT boot partition under power loss.
    { grep -v "^${full}=" "$meta" 2>/dev/null || true; echo "${full}=${value}"; } \
        | atomic_write "$meta"
}

# Remove all dm-verity metadata for a slot (used when (re)installing a
# non-verity image where a previous verity install left stale keys behind).
clear_slot_verity_meta() {
    local slot="$1"
    local meta="${BOOT_MNT}/slots.meta"
    [ -f "$meta" ] || return 0
    grep -vE "^SLOT_${slot}_(ROOT_HASH|SALT|DATA_SIZE|HASH_OFFSET|ROOT_HASH_SIG)=" "$meta" \
        | atomic_write "$meta"
}

# Set a non-slot (global) key in slots.meta, e.g. ROLLBACK_COUNT / BOOT_HALTED.
set_global_meta() {
    local key="$1" value="$2"
    local meta="${BOOT_MNT}/slots.meta"
    touch "$meta"
    { grep -v "^${key}=" "$meta" 2>/dev/null || true; echo "${key}=${value}"; } \
        | atomic_write "$meta"
}

# =============================================================================
# Upgrade Process
# =============================================================================

# Build a fresh system image and write it to the given (inactive) slot,
# including that slot's kernel + initramfs on the boot partition.
install_to_slot() {
    local target_slot="$1"
    local version="${2:-$ALPINE_VERSION}"

    local disk partnum slot_dev
    disk=$(get_boot_disk)
    partnum=$(slot_to_partnum "$target_slot")
    slot_dev=$(get_part_dev "$disk" "$partnum")

    log_step "Building Alpine $version for slot $target_slot..."

    # generate_system_squashfs writes the image and stashes the matching
    # kernel/initramfs under /tmp/boot-files (applies all customization hooks).
    local squashfs="/tmp/system-${target_slot}.squashfs"
    generate_system_squashfs "$squashfs"

    log_step "Writing image to slot $target_slot ($slot_dev)..."
    local slot_sha slot_vmeta=""
    if verity_enabled; then
        slot_vmeta=$(format_verity_slot "$squashfs" "$slot_dev")
        slot_sha=$(sha256_file "$squashfs")
    else
        slot_sha=$(write_image_to_device "$squashfs" "$slot_dev")
    fi
    log_info "Slot $target_slot written: $(du -h "$squashfs" | cut -f1)"

    # Per-slot kernel on the boot partition (rollback-safe: kernel + userspace
    # stay paired even if the kernel version differs between slots).
    place_slot_kernel "$BOOT_MNT" "$target_slot" \
        "/tmp/boot-files/vmlinuz" "/tmp/boot-files/initramfs"

    set_slot_meta "$target_slot" "VERSION" "$version"
    set_slot_meta "$target_slot" "INSTALLED" "$(date -Iseconds)"
    set_slot_meta "$target_slot" "BOOT_COUNT" "0"
    set_slot_meta "$target_slot" "VERIFIED" "false"
    set_slot_meta "$target_slot" "SHA256" "$slot_sha"
    if [ -n "$slot_vmeta" ]; then
        set -- $slot_vmeta
        set_slot_meta "$target_slot" "ROOT_HASH" "$1"
        set_slot_meta "$target_slot" "SALT" "$2"
        set_slot_meta "$target_slot" "DATA_SIZE" "$3"
        set_slot_meta "$target_slot" "HASH_OFFSET" "$4"
    else
        # Non-verity image: drop any stale verity metadata from a prior verity
        # install of this slot, so `switch` won't spuriously add aaverity=1.
        clear_slot_verity_meta "$target_slot"
    fi

    rm -f "$squashfs"
    rm -rf /tmp/boot-files
    log_info "Slot $target_slot ready (Alpine $version)"
}

# Point the bootloader at a slot by editing the EXISTING boot config in place.
# Runs on the installed device, so it must not depend on build-time vars like
# DETECTED_PLATFORM — it detects the bootloader from the files actually present.
switch_slot() {
    local new_slot="$1"
    local disk slot_dev partnum
    disk=$(get_boot_disk)
    partnum=$(slot_to_partnum "$new_slot")
    slot_dev=$(get_part_dev "$disk" "$partnum")

    log_step "Switching boot to slot $new_slot..."

    # Per-slot verity: enable aaverity=1 iff THIS slot was built with dm-verity
    # (its slots.meta carries a ROOT_HASH). This is detected from the on-disk
    # metadata, not a build-time flag, so `switch` does the right thing for a
    # verity slot regardless of how it is invoked.
    local kopts="$SLOT_KERNEL_OPTS"
    if [ -n "$(get_slot_meta "$new_slot" ROOT_HASH)" ]; then
        kopts="$kopts aaverity=1"
        log_info "Slot $new_slot is dm-verity protected; adding aaverity=1"
    fi

    if [ -f "${BOOT_MNT}/config.txt" ]; then
        # Raspberry Pi: select the slot's kernel/initramfs + root device.
        # Patterns are ANCHORED to the slot letter ([AB]) so a trailing comment
        # or a partial match can't eat the rest of the line, and the post-edit
        # state is verified - a no-op edit (slot not actually switched) would
        # otherwise leave the bootloader pointing at the old slot after an
        # upgrade: a brick path. Atomic write protects the FAT partition.
        sed_inplace_checked "${BOOT_MNT}/config.txt" "^kernel=vmlinuz-${new_slot}\$" \
            -e "s|^kernel=vmlinuz-[AB].*|kernel=vmlinuz-${new_slot}|" \
            -e "s|^initramfs initramfs-[AB].*|initramfs initramfs-${new_slot} followkernel|"
        printf 'root=%s %s\n' "$slot_dev" "$kopts" | atomic_write "${BOOT_MNT}/cmdline.txt"
    elif [ -f "${BOOT_MNT}/extlinux/extlinux.conf" ]; then
        sed_inplace_checked "${BOOT_MNT}/extlinux/extlinux.conf" "^DEFAULT alpine-${new_slot}\$" \
            -e "s|^DEFAULT alpine-[AB].*|DEFAULT alpine-${new_slot}|"
        # Mirror the flip for UEFI/GRUB (same boot partition; no-op without an ESP).
        [ -d "${BOOT_MNT}/grub" ] && \
            printf 'set default=alpine-%s\n' "$new_slot" | atomic_write "${BOOT_MNT}/grub/grub_aa_default.cfg"
    else
        die "No known bootloader config on ${BOOT_MNT} (config.txt / extlinux.conf)"
    fi
    # Only flip current_slot AFTER the bootloader config was confirmed changed.
    printf '%s\n' "$new_slot" | atomic_write "${BOOT_MNT}/current_slot"
    sync
    aa_log "switch: boot slot set to $new_slot (root=${slot_dev})"
    log_info "Boot slot switched to $new_slot (reboot to activate)"
}

# =============================================================================
# Rollback Support
# =============================================================================

# Mark the running slot as known-good (call after a successful boot)
verify_current_slot() {
    mount_boot
    local current
    current=$(get_current_slot)
    set_slot_meta "$current" "VERIFIED" "true"
    set_slot_meta "$current" "BOOT_COUNT" "0"
    # A healthy, operator-confirmed boot clears the global rollback guard so a
    # future genuine failure gets a fresh retry budget (and lifts any halt).
    set_global_meta "ROLLBACK_COUNT" "0"
    set_global_meta "BOOT_HALTED" "0"
    aa_log "verify: slot $current marked VERIFIED, boot_count + rollback guard reset"
    umount_boot
    log_info "Slot $current marked verified"
}

# Increment the boot counter for the running slot; roll back if it keeps
# failing without being verified. Intended to run from the early boot guard.
increment_boot_counter() {
    mount_boot
    local current count verified
    current=$(get_current_slot)
    count=$(get_slot_meta "$current" "BOOT_COUNT")
    count=$((${count:-0} + 1))
    set_slot_meta "$current" "BOOT_COUNT" "$count"
    verified=$(get_slot_meta "$current" "VERIFIED")
    aa_log "bootcount: slot=$current root=$(get_root_device) count=$count verified=$verified max=$MAX_BOOT_ATTEMPTS"

    if [ "$count" -gt "$MAX_BOOT_ATTEMPTS" ] && [ "$verified" != "true" ]; then
        aa_log "bootcount: slot $current exceeded ($count>$MAX_BOOT_ATTEMPTS) unverified -> ROLLBACK"
        log_warn "Slot $current failed $count boots without verify; rolling back"
        rollback_slot
        return
    fi
    aa_log "bootcount: slot $current ok to proceed (count=$count)"
    umount_boot
}

# Switch back to the other slot and reboot
rollback_slot() {
    mount_boot
    local current previous prev_ver
    current=$(get_current_slot)
    previous=$(get_inactive_slot)

    prev_ver=$(get_slot_meta "$previous" "VERSION")
    if [ -z "$prev_ver" ]; then
        aa_log "rollback: ABORTED — slot $previous has no installed image"
        umount_boot
        log_error "Cannot roll back: slot $previous has no installed image"
        return 1
    fi

    aa_log "rollback: $current -> $previous"
    log_warn "Rolling back: $current -> $previous"
    switch_slot "$previous"
    umount_boot
    log_info "Rolled back to slot $previous. Rebooting..."
    # Force the reboot(2) syscall directly via busybox: rollback can run from the
    # PID 1 boot-guard shim (before the real init), where the normal /sbin/reboot
    # (now wired to s6-linux-init-shutdownd) has no shutdownd fifo to talk to yet.
    # busybox `reboot -f` bypasses init entirely. Fallbacks cover odd images.
    busybox reboot -f 2>/dev/null || reboot -f 2>/dev/null || reboot
}

# =============================================================================
# Upgrade Command
# =============================================================================

run_upgrade() {
    local version="${1:-$ALPINE_VERSION}"
    local current target

    mount_boot
    current=$(get_current_slot)
    target=$(get_inactive_slot)

    log_step "Upgrading to Alpine $version"
    log_info "Active slot:  $current ($(get_slot_meta "$current" VERSION || echo unknown))"
    log_info "Target slot:  $target"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would build $version into slot $target and switch to it"
        umount_boot
        return 0
    fi

    if [ "$FORCE" != "true" ]; then
        echo ""
        echo "This will build Alpine $version into slot $target and switch boot to it."
        echo "Slot $current is preserved for rollback."
        echo ""
        confirm_action "Proceed with upgrade?"
    fi

    install_to_slot "$target" "$version"
    switch_slot "$target"
    umount_boot

    echo ""
    echo "=========================================="
    echo "         UPGRADE COMPLETE"
    echo "=========================================="
    echo ""
    echo "Alpine $version installed to slot $target."
    echo "Reboot to activate:  reboot"
    echo ""
    echo "After a successful boot, confirm it:  aa verify"
    echo "If slot $target fails to boot ${MAX_BOOT_ATTEMPTS}x, it auto-rolls back to slot $current."
    echo ""
}

# =============================================================================
# Status Command
# =============================================================================

show_status() {
    mount_boot
    local running boot_slot boot_root
    running=$(get_current_slot)                                    # slot we're executing
    boot_slot=$(cat "${BOOT_MNT}/current_slot" 2>/dev/null || echo "?")   # slot configured for next boot
    # Next-boot root= lives in cmdline.txt (RPi bootloader) OR extlinux.conf
    # (x86/extlinux). Read whichever exists; never abort (set -e) when the
    # RPi-style file is absent on an extlinux host (this is what made `aa status`
    # exit 1 with no output on the bare-metal exit).
    local boot_cfg=""
    [ -f "${BOOT_MNT}/cmdline.txt" ] && boot_cfg="${BOOT_MNT}/cmdline.txt"
    [ -z "$boot_cfg" ] && [ -f "${BOOT_MNT}/extlinux/extlinux.conf" ] && boot_cfg="${BOOT_MNT}/extlinux/extlinux.conf"
    boot_root=""
    [ -n "$boot_cfg" ] && boot_root=$(sed -n 's/.*\(root=[^ ]*\).*/\1/p' "$boot_cfg" 2>/dev/null | head -n1) || true

    echo "Alpine Anywhere A/B Status"
    echo "=========================="
    echo ""
    echo "Disk:          $(get_boot_disk)"
    echo "Running slot:  $running   (booted from $(get_root_device))"
    echo "Boot slot:     $boot_slot   (next boot -> ${boot_root:-unknown})"
    if [ "$running" != "$boot_slot" ]; then
        echo "  NOTE: boot slot differs from running slot — reboot will switch to $boot_slot"
    fi
    echo ""

    for slot in A B; do
        local mark=""
        [ "$slot" = "$running" ] && mark="${mark} [running]"
        [ "$slot" = "$boot_slot" ] && mark="${mark} [boot]"
        echo "Slot ${slot}${mark}:"
        local ver
        ver=$(get_slot_meta "$slot" "VERSION")
        if [ -n "$ver" ]; then
            echo "  Version:    $ver"
            echo "  Installed:  $(get_slot_meta "$slot" INSTALLED)"
            echo "  Boot count: $(get_slot_meta "$slot" BOOT_COUNT)"
            echo "  Verified:   $(get_slot_meta "$slot" VERIFIED)"
        else
            echo "  (empty)"
        fi
        echo ""
    done
    umount_boot
}
