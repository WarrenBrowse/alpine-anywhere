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
        # Running from RAM - find first physical disk
        disk=$(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}')
        if [ -z "$disk" ]; then
            die "No physical disk found"
        fi
        log_debug "Running from tmpfs, using first disk: $disk"
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
    parted -s "$disk" mkpart slot_a ext4 "${PART_BOOT_SIZE_MB}MiB" "$((PART_BOOT_SIZE_MB + PART_SLOT_SIZE_MB))MiB"

    log_info "Creating slot B partition (${PART_SLOT_SIZE_MB}MB)..."
    parted -s "$disk" mkpart slot_b ext4 "$((PART_BOOT_SIZE_MB + PART_SLOT_SIZE_MB))MiB" "${slot_end_mb}MiB"

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
generate_system_squashfs() {
    local squashfs_output="$1"

    log_step "Building Alpine system image..."

    local build_dir
    build_dir=$(mktemp -d)

    # Extract minirootfs
    log_info "Extracting base system..."
    if [ -f "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" ]; then
        tar -xzf "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" -C "$build_dir"
    else
        local minirootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz"
        curl -fSL "$minirootfs_url" | tar xz -C "$build_dir"
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
        ssh_pkg="dropbear dropbear-openrc"
    fi

    chroot "$build_dir" /sbin/apk add --no-cache \
        alpine-base openrc busybox-openrc \
        "$kernel_pkg" linux-firmware-none \
        mkinitfs \
        $ssh_pkg \
        e2fsprogs dosfstools \
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

    # Create squashfs
    log_info "Creating squashfs image..."
    mksquashfs "$build_dir" "$squashfs_output" \
        -comp zstd -noappend -no-progress

    rm -rf "$build_dir"

    log_info "System image: $(du -h "$squashfs_output" | cut -f1)"
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

    # Enable services
    chroot "$root" /sbin/rc-update add networking boot
    if [ "$HARDENED_MODE" = "true" ]; then
        chroot "$root" /sbin/rc-update add dropbear default
    else
        chroot "$root" /sbin/rc-update add sshd default
    fi
    chroot "$root" /sbin/rc-update add local default
    chroot "$root" /sbin/rc-update add chronyd default 2>/dev/null || true

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
        cat > "${root}/etc/ssh/sshd_config" << 'EOF'
Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
Subsystem sftp /usr/lib/ssh/sftp-server
EOF
    fi
}

# =============================================================================
# Bootloader Configuration
# =============================================================================

# Setup bootloader for A/B scheme
setup_bootloader() {
    local esp_mount="$1"
    local boot_mount="$2"
    local arch="$3"

    log_step "Setting up bootloader..."

    case "$arch" in
        x86_64)
            setup_bootloader_x86 "$esp_mount" "$boot_mount"
            ;;
        aarch64)
            setup_bootloader_arm64 "$esp_mount" "$boot_mount"
            ;;
        *)
            die "Unsupported architecture for bootloader: $arch"
            ;;
    esac
}

# Setup GRUB for x86_64
setup_bootloader_x86() {
    local esp_mount="$1"
    local boot_mount="$2"

    log_info "Installing GRUB for x86_64..."

    # Install GRUB EFI
    mkdir -p "${esp_mount}/EFI/BOOT"

    # Create GRUB config
    cat > "${boot_mount}/bootloader/grub.cfg" << 'EOF'
set timeout=3
set default=0

# Load current slot
if [ -f /current_slot ]; then
    . /current_slot
else
    set slot=A
fi

menuentry "Alpine Linux (Slot ${slot})" {
    linux /slots/${slot}/vmlinuz root=live:LABEL=ALPINE_BOOT rd.live.dir=/slots/${slot} rd.live.squashimg=system.squashfs ro quiet
    initrd /slots/${slot}/initramfs
}

menuentry "Alpine Linux (Slot A)" {
    linux /slots/A/vmlinuz root=live:LABEL=ALPINE_BOOT rd.live.dir=/slots/A rd.live.squashimg=system.squashfs ro quiet
    initrd /slots/A/initramfs
}

menuentry "Alpine Linux (Slot B)" {
    linux /slots/B/vmlinuz root=live:LABEL=ALPINE_BOOT rd.live.dir=/slots/B rd.live.squashimg=system.squashfs ro quiet
    initrd /slots/B/initramfs
}
EOF
}

# Setup extlinux for ARM64 (Raspberry Pi, etc.)
setup_bootloader_arm64() {
    local esp_mount="$1"
    local boot_mount="$2"

    log_info "Setting up extlinux for ARM64..."

    mkdir -p "${boot_mount}/bootloader"

    # Create extlinux config
    mkdir -p "${boot_mount}/extlinux"
    cat > "${boot_mount}/extlinux/extlinux.conf" << EOF
DEFAULT alpine
TIMEOUT 30
PROMPT 1

LABEL alpine
    MENU LABEL Alpine Linux (Current Slot)
    LINUX /slots/A/vmlinuz
    INITRD /slots/A/initramfs
    APPEND root=live:LABEL=ALPINE_BOOT rd.live.dir=/slots/A rd.live.squashimg=system.squashfs ro quiet

LABEL alpine-a
    MENU LABEL Alpine Linux (Slot A)
    LINUX /slots/A/vmlinuz
    INITRD /slots/A/initramfs
    APPEND root=live:LABEL=ALPINE_BOOT rd.live.dir=/slots/A rd.live.squashimg=system.squashfs ro quiet

LABEL alpine-b
    MENU LABEL Alpine Linux (Slot B)
    LINUX /slots/B/vmlinuz
    INITRD /slots/B/initramfs
    APPEND root=live:LABEL=ALPINE_BOOT rd.live.dir=/slots/B rd.live.squashimg=system.squashfs ro quiet
EOF

    # For Raspberry Pi, also create config.txt
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        setup_rpi_boot "$boot_mount"
    fi
}

# Setup Raspberry Pi specific boot files
setup_rpi_boot() {
    local boot_mount="$1"

    log_info "Configuring Raspberry Pi boot..."

    # Copy RPi firmware files
    if [ -f "${INSTALL_CACHE_DIR}/alpine-rpi-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz" ]; then
        tar -xzf "${INSTALL_CACHE_DIR}/alpine-rpi-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz" \
            -C "$boot_mount" \
            --strip-components=1 \
            '*.bin' '*.elf' '*.dat' 'overlays' 2>/dev/null || true
    fi

    # Create config.txt
    cat > "${boot_mount}/config.txt" << 'EOF'
# Alpine Anywhere - Raspberry Pi Configuration
disable_overscan=1
dtparam=audio=on

# Boot from extlinux
enable_uart=1

[pi4]
max_framebuffers=2
arm_boost=1

[all]
EOF

    # Create cmdline.txt
    echo "root=live:LABEL=ALPINE_BOOT rd.live.dir=/slots/A rd.live.squashimg=system.squashfs ro quiet" > "${boot_mount}/cmdline.txt"
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

    local disk
    disk=$(detect_root_disk)
    log_info "Target disk: $disk ($(get_disk_size_mb "$disk")MB)"

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
    # Copy kernel, initramfs, dtbs, firmware from build
    cp /tmp/boot-files/* "$boot_mnt/" 2>/dev/null || true
    cp -r /tmp/boot-files/overlays "$boot_mnt/" 2>/dev/null || true

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

    # Create slot metadata on boot partition
    mount "$boot_dev" "$boot_mnt"
    cat > "${boot_mnt}/current_slot" << EOF
CURRENT_SLOT=A
SLOT_A_VERSION=${ALPINE_VERSION}
SLOT_A_DATE=$(date -Iseconds)
SLOT_B_VERSION=
SLOT_B_DATE=
EOF
    umount "$boot_mnt"

    log_info "==================================="
    log_info "A/B installation complete!"
    log_info "Slot A: Alpine ${ALPINE_VERSION}"
    log_info "Slot B: empty (ready for upgrade)"
    log_info "==================================="
}

# Install boot configuration (config.txt, cmdline.txt for RPi, extlinux for others)
install_boot_config() {
    local boot_mnt="$1"
    local disk="$2"

    local slota_dev slotb_dev
    slota_dev=$(get_part_dev "$disk" 2)
    slotb_dev=$(get_part_dev "$disk" 3)

    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        log_info "Configuring Raspberry Pi boot..."

        cat > "${boot_mnt}/config.txt" << 'EOF'
# Alpine Anywhere - Raspberry Pi
disable_overscan=1
arm_boost=1
enable_uart=1

[pi4]
kernel=vmlinuz
initramfs initramfs followkernel
max_framebuffers=2

[pi5]
kernel=vmlinuz
initramfs initramfs followkernel

[all]
EOF

        # cmdline.txt points to slot A
        echo "root=${slota_dev} rootfstype=squashfs overlaytmpfs=yes modules=loop,squashfs console=tty1 quiet" \
            > "${boot_mnt}/cmdline.txt"

        log_info "Boot config: root=${slota_dev} (squashfs + tmpfs overlay)"
    else
        # x86_64 / generic: use extlinux or GRUB
        mkdir -p "${boot_mnt}/extlinux"
        cat > "${boot_mnt}/extlinux/extlinux.conf" << EOF
DEFAULT alpine-a
TIMEOUT 30
PROMPT 1

LABEL alpine-a
    MENU LABEL Alpine Linux (Slot A)
    LINUX /vmlinuz
    INITRD /initramfs
    APPEND root=${slota_dev} rootfstype=squashfs overlaytmpfs=yes modules=loop,squashfs quiet

LABEL alpine-b
    MENU LABEL Alpine Linux (Slot B)
    LINUX /vmlinuz
    INITRD /initramfs
    APPEND root=${slotb_dev} rootfstype=squashfs overlaytmpfs=yes modules=loop,squashfs quiet
EOF
    fi
}
