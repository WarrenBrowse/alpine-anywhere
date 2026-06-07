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

    # First, look for existing data partitions on root disk
    get_partition_info "$root_disk" | while IFS= read -r line; do
        local part size fstype label mount
        part=$(echo "$line" | awk '{print $1}')
        fstype=$(echo "$line" | awk '{print $3}')
        label=$(echo "$line" | awk '{print $4}')
        mount=$(echo "$line" | awk '{print $5}')

        # Skip if mounted as / or /boot
        case "$mount" in
            /|/boot*) continue ;;
        esac

        local status
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
    done

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
    parted -s "$disk" mklabel gpt

    log_info "Creating boot partition (${PART_BOOT_SIZE_MB}MB, FAT32)..."
    parted -s "$disk" mkpart boot fat32 1MiB "${PART_BOOT_SIZE_MB}MiB"
    parted -s "$disk" set 1 boot on

    log_info "Creating slot A partition (${PART_SLOT_SIZE_MB}MB)..."
    parted -s "$disk" mkpart slota ext4 "${PART_BOOT_SIZE_MB}MiB" "$((PART_BOOT_SIZE_MB + PART_SLOT_SIZE_MB))MiB"

    log_info "Creating slot B partition (${PART_SLOT_SIZE_MB}MB)..."
    parted -s "$disk" mkpart slotb ext4 "$((PART_BOOT_SIZE_MB + PART_SLOT_SIZE_MB))MiB" "${slot_end_mb}MiB"

    if [ "$with_data" = "true" ]; then
        log_info "Creating data partition (remaining space)..."
        parted -s "$disk" mkpart data ext4 "${slot_end_mb}MiB" 100%
    fi

    # Try to re-read partition table
    sleep 2
    partprobe "$disk" 2>/dev/null || true
    blockdev --rereadpt "$disk" 2>/dev/null || true
    sleep 1

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

    local part_num=0
    echo "$part_info" | while IFS= read -r line; do
        part_num=$((part_num + 1))
        local start size
        start=$(echo "$line" | sed -n 's/.*start= *\([0-9]*\).*/\1/p')
        size=$(echo "$line" | sed -n 's/.*size= *\([0-9]*\).*/\1/p')
        if [ -n "$start" ] && [ -n "$size" ]; then
            local loop="/dev/loop$((part_num - 1))"
            losetup -d "$loop" 2>/dev/null || true
            losetup -o $((start * 512)) --sizelimit $((size * 512)) "$loop" "$disk"
            log_debug "  $loop -> offset=$start size=$size sectors"
        fi
    done

    # Export loop device mapping
    PART_BOOT_DEV="/dev/loop0"
    PART_SLOTA_DEV="/dev/loop1"
    PART_SLOTB_DEV="/dev/loop2"
    PART_DATA_DEV="/dev/loop3"
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
    mkfs.vfat -F 32 -n ALPINE_BOOT "$boot_dev"

    # Slot A and B are raw (squashfs written directly), no formatting needed
    log_info "Slot A and B: raw partitions (squashfs will be written directly)"

    if [ "$with_data" = "true" ]; then
        data_dev=$(get_part_dev "$disk" 4)
        log_info "Formatting data partition ($data_dev, ext4)..."
        mkfs.ext4 -L ALPINE_DATA -q -F "$data_dev"
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

    # Extract minirootfs
    log_info "Extracting base system..."
    if [ -f "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" ]; then
        tar -xzf "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" -C "$build_dir"
    else
        local minirootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz"
        http_fetch_stdout "$minirootfs_url" | tar xz -C "$build_dir"
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

    # Determine kernel package based on platform
    local kernel_pkg="linux-lts"
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        kernel_pkg="linux-rpi4"
    fi

    # Configure mkinitfs to include squashfs BEFORE installing kernel
    mkdir -p "${build_dir}/etc/mkinitfs"
    echo 'features="ata base cdrom ext4 keymap kms mmc nvme scsi usb virtio squashfs"' \
        > "${build_dir}/etc/mkinitfs/mkinitfs.conf"

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

    # squashfs-tools is needed on the installed system so `alpine-anywhere
    # upgrade` can build the next slot's image in place.
    chroot "$build_dir" /sbin/apk add --no-cache \
        alpine-base $init_pkg \
        "$kernel_pkg" linux-firmware-none \
        mkinitfs \
        $ssh_pkg \
        e2fsprogs dosfstools squashfs-tools \
        chrony ca-certificates curl

    # RPi: install firmware package
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        chroot "$build_dir" /sbin/apk add --no-cache raspberrypi-bootloader
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

    # Add the A/B boot-guard to the initramfs (same image used for both slots;
    # it reads the booted slot from root= at runtime).
    [ -f /tmp/boot-files/initramfs ] && wrap_boot_initramfs /tmp/boot-files/initramfs

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

# Bake the alpine-anywhere CLI + A/B services into the image so the installed
# system can run `alpine-anywhere status|verify|rollback` and auto-rollback at boot.
bake_management_tools() {
    local root="$1"
    local src_cli src_lib
    local dest="${root}/usr/local/lib/alpine-anywhere"

    if [ -f "${INSTALL_BASE_DIR}/alpine-anywhere" ]; then
        src_cli="${INSTALL_BASE_DIR}/alpine-anywhere"; src_lib="${INSTALL_BASE_DIR}/lib"
    elif [ -f "${SCRIPT_DIR}/alpine-anywhere" ]; then
        src_cli="${SCRIPT_DIR}/alpine-anywhere"; src_lib="${SCRIPT_DIR}/lib"
    else
        log_warn "alpine-anywhere CLI source not found; skipping management tools"
        return 0
    fi

    log_info "Baking alpine-anywhere management CLI into image..."
    mkdir -p "${dest}/lib" "${root}/usr/local/sbin"
    cp "$src_cli" "${dest}/alpine-anywhere"
    cp "$src_lib"/*.sh "${dest}/lib/"
    chmod +x "${dest}/alpine-anywhere"

    # PATH wrapper. exec (not symlink): the CLI derives its lib dir from $0,
    # which a symlink would resolve to the wrong directory.
    cat > "${root}/usr/local/sbin/alpine-anywhere" << 'EOF'
#!/bin/sh
exec /usr/local/lib/alpine-anywhere/alpine-anywhere "$@"
EOF
    chmod +x "${root}/usr/local/sbin/alpine-anywhere"
    # Also expose on /usr/sbin: dropbear's non-interactive PATH does not include
    # /usr/local/sbin, so `alpine-anywhere ...` would be "not found" otherwise.
    mkdir -p "${root}/usr/sbin"
    ln -sf /usr/local/sbin/alpine-anywhere "${root}/usr/sbin/alpine-anywhere"

    install_ab_services "$root"
}

# Wrap an Alpine mkinitfs initramfs with an A/B boot-guard, in place.
# The guard runs BEFORE the real init: it counts the boot attempt (rolling back
# after too many unverified tries) and, crucially, rolls back immediately if the
# slot's squashfs won't mount at all — then hands off to the original Alpine init
# for the real root setup. Best-effort: any guard failure falls through to a
# normal boot (exec /init.alpine), so a bug here cannot brick the boot.
wrap_boot_initramfs() {
    local img="$1"        # initramfs image to wrap (modified in place)
    local src_cli src_lib
    if [ -f "${INSTALL_BASE_DIR}/alpine-anywhere" ]; then
        src_cli="${INSTALL_BASE_DIR}/alpine-anywhere"; src_lib="${INSTALL_BASE_DIR}/lib"
    elif [ -f "${SCRIPT_DIR}/alpine-anywhere" ]; then
        src_cli="${SCRIPT_DIR}/alpine-anywhere"; src_lib="${SCRIPT_DIR}/lib"
    else
        log_warn "CLI source not found; skipping initramfs boot-guard"
        return 0
    fi

    log_info "Wrapping initramfs with A/B boot-guard..."
    local tmp; tmp=$(mktemp -d)
    ( cd "$tmp" && gzip -dc "$img" 2>/dev/null | cpio -idm 2>/dev/null ) || {
        log_warn "Could not unpack initramfs; skipping boot-guard"; rm -rf "$tmp"; return 0; }
    [ -f "$tmp/init" ] || { log_warn "initramfs has no /init; skipping"; rm -rf "$tmp"; return 0; }

    mv "$tmp/init" "$tmp/init.alpine"
    mkdir -p "$tmp/usr/local/lib/alpine-anywhere/lib" "$tmp/usr/local/sbin"
    cp "$src_cli" "$tmp/usr/local/lib/alpine-anywhere/alpine-anywhere"
    cp "$src_lib"/*.sh "$tmp/usr/local/lib/alpine-anywhere/lib/"
    cat > "$tmp/usr/local/sbin/alpine-anywhere" << 'EOF'
#!/bin/sh
exec /usr/local/lib/alpine-anywhere/alpine-anywhere "$@"
EOF
    chmod +x "$tmp/usr/local/sbin/alpine-anywhere" "$tmp/usr/local/lib/alpine-anywhere/alpine-anywhere"

    cat > "$tmp/init" << 'EOF'
#!/bin/sh
# A/B boot-guard (best-effort) -> hand off to the real Alpine init.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
for m in sd-mod usb-storage uas scsi_mod nvme mmcblk squashfs loop ext4 vfat overlay; do
    modprobe "$m" 2>/dev/null
done
root=$(sed -n 's/.*root=\([^ ]*\).*/\1/p' /proc/cmdline)
i=0; while [ -n "$root" ] && [ ! -b "$root" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
if [ -n "$root" ] && [ -b "$root" ]; then
    # count this attempt (rolls back after too many unverified boots)
    /usr/local/sbin/alpine-anywhere bootcount 2>/dev/null || true
    # unmountable-slot guard: a slot whose squashfs won't mount is bad now
    mkdir -p /aa-test
    if mount -t squashfs -o ro "$root" /aa-test 2>/dev/null; then
        umount /aa-test 2>/dev/null
    else
        echo "[boot-guard] $root squashfs unmountable -> rolling back" > /dev/console 2>&1
        /usr/local/sbin/alpine-anywhere rollback 2>/dev/null
        sleep 3; reboot -f
    fi
fi
exec /init.alpine
EOF
    chmod +x "$tmp/init"

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
    /usr/local/sbin/alpine-anywhere verify || true
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

    # Step 3: Write squashfs to slot A
    local slota_dev
    slota_dev=$(get_part_dev "$disk" 2)
    log_step "Writing squashfs to slot A ($slota_dev)..."
    dd if="$squashfs" of="$slota_dev" bs=1M 2>/dev/null
    sync
    log_info "Slot A written: $(du -h "$squashfs" | cut -f1)"

    # Step 4: Install boot files
    local boot_dev
    boot_dev=$(get_part_dev "$disk" 1)
    local boot_mnt="/mnt/boot"
    mkdir -p "$boot_mnt"
    mount "$boot_dev" "$boot_mnt"

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
    chmod +x "${boot_mnt}/alpine-anywhere/alpine-anywhere" 2>/dev/null || true

    # Step 6: Setup data partition (phase 3 prep)
    if [ "$with_data" = "true" ]; then
        local data_dev
        data_dev=$(get_part_dev "$disk" 4)
        mkdir -p /mnt/data
        mount "$data_dev" /mnt/data
        setup_data_partition /mnt/data
        umount /mnt/data
    fi

    # Cleanup
    umount "$boot_mnt"
    rm -f "$squashfs"
    rm -rf /tmp/boot-files

    # Create slot metadata on boot partition.
    # current_slot: single-line slot letter (A/B), read by upgrade.sh.
    # slots.meta:   KEY=VALUE per-slot metadata (version/date/verified/boot count).
    mount "$boot_dev" "$boot_mnt"
    echo "A" > "${boot_mnt}/current_slot"
    cat > "${boot_mnt}/slots.meta" << EOF
SLOT_A_VERSION=${ALPINE_VERSION}
SLOT_A_INSTALLED=$(date -Iseconds)
SLOT_A_VERIFIED=true
SLOT_A_BOOT_COUNT=0
SLOT_B_VERSION=
SLOT_B_INSTALLED=
SLOT_B_VERIFIED=false
SLOT_B_BOOT_COUNT=0
EOF
    umount "$boot_mnt"

    log_info "==================================="
    log_info "A/B installation complete!"
    log_info "Slot A: Alpine ${ALPINE_VERSION}"
    log_info "Slot B: empty (ready for upgrade)"
    log_info "==================================="
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
# The A/B boot-guard lives in the initramfs (wrap_boot_initramfs): it counts
# boot attempts and rolls back BEFORE mounting the root, and rolls back
# immediately if the slot's squashfs won't even mount.
# - panic=10: a dying init (PID 1 exit -> kernel panic) reboots after 10s so a
#   broken-but-mountable slot also accumulates failed boots toward rollback.
SLOT_KERNEL_OPTS="rootfstype=squashfs overlaytmpfs=yes modules=loop,squashfs panic=10 console=tty1 quiet"

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

        echo "root=${slot_dev} ${SLOT_KERNEL_OPTS}" > "${boot_mnt}/cmdline.txt"

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
    APPEND root=${slota_dev} ${SLOT_KERNEL_OPTS}

LABEL alpine-B
    MENU LABEL Alpine Linux (Slot B)
    LINUX /vmlinuz-B
    INITRD /initramfs-B
    APPEND root=${slotb_dev} ${SLOT_KERNEL_OPTS}
EOF
        log_info "Boot config: extlinux default slot $slot"
    fi
}
