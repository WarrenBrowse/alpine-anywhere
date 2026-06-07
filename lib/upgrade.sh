#!/bin/sh
# upgrade.sh - A/B upgrade management for alpine-anywhere
#
# Atomic upgrades for the raw-partition squashfs A/B layout:
#   sda1  FAT boot   - config.txt, cmdline.txt, vmlinuz-A/B, initramfs-A/B,
#                      current_slot, slots.meta, firmware, dtbs, overlays
#   sda2  slot A     - raw squashfs root image
#   sda3  slot B     - raw squashfs root image
#   sda4  data       - persistent overlay (phase 3)
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
MAX_BOOT_ATTEMPTS=3

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

# Device the running system was booted from (root=... in the kernel cmdline)
get_root_device() {
    sed -n 's/.*root=\([^ ]*\).*/\1/p' /proc/cmdline
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
    # Rewrite via temp file (portable; avoids GNU/BSD `sed -i` differences)
    if grep -q "^${full}=" "$meta" 2>/dev/null; then
        # `|| true`: grep -v exits 1 when it removes the only line (not an error here)
        grep -v "^${full}=" "$meta" > "${meta}.tmp" || true
        mv "${meta}.tmp" "$meta"
    fi
    echo "${full}=${value}" >> "$meta"
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
    dd if="$squashfs" of="$slot_dev" bs=1M conv=fsync 2>/dev/null
    sync
    log_info "Slot $target_slot written: $(du -h "$squashfs" | cut -f1)"

    # Per-slot kernel on the boot partition (rollback-safe: kernel + userspace
    # stay paired even if the kernel version differs between slots).
    place_slot_kernel "$BOOT_MNT" "$target_slot" \
        "/tmp/boot-files/vmlinuz" "/tmp/boot-files/initramfs"

    set_slot_meta "$target_slot" "VERSION" "$version"
    set_slot_meta "$target_slot" "INSTALLED" "$(date -Iseconds)"
    set_slot_meta "$target_slot" "BOOT_COUNT" "0"
    set_slot_meta "$target_slot" "VERIFIED" "false"

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
    if [ -f "${BOOT_MNT}/config.txt" ]; then
        # Raspberry Pi: select the slot's kernel/initramfs + root device
        sed_inplace "${BOOT_MNT}/config.txt" \
            -e "s|^kernel=vmlinuz-.*|kernel=vmlinuz-${new_slot}|" \
            -e "s|^initramfs initramfs-.*|initramfs initramfs-${new_slot} followkernel|"
        echo "root=${slot_dev} ${SLOT_KERNEL_OPTS}" > "${BOOT_MNT}/cmdline.txt"
    elif [ -f "${BOOT_MNT}/extlinux/extlinux.conf" ]; then
        sed_inplace "${BOOT_MNT}/extlinux/extlinux.conf" \
            -e "s|^DEFAULT alpine-.*|DEFAULT alpine-${new_slot}|"
    else
        die "No known bootloader config on ${BOOT_MNT} (config.txt / extlinux.conf)"
    fi
    echo "$new_slot" > "${BOOT_MNT}/current_slot"
    sync
    log_info "Boot slot switched to $new_slot (reboot to activate)"
}

# Portable in-place sed: sed_inplace FILE -e EXPR [-e EXPR ...]
# Avoids `sed -i` which differs between GNU, BSD and busybox.
sed_inplace() {
    local f="$1"; shift
    sed "$@" "$f" > "${f}.aatmp" && mv "${f}.aatmp" "$f"
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
    umount_boot
    log_info "Slot $current marked verified"
}

# Increment the boot counter for the running slot; roll back if it keeps
# failing without being verified. Intended to run from an early boot service.
increment_boot_counter() {
    mount_boot
    local current count verified
    current=$(get_current_slot)
    count=$(get_slot_meta "$current" "BOOT_COUNT")
    count=$((${count:-0} + 1))
    set_slot_meta "$current" "BOOT_COUNT" "$count"
    verified=$(get_slot_meta "$current" "VERIFIED")

    if [ "$count" -gt "$MAX_BOOT_ATTEMPTS" ] && [ "$verified" != "true" ]; then
        log_warn "Slot $current failed $count boots without verify; rolling back"
        rollback_slot
        return
    fi
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
        umount_boot
        log_error "Cannot roll back: slot $previous has no installed image"
        return 1
    fi

    log_warn "Rolling back: $current -> $previous"
    switch_slot "$previous"
    umount_boot
    log_info "Rolled back to slot $previous. Rebooting..."
    # -f: rollback can run from the PID 1 boot-guard shim (before the real init),
    # where signalling a normal reboot would have nothing to handle it.
    reboot -f 2>/dev/null || reboot
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
    echo "After a successful boot, confirm it:  alpine-anywhere verify"
    echo "If slot $target fails to boot ${MAX_BOOT_ATTEMPTS}x, it auto-rolls back to slot $current."
    echo ""
}

# =============================================================================
# Status Command
# =============================================================================

show_status() {
    mount_boot
    local current
    current=$(get_current_slot)

    echo "Alpine Anywhere A/B Status"
    echo "=========================="
    echo ""
    echo "Disk:         $(get_boot_disk)"
    echo "Active slot:  $current"
    echo ""

    for slot in A B; do
        echo "Slot $slot:"
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
