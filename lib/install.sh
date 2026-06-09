#!/bin/sh
# install.sh - A/B installation for alpine-anywhere
#
# Creates an immutable Alpine Linux installation with:
# - A/B boot slots for atomic updates
# - Read-only squashfs root
# - Optional persistent overlay for data

# =============================================================================
# Constants
# =============================================================================

# Partition layout (GPT)
# 1: Boot (FAT32, 512M) - firmware + kernel + initramfs + config
# 2: Slot A (raw, 2G)   - squashfs root image A
# 3: Slot B (raw, 2G)   - squashfs root image B
# 4: Data (ext4, rest)  - persistent overlay (optional, phase 3)

PART_BOOT_SIZE_MB=512
PART_SLOT_SIZE_MB=2048
MIN_DISK_SIZE_MB=5120

# dm-verity: the per-slot hash tree is appended INSIDE the slot partition at a
# fixed offset near its end (a tree for a ~1.5 GiB image is well under 16 MiB;
# 64 MiB is a generous constant so the initramfs needs no metadata to find it).
VERITY_RESERVE_MB=64
VERITY_OFFSET_MB=$((PART_SLOT_SIZE_MB - VERITY_RESERVE_MB))

# =============================================================================
# Disk Detection
# =============================================================================

# Detect the target install disk
# When running from tmpfs (after pivot), root is not on a real disk,
# so we find the first available physical disk instead.
detect_root_disk() {
    local root_type disk

    root_type=$(stat -f -c %T / 2>/dev/null || df -T / 2>/dev/null | awk 'NR==2{print $2}')

    if echo "$root_type" | grep -qi tmpfs; then
        # Running from RAM - pick the target physical disk.
        # DANGER: with both an SD card (mmcblk0) and a USB/NVMe disk present,
        # guessing "the first disk" could wipe the boot medium. So refuse to
        # guess when there is more than one disk — require --disk.
        local disks ndisks
        disks=$(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
        ndisks=$(printf '%s\n' "$disks" | grep -c .)
        if [ "$ndisks" -eq 0 ]; then
            die "No physical disk found"
        elif [ "$ndisks" -gt 1 ]; then
            log_error "Multiple disks present:"
            list_available_disks >&2
            die "Refusing to guess the install disk. Re-run with --disk <device> (e.g. --disk /dev/sda)"
        fi
        disk="$disks"
        log_debug "Running from tmpfs, single disk: $disk"
    else
        # Running from disk - detect root device
        disk=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's/p$//')
        case "$disk" in
            *mmcblk*|*nvme*) disk=$(echo "$disk" | sed 's/p$//') ;;
        esac
    fi

    echo "$disk"
}

# Get disk size in MB
get_disk_size_mb() {
    local disk="$1"
    local size_bytes
    size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null)
    echo $((size_bytes / 1024 / 1024))
}

# List all available block devices (disks only, no partitions)
list_available_disks() {
    lsblk -dnpo NAME,SIZE,TYPE 2>/dev/null | awk '$3 == "disk" {print $1, $2}'
}

# Get partition info for a disk
get_partition_info() {
    local disk="$1"
    lsblk -npo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$disk" 2>/dev/null | tail -n +2
}

# Check if partition exists and is usable for data overlay
is_usable_data_partition() {
    local part="$1"
    local fstype label

    fstype=$(lsblk -npo FSTYPE "$part" 2>/dev/null)
    label=$(lsblk -npo LABEL "$part" 2>/dev/null)

    # Accept ext4 partitions, especially those labeled for data
    if [ "$fstype" = "ext4" ]; then
        # Prefer partitions with data-related labels
        case "$label" in
            *DATA*|*data*|*home*|*persist*)
                echo "preferred"
                ;;
            *)
                echo "usable"
                ;;
        esac
    elif [ -z "$fstype" ]; then
        # Unformatted partition - can be formatted
        echo "unformatted"
    else
        echo "unusable"
    fi
}

# Auto-detect best overlay device
# Returns: device path or empty if none found
auto_detect_overlay_device() {
    local root_disk preferred_part usable_part unformatted_part

    root_disk=$(detect_root_disk)
    log_debug "Root disk: $root_disk"

    # First, look for existing data partitions on root disk.
    # NOTE: must NOT pipe into `while` - a piped loop runs in a subshell and
    # the preferred_part/usable_part/unformatted_part assignments would be lost,
    # making detection silently always return empty (or, worse, a later edit
    # picking a wrong device). Feed the loop via a here-doc instead so it runs
    # in the current shell. (BusyBox ash / bash 3.2 both lack `lastpipe`.)
    local part_info
    part_info=$(get_partition_info "$root_disk")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local part fstype label mount status
        part=$(echo "$line" | awk '{print $1}')
        fstype=$(echo "$line" | awk '{print $3}')
        label=$(echo "$line" | awk '{print $4}')
        mount=$(echo "$line" | awk '{print $5}')

        # Skip if mounted as / or /boot
        case "$mount" in
            /|/boot*) continue ;;
        esac

        status=$(is_usable_data_partition "$part")

        case "$status" in
            preferred)
                preferred_part="$part"
                log_debug "Found preferred data partition: $part (label: $label)"
                ;;
            usable)
                [ -z "$usable_part" ] && usable_part="$part"
                log_debug "Found usable partition: $part"
                ;;
            unformatted)
                [ -z "$unformatted_part" ] && unformatted_part="$part"
                log_debug "Found unformatted partition: $part"
                ;;
        esac
    done <<EOF
$part_info
EOF

    # Return best option
    if [ -n "$preferred_part" ]; then
        echo "$preferred_part"
    elif [ -n "$usable_part" ]; then
        echo "$usable_part"
    elif [ -n "$unformatted_part" ]; then
        echo "$unformatted_part"
    fi
}

# Detect and display disk information
detect_disk_layout() {
    log_step "Detecting disk layout..."

    local root_disk overlay_device
    root_disk=$(detect_root_disk)

    log_info "Root disk: $root_disk ($(get_disk_size_mb "$root_disk")MB)"
    log_info "Current partitions:"

    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$root_disk" 2>/dev/null | while read -r line; do
        log_info "  $line"
    done

    # Auto-detect overlay if not specified
    if [ -z "$OVERLAY_DEVICE" ]; then
        overlay_device=$(auto_detect_overlay_device)
        if [ -n "$overlay_device" ]; then
            log_info "Auto-detected overlay device: $overlay_device"
            OVERLAY_DEVICE="$overlay_device"
        else
            log_info "No suitable overlay partition found - will create new layout"
        fi
    else
        log_info "Using specified overlay device: $OVERLAY_DEVICE"
    fi

    echo "$root_disk"
}

# =============================================================================
# Partition Management
# =============================================================================

# Create partition layout for A/B installation
create_partition_layout() {
    local disk="$1"
    local with_data="${2:-true}"

    log_step "Creating partition layout on $disk..."

    local disk_size
    disk_size=$(get_disk_size_mb "$disk")
    if [ "$disk_size" -lt "$MIN_DISK_SIZE_MB" ]; then
        die "Disk too small: ${disk_size}MB (minimum: ${MIN_DISK_SIZE_MB}MB)"
    fi

    log_info "Disk size: ${disk_size}MB"

    local slot_end_mb=$((1 + PART_BOOT_SIZE_MB + PART_SLOT_SIZE_MB + PART_SLOT_SIZE_MB))

    log_info "Creating GPT partition table..."
    require parted -s "$disk" mklabel gpt

    log_info "Creating boot partition (${PART_BOOT_SIZE_MB}MB, FAT32)..."
    require parted -s "$disk" mkpart boot fat32 1MiB "${PART_BOOT_SIZE_MB}MiB"
    require parted -s "$disk" set 1 boot on

    log_info "Creating slot A partition (${PART_SLOT_SIZE_MB}MB)..."
    require parted -s "$disk" mkpart slota ext4 "${PART_BOOT_SIZE_MB}MiB" "$((PART_BOOT_SIZE_MB + PART_SLOT_SIZE_MB))MiB"

    log_info "Creating slot B partition (${PART_SLOT_SIZE_MB}MB)..."
    require parted -s "$disk" mkpart slotb ext4 "$((PART_BOOT_SIZE_MB + PART_SLOT_SIZE_MB))MiB" "${slot_end_mb}MiB"

    if [ "$with_data" = "true" ]; then
        log_info "Creating data partition (remaining space)..."
        require parted -s "$disk" mkpart data ext4 "${slot_end_mb}MiB" 100%
    fi

    # Try to re-read partition table. partprobe/blockdev legitimately fail on a
    # busy disk, so they stay best-effort - but the partition table MUST be
    # readable one way or another before we format/dd, so ensure_partition_devices
    # (which falls back to loop devices and dies if even that fails) is the
    # authoritative gate, asserted here.
    sync
    try_warn partprobe "$disk"
    try_warn blockdev --rereadpt "$disk"
    sleep 1
    ensure_partition_devices "$disk"

    log_info "Partition layout created"
}

# Get partition device name
get_partition_device() {
    local disk="$1"
    local part_num="$2"

    case "$disk" in
        *mmcblk*|*nvme*|*loop*)
            echo "${disk}p${part_num}"
            ;;
        *)
            echo "${disk}${part_num}"
            ;;
    esac
}

# Ensure partition devices exist (use loop devices if kernel can't re-read table)
ensure_partition_devices() {
    local disk="$1"
    local part1_dev
    part1_dev=$(get_partition_device "$disk" 1)

    if [ -b "$part1_dev" ]; then
        log_debug "Partition devices available directly"
        return 0
    fi

    log_info "Kernel can't see new partitions, creating loop devices..."

    # Read partition offsets from GPT via sfdisk
    local part_info
    part_info=$(sfdisk -d "$disk" 2>/dev/null | grep "^${disk}")

    # Feed the loop via here-doc, NOT a pipe: a piped `while` runs in a subshell
    # so a losetup failure inside it would be invisible AND we must `die` before
    # exporting any PART_*_DEV that points at a stale/never-created loop device -
    # otherwise a later `dd` could write to the wrong device. (CRITICAL.)
    local part_num=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        part_num=$((part_num + 1))
        local start size loop
        start=$(echo "$line" | sed -n 's/.*start= *\([0-9]*\).*/\1/p')
        size=$(echo "$line" | sed -n 's/.*size= *\([0-9]*\).*/\1/p')
        if [ -z "$start" ] || [ -z "$size" ]; then
            die "ensure_partition_devices: could not parse offsets from sfdisk for partition $part_num"
        fi
        loop="/dev/loop$((part_num - 1))"
        losetup -d "$loop" 2>/dev/null || true
        require losetup -o $((start * 512)) --sizelimit $((size * 512)) "$loop" "$disk"
        log_debug "  $loop -> offset=$start size=$size sectors"
    done <<EOF
$part_info
EOF

    [ "$part_num" -ge 3 ] || die "ensure_partition_devices: expected >=3 partitions, mapped $part_num"

    # Export loop device mapping
    PART_BOOT_DEV="/dev/loop0"
    PART_SLOTA_DEV="/dev/loop1"
    PART_SLOTB_DEV="/dev/loop2"
    PART_DATA_DEV="/dev/loop3"

    # Verify each mapped loop actually backs the target disk before any caller
    # writes to it.
    local d
    for d in "$PART_BOOT_DEV" "$PART_SLOTA_DEV" "$PART_SLOTB_DEV"; do
        [ -b "$d" ] || die "ensure_partition_devices: $d is not a block device after losetup"
        losetup "$d" 2>/dev/null | grep -qF "$disk" || die "ensure_partition_devices: $d does not back $disk"
    done
}

# Get the actual device for a partition (handles loop device fallback)
get_part_dev() {
    local disk="$1"
    local part_num="$2"
    local direct_dev
    direct_dev=$(get_partition_device "$disk" "$part_num")

    if [ -b "$direct_dev" ]; then
        echo "$direct_dev"
    else
        # Use loop device
        echo "/dev/loop$((part_num - 1))"
    fi
}

# Refuse a kernel image the Raspberry Pi firmware cannot boot. The RPi firmware
# loads a flat ARM64 `Image`, identified by the magic bytes "ARMd" (0x41 52 4d
# 64) at offset 56. A compressed EFI-zboot vmlinuz (e.g. Alpine linux-lts) lacks
# it and the firmware fails to start it - producing a slot that never boots.
# No-op on non-RPi platforms (UEFI/extlinux handle compressed kernels fine).
assert_rpi_bootable_kernel() {
    _arbk_vmlinuz="$1"
    [ "$DETECTED_PLATFORM" = "rpi" ] || return 0
    [ -f "$_arbk_vmlinuz" ] || die "kernel image missing: $_arbk_vmlinuz"

    _arbk_magic=$(dd if="$_arbk_vmlinuz" bs=1 skip=56 count=4 2>/dev/null)
    if [ "$_arbk_magic" != "ARMd" ]; then
        die "kernel '${KERNEL_PKG:-linux-rpi}' is not a flat ARM64 Image (RPi firmware can't boot it: magic '${_arbk_magic}' != 'ARMd'). On a Raspberry Pi use linux-rpi, or a kernel built as a flat Image with CONFIG_DM_VERITY for --verity."
    fi
    log_debug "RPi kernel image is a bootable flat ARM64 Image (ARMd magic OK)"
}

# True if the kernel installed in the build chroot supports dm-verity, either
# builtin (CONFIG_DM_VERITY=y) or as a loadable module (=m / a dm-verity.ko).
# Checked against the real /boot/config-* so we never enable verity on a kernel
# that can't open it at boot (e.g. Alpine linux-rpi, which disables it).
kernel_supports_verity() {
    _ksv_root="$1"
    # Builtin or module per the kernel config.
    if grep -hqs '^CONFIG_DM_VERITY=[ym]' "${_ksv_root}"/boot/config-* 2>/dev/null; then
        return 0
    fi
    # Fallback: an actual dm-verity.ko shipped under the installed modules.
    if ls "${_ksv_root}"/lib/modules/*/kernel/drivers/md/dm-verity.ko* >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Write a squashfs image to a slot partition AND lay down a dm-verity hash tree
# for it, so the kernel can cryptographically verify every block at runtime.
#
# Layout inside the slot partition:
#   [ 0 .. data_size )                 squashfs image (read-only root)
#   [ VERITY_OFFSET_MB MiB .. )        verity hash tree
# With veritysetup's --hash-offset the SAME device is both data and hash device,
# so no extra partition is needed (RPi/UEFI-agnostic).
#
# Echoes a single line:  ROOT_HASH SALT DATA_SIZE HASH_OFFSET_BYTES
# which the caller persists into slots.meta. Dies on any failure.
format_verity_slot() {
    _fvs_src="$1"; _fvs_dev="$2"
    # veritysetup runs on the BUILDER (the running system / RAM env doing the
    # install), not in the image chroot - ensure it is present here.
    if ! command_exists veritysetup; then
        log_info "Installing cryptsetup on the builder for veritysetup..."
        apk add --no-cache cryptsetup >/dev/null 2>&1 || true
    fi
    command_exists veritysetup || die "veritysetup not found (apk add cryptsetup) - required for --verity"
    [ -f "$_fvs_src" ] || die "format_verity_slot: source $_fvs_src missing"
    is_block_device "$_fvs_dev" || die "format_verity_slot: $_fvs_dev is not a block device"

    _fvs_size=$(wc -c < "$_fvs_src")
    _fvs_offset=$((VERITY_OFFSET_MB * 1024 * 1024))
    if [ "$_fvs_size" -gt "$_fvs_offset" ]; then
        die "format_verity_slot: image ($_fvs_size B) exceeds verity offset ($_fvs_offset B); slot too small"
    fi

    # Build the hash tree to a sidecar file and capture Root hash + Salt.
    _fvs_hash="${_fvs_src}.hash"
    _fvs_out=$(veritysetup format "$_fvs_src" "$_fvs_hash" \
        --data-block-size=4096 --hash-block-size=4096) \
        || die "veritysetup format failed for $_fvs_src"
    _fvs_root=$(printf '%s\n' "$_fvs_out" | awk '/Root hash:/{print $NF}')
    _fvs_salt=$(printf '%s\n' "$_fvs_out" | awk '/Salt:/{print $NF}')
    [ -n "$_fvs_root" ] || die "format_verity_slot: could not parse Root hash"

    # Write image at offset 0, then the hash tree at the fixed offset.
    require dd if="$_fvs_src" of="$_fvs_dev" bs=1M conv=fsync
    require dd if="$_fvs_hash" of="$_fvs_dev" bs=1M seek="$VERITY_OFFSET_MB" conv=fsync
    sync
    rm -f "$_fvs_hash"

    log_info "Slot verity formatted: root=${_fvs_root} (data ${_fvs_size}B, hash@${_fvs_offset}B)" >&2
    echo "$_fvs_root $_fvs_salt $_fvs_size $_fvs_offset"
}

# Format partitions
format_partitions() {
    local disk="$1"
    local with_data="${2:-true}"

    log_step "Formatting partitions..."

    # Ensure we can access partitions (loop devices if needed)
    ensure_partition_devices "$disk"

    local boot_dev slota_dev data_dev
    boot_dev=$(get_part_dev "$disk" 1)

    log_info "Formatting boot partition ($boot_dev, FAT32)..."
    require mkfs.vfat -F 32 -n ALPINE_BOOT "$boot_dev"

    # Slot A and B are raw (squashfs written directly), no formatting needed
    log_info "Slot A and B: raw partitions (squashfs will be written directly)"

    if [ "$with_data" = "true" ]; then
        data_dev=$(get_part_dev "$disk" 4)
        log_info "Formatting data partition ($data_dev, ext4)..."
        require mkfs.ext4 -L ALPINE_DATA -q -F "$data_dev"
    fi

    log_info "Partitions formatted"
}

# =============================================================================
# Boot Structure Setup
# =============================================================================

# Create A/B boot structure
setup_boot_structure() {
    local boot_mount="$1"

    log_step "Setting up A/B boot structure..."

    # Create slot directories
    mkdir -p "${boot_mount}/slots/A"
    mkdir -p "${boot_mount}/slots/B"
    mkdir -p "${boot_mount}/bootloader"

    # Create slot marker
    echo "A" > "${boot_mount}/current_slot"

    # Create slot metadata
    cat > "${boot_mount}/slots/A/meta.conf" << 'EOF'
VERSION=
INSTALLED=
BOOT_COUNT=0
VERIFIED=false
EOF

    cat > "${boot_mount}/slots/B/meta.conf" << 'EOF'
VERSION=
INSTALLED=
BOOT_COUNT=0
VERIFIED=false
EOF

    log_info "Boot structure created"
}

# =============================================================================
# System Image Generation
# =============================================================================

# Build Alpine rootfs and create squashfs image
# Output: /tmp/system.squashfs + kernel/initramfs in $BUILD_DIR/boot/
# Resolve INIT_SYSTEM default (s6 when hardened, else openrc) and validate it.
resolve_init_system() {
    if [ -z "$INIT_SYSTEM" ]; then
        if [ "$HARDENED_MODE" = "true" ]; then INIT_SYSTEM="s6"; else INIT_SYSTEM="openrc"; fi
    fi
    case "$INIT_SYSTEM" in
        openrc|s6) ;;
        *) die "Invalid --init '$INIT_SYSTEM' (expected: openrc or s6)" ;;
    esac
}

generate_system_squashfs() {
    local squashfs_output="$1"

    resolve_init_system
    log_step "Building Alpine system image (init: ${INIT_SYSTEM})..."

    local build_dir
    build_dir=$(mktemp -d)

    # Extract minirootfs. Download to a file first (not a streamed pipe) so the
    # archive can be integrity-checked against its published sha512 before any
    # of its contents touch the build tree.
    log_info "Extracting base system..."
    if [ -f "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" ]; then
        require tar -xzf "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" -C "$build_dir"
    else
        local minirootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz"
        local minirootfs_tgz="${build_dir}.minirootfs.tar.gz"
        download_file "$minirootfs_url" "$minirootfs_tgz"
        require tar -xzf "$minirootfs_tgz" -C "$build_dir"
        rm -f "$minirootfs_tgz"
    fi

    # DNS must be set BEFORE apk update
    cp /etc/resolv.conf "${build_dir}/etc/resolv.conf"

    # APK repos
    cat > "${build_dir}/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF

    # Mount for chroot
    mount -t proc proc "${build_dir}/proc"
    mount -t sysfs sysfs "${build_dir}/sys"
    mount --bind /dev "${build_dir}/dev"

    # Determine kernel package. --kernel-pkg overrides the platform default,
    # which lets you pick a verity-capable kernel on a Pi (linux-lts/linux-edge)
    # or a self-built linux-hardened published in a custom apk repo.
    # NOTE: the stock linux-rpi has `# CONFIG_DM_VERITY is not set` (verified on
    # a real Pi 4), so --verity is NOT available there; linux-lts/virt/edge have
    # CONFIG_DM_VERITY=m. The feasibility gate below enforces this against the
    # ACTUAL installed kernel config, whatever package was chosen.
    local kernel_pkg="linux-lts"
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        kernel_pkg="linux-rpi"
    fi
    if [ -n "$KERNEL_PKG" ]; then
        kernel_pkg="$KERNEL_PKG"
        log_info "Using overridden kernel package: $kernel_pkg"
    fi

    # Configure mkinitfs to include squashfs BEFORE installing kernel.
    # When dm-verity is enabled we also pull in the stock `cryptsetup` mkinitfs
    # feature, which embeds /sbin/veritysetup + its libs and the dm-mod/dm-verity
    # modules into the initramfs (the same proven path Alpine uses for LUKS).
    mkdir -p "${build_dir}/etc/mkinitfs"
    local mkinitfs_features="ata base cdrom ext4 keymap kms mmc nvme scsi usb virtio squashfs"
    if verity_enabled; then
        mkinitfs_features="$mkinitfs_features cryptsetup"
    fi
    echo "features=\"${mkinitfs_features}\"" > "${build_dir}/etc/mkinitfs/mkinitfs.conf"

    # Install packages
    log_info "Installing packages (kernel: $kernel_pkg)..."
    chroot "$build_dir" /sbin/apk update

    local ssh_pkg="openssh-server openssh-client"
    if [ "$HARDENED_MODE" = "true" ]; then
        # dropbear-convert provides dropbearconvert, needed to preserve an
        # existing OpenSSH host identity as dropbear keys (and vice versa).
        ssh_pkg="dropbear dropbear-openrc dropbear-convert"
    fi

    # Init system packages
    local init_pkg="openrc busybox-openrc"
    if [ "$INIT_SYSTEM" = "s6" ]; then
        init_pkg="s6 s6-rc s6-linux-init s6-portable-utils s6-linux-utils execline"
    fi

    # cryptsetup provides veritysetup, needed both at build time (format the
    # hash tree) and on the installed system (re-format on upgrade) when
    # dm-verity is enabled.
    local verity_pkg=""
    verity_enabled && verity_pkg="cryptsetup"

    # squashfs-tools is needed on the installed system so `alpine-anywhere
    # upgrade` can build the next slot's image in place.
    chroot "$build_dir" /sbin/apk add --no-cache \
        alpine-base $init_pkg \
        "$kernel_pkg" linux-firmware-none \
        mkinitfs \
        $ssh_pkg \
        e2fsprogs dosfstools squashfs-tools $verity_pkg \
        chrony ca-certificates curl

    # RPi: install firmware package
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        chroot "$build_dir" /sbin/apk add --no-cache raspberrypi-bootloader
    fi

    # dm-verity feasibility gate: the stock Alpine linux-rpi kernel ships with
    # `# CONFIG_DM_VERITY is not set` (verified on a real RPi: 6.6.49-r0), so
    # opening the verity device at boot would fail and the slot would never
    # mount -> rollback loop -> unbootable. Check the kernel we just installed
    # and refuse (explicit --verity) or auto-disable (hardened default) rather
    # than building a brick.
    if verity_enabled && ! kernel_supports_verity "$build_dir"; then
        if [ "$VERITY_MODE" = "on" ]; then
            die "dm-verity requested but the installed kernel ($kernel_pkg) has no CONFIG_DM_VERITY. Use --no-verity or a kernel with dm-verity (e.g. linux-lts on x86_64)."
        fi
        log_warn "Kernel ($kernel_pkg) lacks CONFIG_DM_VERITY; disabling dm-verity for this build."
        log_warn "(The hardened root will NOT be verity-protected on this platform.)"
        VERITY_MODE=off
    fi

    # Extra packages
    if [ -n "$EXTRA_PACKAGES" ]; then
        chroot "$build_dir" /sbin/apk add --no-cache $(echo "$EXTRA_PACKAGES" | tr ',' ' ')
    fi

    # Configure the system
    configure_system_image "$build_dir"

    # Setup SSH
    setup_system_ssh "$build_dir"

    # Apply hardening if enabled
    if [ "$HARDENED_MODE" = "true" ]; then
        apply_hardening_to_image "$build_dir" 2>/dev/null || true
    fi

    # User customization hook (runs inside the chroot, network available)
    run_custom_script "$build_dir"

    # Bake the management CLI + A/B auto-rollback services into the image
    bake_management_tools "$build_dir"

    # s6 init: build s6-rc db + s6-linux-init basedir, make s6 PID 1
    if [ "$INIT_SYSTEM" = "s6" ]; then
        setup_s6_init "$build_dir"
    fi

    # Cleanup chroot mounts
    umount "${build_dir}/dev" 2>/dev/null || true
    umount "${build_dir}/sys" 2>/dev/null || true
    umount "${build_dir}/proc" 2>/dev/null || true

    # Save boot files BEFORE creating squashfs (we'll extract them for boot partition)
    mkdir -p /tmp/boot-files
    cp "${build_dir}"/boot/vmlinuz-* /tmp/boot-files/vmlinuz 2>/dev/null || true
    cp "${build_dir}"/boot/initramfs-* /tmp/boot-files/initramfs 2>/dev/null || true
    cp "${build_dir}"/boot/*.dtb /tmp/boot-files/ 2>/dev/null || true
    cp -r "${build_dir}"/boot/overlays /tmp/boot-files/ 2>/dev/null || true
    # RPi firmware files
    cp "${build_dir}"/boot/start*.elf /tmp/boot-files/ 2>/dev/null || true
    cp "${build_dir}"/boot/fixup*.dat /tmp/boot-files/ 2>/dev/null || true
    cp "${build_dir}"/boot/bootcode.bin /tmp/boot-files/ 2>/dev/null || true

    # On a Raspberry Pi, refuse a kernel the firmware can't boot. The RPi
    # firmware (non-UEFI) only loads a FLAT arm64 `Image` (magic "ARMd" at
    # offset 56); Alpine's linux-lts ships a COMPRESSED EFI-zboot vmlinuz which
    # the firmware silently fails to start -> the slot would never boot (no
    # rollback, since the kernel never reaches the initramfs). Catch it here at
    # build time instead of producing an unbootable slot. linux-rpi ships the
    # flat Image, so the default path is unaffected; this only bites a
    # --kernel-pkg override like linux-lts/linux-edge on a Pi.
    assert_rpi_bootable_kernel /tmp/boot-files/vmlinuz

    # A/B boot-guard: patch this slot's initramfs so a failed/unverified boot
    # rolls back to the other slot. Runs in the initramfs right before
    # switch_root (modules loaded, busybox ready, disk accessible) — the one
    # environment where rdinit=/init=/early-/init all failed before.
    wrap_boot_initramfs /tmp/boot-files/initramfs

    # Create squashfs
    log_info "Creating squashfs image..."
    # NOTE: gzip (not zstd) — the Alpine linux-rpi4 kernel builds squashfs
    # without CONFIG_SQUASHFS_ZSTD, so a zstd image fails to mount (EINVAL)
    # at boot. gzip/xz/lz4/lzo are the supported decompressors.
    mksquashfs "$build_dir" "$squashfs_output" \
        -comp gzip -noappend -no-progress

    rm -rf "$build_dir"

    log_info "System image: $(du -h "$squashfs_output" | cut -f1)"
}

# Run a user-provided customization script inside the image chroot.
# The script runs as root with the image mounted at /, with working network
# (resolv.conf + /proc /sys /dev are bind-mounted), so it can `apk add`,
# `wget`/`curl` projects into /usr/local/share, drop config files, etc.
# Example custom-script.sh:
#   #!/bin/sh
#   apk add --no-cache git
#   git clone --depth 1 https://github.com/aya/myos /usr/local/share/myos
run_custom_script() {
    local root="$1"
    [ -n "$CUSTOM_SCRIPT" ] || return 0
    [ -f "$CUSTOM_SCRIPT" ] || die "Custom script not found: $CUSTOM_SCRIPT"

    log_info "Running custom build hook: $CUSTOM_SCRIPT"
    cp "$CUSTOM_SCRIPT" "${root}/tmp/aa-custom.sh"
    chmod +x "${root}/tmp/aa-custom.sh"
    if ! chroot "$root" /bin/sh /tmp/aa-custom.sh; then
        rm -f "${root}/tmp/aa-custom.sh"
        die "Custom script failed: $CUSTOM_SCRIPT"
    fi
    rm -f "${root}/tmp/aa-custom.sh"
    log_info "Custom build hook completed"
}

# Locate the alpine-anywhere CLI source base dir (control-host deploy or repo).
_aa_cli_src() {
    if [ -f "${INSTALL_BASE_DIR}/alpine-anywhere" ]; then echo "${INSTALL_BASE_DIR}"
    elif [ -f "${SCRIPT_DIR}/alpine-anywhere" ]; then echo "${SCRIPT_DIR}"
    else return 1; fi
}

# Install the full alpine-anywhere tool into $root, exposed as the `aa` command.
#   /usr/local/share/alpine-anywhere/{alpine-anywhere,lib/*.sh} - a complete copy
#     so the installed host can itself act as a control host and install other
#     remotes (e.g. `aa --install user@other`).
#   /usr/local/bin/aa - exec wrapper for the command (no system dirs touched).
AA_TOOL_DIR="/usr/local/share/alpine-anywhere"
install_aa_cli() {
    local root="$1" srcbase dest
    srcbase=$(_aa_cli_src) || return 1
    dest="${root}${AA_TOOL_DIR}"
    mkdir -p "${dest}/lib" "${root}/usr/local/bin"
    cp "${srcbase}/alpine-anywhere" "${dest}/alpine-anywhere"
    cp "${srcbase}"/lib/*.sh "${dest}/lib/"
    chmod +x "${dest}/alpine-anywhere"
    cat > "${root}/usr/local/bin/aa" << EOF
#!/bin/sh
exec ${AA_TOOL_DIR}/alpine-anywhere "\$@"
EOF
    chmod +x "${root}/usr/local/bin/aa"
}

# Bake the `aa` command + A/B services into the image so the installed system can
# run `aa status|verify|rollback`, auto-rollback at boot, and install other hosts.
bake_management_tools() {
    local root="$1"
    if ! install_aa_cli "$root"; then
        log_warn "aa CLI source not found; skipping management tools"
        return 0
    fi
    log_info "Baking 'aa' command + alpine-anywhere tool into image..."
    # The A/B boot-guard itself (init.aa) is injected into the initramfs by
    # wrap_boot_initramfs (called from generate_system_squashfs); here we only
    # install the userspace aa-verify service that COMMITS a healthy boot
    # (resets the boot counter), which is what stops init.aa from rolling back.
    install_ab_services "$root"
}

# Wrap the Alpine mkinitfs initramfs with the A/B boot-guard, in place.
# We PATCH the Alpine init to call /sbin/init.aa right before its
# `exec ... switch_root`. CRUCIAL DETAIL: at that point the init has ALREADY
# run its "move mounts into $sysroot" loop, so /proc and /dev are NO LONGER at
# their normal paths (/proc/cmdline is empty, /dev/<part> is gone) — they live
# under $sysroot now. So the patch passes the init's OWN variables to the guard:
#     /sbin/init.aa "$KOPT_root" "$sysroot"
# and init.aa reads root from the arg (fallback: $sysroot/proc/cmdline) and
# finds the FAT boot node under /dev OR $sysroot/dev. busybox runs as a
# standalone shell, so applets (mount/sed/reboot/...) resolve without symlinks.
wrap_boot_initramfs() {
    local img="$1"
    [ -f "$img" ] || { log_warn "initramfs $img missing; skipping boot-guard"; return 0; }
    log_info "Wrapping initramfs with A/B boot-guard (init.aa before switch_root)..."
    local tmp; tmp=$(mktemp -d)
    ( cd "$tmp" && gzip -dc "$img" 2>/dev/null | cpio -idm 2>/dev/null ) || {
        log_warn "Could not unpack initramfs; skipping boot-guard"; rm -rf "$tmp"; return 0; }
    [ -f "$tmp/init" ] || { log_warn "initramfs has no /init; skipping boot-guard"; rm -rf "$tmp"; return 0; }
    grep -q 'exec .*switch_root' "$tmp/init" || { log_warn "no 'exec ... switch_root' in init; skipping boot-guard"; rm -rf "$tmp"; return 0; }

    mkdir -p "$tmp/sbin"
    # init.aa now lives as a standalone, testable file under lib/initramfs/.
    # Resolve it from wherever the tool is installed/run.
    local init_aa_src=""
    for cand in \
        "${SCRIPT_DIR}/lib/initramfs/init.aa" \
        "${INSTALL_LIB_DIR}/initramfs/init.aa" \
        "${INSTALL_BASE_DIR}/lib/initramfs/init.aa" \
        "/boot/alpine-anywhere/lib/initramfs/init.aa"; do
        [ -f "$cand" ] && { init_aa_src="$cand"; break; }
    done
    [ -n "$init_aa_src" ] || { log_warn "init.aa source not found; skipping boot-guard"; rm -rf "$tmp"; return 0; }
    require cp "$init_aa_src" "$tmp/sbin/init.aa"
    chmod +x "$tmp/sbin/init.aa"

    # Insert the guard call on the line(s) before `exec ... switch_root`, once,
    # preserving indentation. We pass the init's own $KOPT_root and $sysroot so
    # the guard works even though /proc and /dev have been moved into $sysroot.
    # awk (not `sed -i ...\n...`) so it's portable + idempotent. NOTE: $KOPT_root
    # / $sysroot are LITERAL text emitted into /init (shell expands them at boot);
    # inside an awk string literal `$` is not the field operator.
    if ! grep -q '/sbin/init.aa' "$tmp/init"; then
        awk '
            /^[[:space:]]*exec .*switch_root/ {
                match($0, /^[[:space:]]*/)
                print substr($0, 1, RLENGTH) "/sbin/init.aa \"$KOPT_root\" \"$sysroot\" 2>/dev/null || true"
            }
            { print }
        ' "$tmp/init" > "$tmp/init.aa.new" && mv "$tmp/init.aa.new" "$tmp/init"
        chmod +x "$tmp/init"
    fi

    # dm-verity: copy aa-verity-open and insert a call BEFORE the root mount so
    # the init mounts the verified mapper device instead of the raw slot. The
    # verity device must be opened before the mount that targets $sysroot.
    if verity_enabled; then
        local vopen_src=""
        for cand in \
            "${SCRIPT_DIR}/lib/initramfs/aa-verity-open" \
            "${INSTALL_LIB_DIR}/initramfs/aa-verity-open" \
            "${INSTALL_BASE_DIR}/lib/initramfs/aa-verity-open" \
            "/boot/alpine-anywhere/lib/initramfs/aa-verity-open"; do
            [ -f "$cand" ] && { vopen_src="$cand"; break; }
        done
        [ -n "$vopen_src" ] || die "aa-verity-open source not found but --verity requested"
        require cp "$vopen_src" "$tmp/sbin/aa-verity-open"
        chmod +x "$tmp/sbin/aa-verity-open"

        if ! grep -q '/sbin/aa-verity-open' "$tmp/init"; then
            # Open verity right before the root device is mounted, AFTER
            # nlplug-findfs has plugged the real slot node. In the real Alpine
            # mkinitfs init the overlaytmpfs path (what we use) mounts $KOPT_root
            # at /media/root-ro via `mkdir -p /media/root-ro ...`; the plain path
            # mounts onto $sysroot. Anchor on whichever appears first and rewrite
            # KOPT_root to the verity mapper so the subsequent mount uses it.
            # Fail the build LOUDLY rather than ship an unbootable verity slot.
            local vanchor=""
            if grep -qE '^[[:space:]]*mkdir -p /media/root-ro' "$tmp/init"; then
                vanchor='^[[:space:]]*mkdir -p /media/root-ro'
            elif grep -qE 'mount .*\$sysroot' "$tmp/init"; then
                vanchor='mount .*\$sysroot'
            else
                die "wrap_boot_initramfs: no root-mount anchor for verity in initramfs init (mkinitfs layout changed)"
            fi
            awk -v anchor="$vanchor" '
                $0 ~ anchor && !done {
                    match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
                    print ind "if [ \"$KOPT_aaverity\" = 1 ]; then _aadev=$(/sbin/aa-verity-open \"$KOPT_root\" \"$sysroot\" 2>/dev/null); [ -n \"$_aadev\" ] && KOPT_root=\"$_aadev\" && root=\"$_aadev\"; fi"
                    done=1
                }
                { print }
            ' "$tmp/init" > "$tmp/init.v.new" && mv "$tmp/init.v.new" "$tmp/init"
            chmod +x "$tmp/init"
        fi
    fi

    ( cd "$tmp" && find . | cpio -o -H newc 2>/dev/null | gzip ) > "$img" \
        || log_warn "Could not repack initramfs boot-guard"
    rm -rf "$tmp"
}

# OpenRC service for A/B auto-rollback:
#   aa-verify (default) - once booted far enough, mark the slot good (reset counter)
# NOTE: the boot-attempt COUNT happens earlier, in the PID 1 boot-guard shim
# (/sbin/aa-boot-init), so it works even when the init system itself is broken.
install_ab_services() {
    local root="$1"
    # OpenRC init script; s6 defines aa-verify in setup_s6_init.
    [ "$INIT_SYSTEM" = "openrc" ] || return 0
    mkdir -p "${root}/etc/init.d"

    cat > "${root}/etc/init.d/aa-verify" << 'EOF'
#!/sbin/openrc-run
description="Alpine Anywhere: mark current A/B slot verified after a healthy boot"
depend() {
    after sshd net
}
start() {
    ebegin "Marking A/B slot as verified"
    /usr/local/bin/aa verify || true
    eend 0
}
EOF
    chmod +x "${root}/etc/init.d/aa-verify"

    chroot "$root" /sbin/rc-update add aa-verify default 2>/dev/null || true
}

# Configure the system image
configure_system_image() {
    local root="$1"

    log_info "Configuring system..."

    # Hostname
    echo "${DETECTED_HOSTNAME}" > "${root}/etc/hostname"

    # Network
    mkdir -p "${root}/etc/network"
    if [ "$NETWORK_IS_DHCP" = "true" ]; then
        cat > "${root}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto ${DETECTED_INTERFACE}
iface ${DETECTED_INTERFACE} inet dhcp
EOF
    else
        cat > "${root}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto ${DETECTED_INTERFACE}
iface ${DETECTED_INTERFACE} inet static
    address ${DETECTED_IP_ADDRESS}
    netmask ${DETECTED_NETMASK}
    gateway ${DETECTED_GATEWAY}
EOF
    fi

    # DNS
    cat > "${root}/etc/resolv.conf" << EOF
nameserver ${DETECTED_DNS%% *}
EOF

    # Enable services (OpenRC only; s6 services are defined in setup_s6_init)
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        chroot "$root" /sbin/rc-update add networking boot
        if [ "$HARDENED_MODE" = "true" ]; then
            chroot "$root" /sbin/rc-update add dropbear default
        else
            chroot "$root" /sbin/rc-update add sshd default
        fi
        chroot "$root" /sbin/rc-update add local default
        chroot "$root" /sbin/rc-update add chronyd default 2>/dev/null || true
    fi

    # Create immutable marker
    touch "${root}/etc/alpine-anywhere-immutable"

    # Create version file
    cat > "${root}/etc/alpine-anywhere-version" << EOF
VERSION=${ALPINE_VERSION}
BUILD_DATE=$(date -Iseconds)
ARCH=${DETECTED_ARCH}
EOF
}

# Setup SSH in system image
setup_system_ssh() {
    local root="$1"

    log_info "Configuring SSH..."

    mkdir -p "${root}/root/.ssh"
    chmod 700 "${root}/root/.ssh"

    # Copy authorized keys from apkovl
    if [ -f "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" ]; then
        tar -xzf "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" \
            -C "$root" ./root/.ssh/authorized_keys 2>/dev/null || true
    fi

    # Fallback
    if [ ! -s "${root}/root/.ssh/authorized_keys" ]; then
        cat ~/.ssh/authorized_keys >> "${root}/root/.ssh/authorized_keys" 2>/dev/null || true
        cat /root/.ssh/authorized_keys >> "${root}/root/.ssh/authorized_keys" 2>/dev/null || true
    fi

    chown -R 0:0 "${root}/root/.ssh"
    chmod 600 "${root}/root/.ssh/authorized_keys" 2>/dev/null || true

    # Configure SSH server
    if [ "$HARDENED_MODE" = "true" ]; then
        # Dropbear uses authorized_keys in same location, no config file needed
        # Dropbear configuration is handled by hardening.sh (via /etc/conf.d/dropbear)
        log_info "Using dropbear (key-only authentication)"
    else
        # Configure OpenSSH
        mkdir -p "${root}/etc/ssh"
        # No sftp Subsystem: the image ships no openssh-sftp-server, and remote
        # transfers use tar/cat over ssh instead of scp/sftp.
        cat > "${root}/etc/ssh/sshd_config" << 'EOF'
Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
EOF
    fi

    # Bake persistent SSH host keys so identity survives A/B upgrades
    persist_host_keys "$root"
}

# Capture the SOURCE host's existing SSH identity into $dest as canonical
# OpenSSH-format keys, regardless of whether the source runs OpenSSH or dropbear.
# Runs on the source system (before any wipe). Returns 0 if keys were captured.
# This is what lets an existing server keep its SSH identity after install.
capture_host_identity() {
    local dest="$1"
    mkdir -p "$dest"

    if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        cp /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub "$dest"/ 2>/dev/null
        log_info "Captured existing OpenSSH host identity"
        return 0
    fi

    if ls /etc/dropbear/dropbear_*_host_key >/dev/null 2>&1; then
        if ! command_exists dropbearconvert; then
            log_warn "dropbear host keys present but dropbearconvert missing; cannot preserve identity"
            return 1
        fi
        local dbk t
        for dbk in /etc/dropbear/dropbear_*_host_key; do
            t=$(basename "$dbk" | sed 's/^dropbear_\(.*\)_host_key$/\1/')
            if dropbearconvert dropbear openssh "$dbk" "${dest}/ssh_host_${t}_key" 2>/dev/null; then
                chmod 600 "${dest}/ssh_host_${t}_key"
                ssh-keygen -y -f "${dest}/ssh_host_${t}_key" > "${dest}/ssh_host_${t}_key.pub" 2>/dev/null || true
            fi
        done
        log_info "Captured + converted existing dropbear host identity"
        return 0
    fi

    return 1
}

# Bake persistent SSH host keys into the image so the server identity is stable
# across reboots AND A/B upgrades, and is PRESERVED when installing over an
# existing server — independent of OpenSSH vs dropbear on either side.
#
# Source of truth is always canonical OpenSSH-format keys (from --ssh-host-keys,
# an auto-captured dir, or the building system's /etc/ssh). They are emitted in
# the target's format: copied for OpenSSH, converted via dropbearconvert for
# dropbear (the hardened build chroot ships dropbearconvert). Missing key types
# are generated fresh.
persist_host_keys() {
    local root="$1"
    local srcdir="" ossh t

    # Locate canonical OpenSSH-format source keys
    if [ -n "$SSH_HOST_KEY_DIR" ] && ls "$SSH_HOST_KEY_DIR"/ssh_host_*_key >/dev/null 2>&1; then
        srcdir="$SSH_HOST_KEY_DIR"
    elif ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        srcdir="/etc/ssh"   # e.g. A/B upgrade building on the running OpenSSH system
    fi

    if [ "$HARDENED_MODE" = "true" ]; then
        mkdir -p "${root}/etc/dropbear"
        if [ -n "$srcdir" ]; then
            log_info "SSH identity: converting OpenSSH host keys -> dropbear (from $srcdir)"
            for ossh in "$srcdir"/ssh_host_*_key; do
                [ -f "$ossh" ] || continue
                t=$(basename "$ossh" | sed 's/^ssh_host_\(.*\)_key$/\1/')
                case "$t" in rsa|ed25519|ecdsa) ;; *) continue ;; esac  # dropbear-supported
                cp "$ossh" "${root}/tmp/aa_ih_${t}"
                chroot "$root" dropbearconvert openssh dropbear \
                    "/tmp/aa_ih_${t}" "/etc/dropbear/dropbear_${t}_host_key" >/dev/null 2>&1 || true
                rm -f "${root}/tmp/aa_ih_${t}"
            done
        fi
        # Generate any dropbear key types still missing
        [ -f "${root}/etc/dropbear/dropbear_ed25519_host_key" ] || \
            chroot "$root" dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1 || true
        [ -f "${root}/etc/dropbear/dropbear_rsa_host_key" ] || \
            chroot "$root" dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1 || true
        chmod 600 "${root}"/etc/dropbear/dropbear_*_host_key 2>/dev/null || true
    else
        mkdir -p "${root}/etc/ssh"
        if [ -n "$srcdir" ]; then
            log_info "SSH identity: reusing OpenSSH host keys (from $srcdir)"
            cp "$srcdir"/ssh_host_*_key "$srcdir"/ssh_host_*_key.pub "${root}/etc/ssh/" 2>/dev/null
        else
            log_info "SSH identity: none found, generating fresh OpenSSH host keys"
            chroot "$root" ssh-keygen -A >/dev/null 2>&1 || true
        fi
        chmod 600 "${root}"/etc/ssh/ssh_host_*_key 2>/dev/null || true
        chmod 644 "${root}"/etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
    fi
}


# =============================================================================
# Data Partition Setup (Overlay)
# =============================================================================

# Setup persistent data partition
setup_data_partition() {
    local data_mount="$1"

    log_step "Setting up data partition..."

    # Create overlay directories
    mkdir -p "${data_mount}/overlay/upper"
    mkdir -p "${data_mount}/overlay/work"
    mkdir -p "${data_mount}/apkovl"
    mkdir -p "${data_mount}/persist"

    # Create marker file
    cat > "${data_mount}/.alpine-anywhere-data" << EOF
VERSION=1
CREATED=$(date -Iseconds)
EOF

    log_info "Data partition configured"
}

# =============================================================================
# Main Installation Flow
# =============================================================================

# Run full A/B installation (must be run as root)
run_ab_install() {
    if [ "$(id -u)" -ne 0 ]; then
        die "run_ab_install must be run as root"
    fi

    log_step "Starting A/B installation..."

    # Explicit --disk wins; otherwise auto-detect (which refuses to guess when
    # more than one disk is present, to avoid wiping the SD/boot medium).
    local disk
    if [ -n "$TARGET_DISK" ]; then
        disk="$TARGET_DISK"
        [ -b "$disk" ] || die "--disk $disk is not a block device"
        log_info "Target disk (explicit --disk): $disk ($(get_disk_size_mb "$disk")MB)"
    else
        disk=$(detect_root_disk)
        log_info "Target disk (auto-detected): $disk ($(get_disk_size_mb "$disk")MB)"
    fi

    # Confirm
    if [ "$FORCE" != "true" ]; then
        echo ""
        echo "WARNING: This will ERASE ALL DATA on $disk"
        echo ""
        confirm_action "Proceed with installation on $disk?"
    fi

    local with_data=true

    # Step 1: Partition disk
    create_partition_layout "$disk" "$with_data"
    format_partitions "$disk" "$with_data"

    # Step 2: Build system image
    local squashfs="/tmp/system.squashfs"
    generate_system_squashfs "$squashfs"

    # Step 3: Write squashfs to slot A (durable + read-back verified, and if
    # enabled, with a dm-verity hash tree so the root is cryptographically
    # verified block-by-block at runtime).
    local slota_dev slota_sha slota_vmeta=""
    slota_dev=$(get_part_dev "$disk" 2)
    log_step "Writing squashfs to slot A ($slota_dev)..."
    if verity_enabled; then
        slota_vmeta=$(format_verity_slot "$squashfs" "$slota_dev")
        slota_sha=$(sha256_file "$squashfs")
    else
        slota_sha=$(write_image_to_device "$squashfs" "$slota_dev")
    fi
    log_info "Slot A written: $(du -h "$squashfs" | cut -f1)"

    # Step 4: Install boot files
    local boot_dev
    boot_dev=$(get_part_dev "$disk" 1)
    local boot_mnt="/mnt/boot"
    mkdir -p "$boot_mnt"
    require mount "$boot_dev" "$boot_mnt"
    assert_mounted "$boot_mnt"

    log_step "Installing boot files..."
    # Shared boot files: firmware, DTBs, overlays (identical for both slots)
    cp /tmp/boot-files/*.elf /tmp/boot-files/*.dat /tmp/boot-files/*.bin "$boot_mnt/" 2>/dev/null || true
    cp /tmp/boot-files/*.dtb "$boot_mnt/" 2>/dev/null || true
    cp -r /tmp/boot-files/overlays "$boot_mnt/" 2>/dev/null || true
    # Per-slot kernel: slot A gets vmlinuz-A / initramfs-A
    place_slot_kernel "$boot_mnt" "A" "/tmp/boot-files/vmlinuz" "/tmp/boot-files/initramfs"

    # Step 5: Configure bootloader
    install_boot_config "$boot_mnt" "$disk"

    # Copy alpine-anywhere scripts to boot partition for future upgrades
    mkdir -p "${boot_mnt}/alpine-anywhere/lib"
    cp "${INSTALL_BASE_DIR}/alpine-anywhere" "${boot_mnt}/alpine-anywhere/" 2>/dev/null || \
        cp "${SCRIPT_DIR}/alpine-anywhere" "${boot_mnt}/alpine-anywhere/" 2>/dev/null || true
    cp "${INSTALL_BASE_DIR}"/lib/*.sh "${boot_mnt}/alpine-anywhere/lib/" 2>/dev/null || \
        cp "${SCRIPT_DIR}"/lib/*.sh "${boot_mnt}/alpine-anywhere/lib/" 2>/dev/null || true
    # initramfs payloads (init.aa, aa-verity-open) so future upgrades on-device
    # can re-wrap the initramfs without network access.
    mkdir -p "${boot_mnt}/alpine-anywhere/lib/initramfs"
    cp "${INSTALL_LIB_DIR}"/initramfs/* "${boot_mnt}/alpine-anywhere/lib/initramfs/" 2>/dev/null || \
        cp "${SCRIPT_DIR}"/lib/initramfs/* "${boot_mnt}/alpine-anywhere/lib/initramfs/" 2>/dev/null || true
    chmod +x "${boot_mnt}/alpine-anywhere/alpine-anywhere" 2>/dev/null || true

    # Step 6: Setup data partition (phase 3 prep)
    if [ "$with_data" = "true" ]; then
        local data_dev
        data_dev=$(get_part_dev "$disk" 4)
        mkdir -p /mnt/data
        require mount "$data_dev" /mnt/data
        assert_mounted /mnt/data
        setup_data_partition /mnt/data
        require umount /mnt/data
    fi

    # Cleanup
    require umount "$boot_mnt"
    rm -f "$squashfs"
    rm -rf /tmp/boot-files

    # Create slot metadata on boot partition.
    # current_slot: single-line slot letter (A/B), read by upgrade.sh.
    # slots.meta:   KEY=VALUE per-slot metadata (version/date/verified/boot count).
    require mount "$boot_dev" "$boot_mnt"
    assert_mounted "$boot_mnt"
    printf 'A\n' | atomic_write "${boot_mnt}/current_slot"

    # Optional dm-verity fields for slot A (ROOT_HASH SALT DATA_SIZE HASH_OFFSET).
    local slota_verity_lines=""
    if [ -n "$slota_vmeta" ]; then
        set -- $slota_vmeta
        slota_verity_lines="SLOT_A_ROOT_HASH=$1
SLOT_A_SALT=$2
SLOT_A_DATA_SIZE=$3
SLOT_A_HASH_OFFSET=$4"
    fi

    cat <<EOF | atomic_write "${boot_mnt}/slots.meta"
SLOT_A_VERSION=${ALPINE_VERSION}
SLOT_A_INSTALLED=$(date -Iseconds)
SLOT_A_VERIFIED=true
SLOT_A_BOOT_COUNT=0
SLOT_A_SHA256=${slota_sha}
${slota_verity_lines}
SLOT_B_VERSION=
SLOT_B_INSTALLED=
SLOT_B_VERIFIED=false
SLOT_B_BOOT_COUNT=0
EOF
    require umount "$boot_mnt"

    log_info "==================================="
    log_info "A/B installation complete!"
    log_info "Slot A: Alpine ${ALPINE_VERSION}"
    log_info "Slot B: empty (ready for upgrade)"
    log_info "==================================="
}

# Install an image into a specific slot of an EXISTING A/B layout, without
# repartitioning and without changing the active slot. Used for `--install
# --slot B` (e.g. building a second variant alongside the current one).
# Use `aa switch <slot>` afterwards to boot it.
install_secondary_slot() {
    local disk="$1" slot="$2"
    local partnum dev sq boot_dev

    partnum=$(slot_to_partnum "$slot")
    dev=$(get_part_dev "$disk" "$partnum")
    [ -b "$dev" ] || die "Slot $slot partition ($dev) not found — run a full install first"

    log_step "Installing to slot $slot ($dev) on the existing layout (init: ${INIT_SYSTEM})..."
    sq="/tmp/system-${slot}.squashfs"
    generate_system_squashfs "$sq"   # builds image, wraps initramfs, saves /tmp/boot-files
    log_step "Writing image to slot $slot ($dev)..."
    local slot_sha slot_vmeta=""
    if verity_enabled; then
        slot_vmeta=$(format_verity_slot "$sq" "$dev")
        slot_sha=$(sha256_file "$sq")
    else
        slot_sha=$(write_image_to_device "$sq" "$dev")
    fi
    log_info "Slot $slot written: $(du -h "$sq" | cut -f1)"

    boot_dev=$(get_part_dev "$disk" 1)
    BOOT_MNT="/mnt/aa-boot"
    mkdir -p "$BOOT_MNT"
    require mount "$boot_dev" "$BOOT_MNT"
    assert_mounted "$BOOT_MNT"
    place_slot_kernel "$BOOT_MNT" "$slot" "/tmp/boot-files/vmlinuz" "/tmp/boot-files/initramfs"
    set_slot_meta "$slot" "VERSION" "$ALPINE_VERSION"
    set_slot_meta "$slot" "INSTALLED" "$(date -Iseconds)"
    set_slot_meta "$slot" "VERIFIED" "false"
    set_slot_meta "$slot" "BOOT_COUNT" "0"
    set_slot_meta "$slot" "SHA256" "$slot_sha"
    if [ -n "$slot_vmeta" ]; then
        set -- $slot_vmeta
        set_slot_meta "$slot" "ROOT_HASH" "$1"
        set_slot_meta "$slot" "SALT" "$2"
        set_slot_meta "$slot" "DATA_SIZE" "$3"
        set_slot_meta "$slot" "HASH_OFFSET" "$4"
    fi
    sync
    require umount "$BOOT_MNT"

    rm -f "$sq"; rm -rf /tmp/boot-files
    log_info "Slot $slot installed; active slot unchanged. Boot it with: aa switch $slot && reboot"
}

# =============================================================================
# Slot / Boot helpers (shared by install.sh and upgrade.sh)
# =============================================================================

# Map a slot letter to its GPT partition number (A=2, B=3)
slot_to_partnum() {
    case "$1" in
        A) echo 2 ;;
        B) echo 3 ;;
        *) die "Invalid slot: $1" ;;
    esac
}

# Kernel cmdline shared by both slots (root= is appended per-slot).
# The A/B boot-guard is /sbin/init.aa, invoked by the (patched) Alpine initramfs
# init right BEFORE switch_root — i.e. in the initramfs once modules are loaded,
# busybox is ready and the disk is accessible, but before handing off to the
# real init. (init=/sbin/aa-boot-init failed: switch_root couldn't exec it;
# rdinit=/init.aa was ignored; a first-thing /init guard hit a too-bare env.)
# - panic=10: a dying init (PID 1 exit -> kernel panic) reboots after 10s so a
#   broken-but-mountable slot accumulates failed boots toward rollback.
SLOT_KERNEL_OPTS="rootfstype=squashfs overlaytmpfs=yes modules=loop,squashfs panic=10 console=tty1 quiet"

# Kernel opts including the optional dm-verity toggle. Computed at use time
# because VERITY_MODE/HARDENED_MODE are set by parse_arguments, after sourcing.
slot_kernel_opts() {
    if verity_enabled; then
        echo "${SLOT_KERNEL_OPTS} aaverity=1"
    else
        echo "${SLOT_KERNEL_OPTS}"
    fi
}

# Place a slot's kernel + initramfs on the boot partition as vmlinuz-<slot>/initramfs-<slot>
place_slot_kernel() {
    local boot_mnt="$1" slot="$2" src_vmlinuz="$3" src_initramfs="$4"
    cp "$src_vmlinuz"   "${boot_mnt}/vmlinuz-${slot}"
    cp "$src_initramfs" "${boot_mnt}/initramfs-${slot}"
}

# Install boot configuration (config.txt, cmdline.txt for RPi, extlinux for others)
# Configures the boot partition to boot the given slot (default A).
install_boot_config() {
    local boot_mnt="$1"
    local disk="$2"
    local slot="${3:-A}"

    local slot_dev partnum
    partnum=$(slot_to_partnum "$slot")
    slot_dev=$(get_part_dev "$disk" "$partnum")

    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        log_info "Configuring Raspberry Pi boot (slot $slot)..."

        # NOTE: arm_64bit=1 is REQUIRED — the linux-rpi4 kernel is a 64-bit
        # ARM64 Image; without this the firmware loads a multicolour screen
        # and never starts the kernel.
        cat > "${boot_mnt}/config.txt" << EOF
# Alpine Anywhere - Raspberry Pi
arm_64bit=1
disable_overscan=1
arm_boost=1
enable_uart=1

[pi4]
kernel=vmlinuz-${slot}
initramfs initramfs-${slot} followkernel
max_framebuffers=2

[pi5]
kernel=vmlinuz-${slot}
initramfs initramfs-${slot} followkernel

[all]
EOF

        echo "root=${slot_dev} $(slot_kernel_opts)" > "${boot_mnt}/cmdline.txt"

        log_info "Boot config: slot $slot, kernel vmlinuz-${slot}, root=${slot_dev}"
    else
        # x86_64 / generic: extlinux with per-slot kernels
        local slota_dev slotb_dev
        slota_dev=$(get_part_dev "$disk" 2)
        slotb_dev=$(get_part_dev "$disk" 3)
        mkdir -p "${boot_mnt}/extlinux"
        cat > "${boot_mnt}/extlinux/extlinux.conf" << EOF
DEFAULT alpine-${slot}
TIMEOUT 30
PROMPT 1

LABEL alpine-A
    MENU LABEL Alpine Linux (Slot A)
    LINUX /vmlinuz-A
    INITRD /initramfs-A
    APPEND root=${slota_dev} $(slot_kernel_opts)

LABEL alpine-B
    MENU LABEL Alpine Linux (Slot B)
    LINUX /vmlinuz-B
    INITRD /initramfs-B
    APPEND root=${slotb_dev} $(slot_kernel_opts)
EOF
        log_info "Boot config: extlinux default slot $slot"
    fi
}
