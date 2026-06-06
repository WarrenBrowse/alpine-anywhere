#!/bin/bash
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
# 1: EFI System Partition (ESP) - 256MB - FAT32
# 2: Boot partition - 512MB - ext4 (contains A/B slots)
# 3: Data partition - remaining - ext4 (optional, for overlay)

PART_ESP_SIZE="256M"
PART_BOOT_SIZE="512M"
MIN_DISK_SIZE_MB=1024

# =============================================================================
# Disk Detection
# =============================================================================

# Detect the root disk
detect_root_disk() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p$//')

    # Handle /dev/mmcblk0p1 -> /dev/mmcblk0
    if [[ "$root_dev" =~ mmcblk|nvme ]]; then
        root_dev=$(echo "$root_dev" | sed 's/p$//')
    fi

    echo "$root_dev"
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
    if [[ "$fstype" == "ext4" ]]; then
        # Prefer partitions with data-related labels
        if [[ "$label" =~ DATA|data|home|persist ]]; then
            echo "preferred"
        else
            echo "usable"
        fi
    elif [[ -z "$fstype" ]]; then
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
    while IFS= read -r line; do
        local part size fstype label mount
        part=$(echo "$line" | awk '{print $1}')
        fstype=$(echo "$line" | awk '{print $3}')
        label=$(echo "$line" | awk '{print $4}')
        mount=$(echo "$line" | awk '{print $5}')

        # Skip if mounted as / or /boot
        [[ "$mount" == "/" || "$mount" == "/boot"* ]] && continue

        local status
        status=$(is_usable_data_partition "$part")

        case "$status" in
            preferred)
                preferred_part="$part"
                log_debug "Found preferred data partition: $part (label: $label)"
                ;;
            usable)
                [[ -z "$usable_part" ]] && usable_part="$part"
                log_debug "Found usable partition: $part"
                ;;
            unformatted)
                [[ -z "$unformatted_part" ]] && unformatted_part="$part"
                log_debug "Found unformatted partition: $part"
                ;;
        esac
    done < <(get_partition_info "$root_disk")

    # Return best option
    if [[ -n "$preferred_part" ]]; then
        echo "$preferred_part"
    elif [[ -n "$usable_part" ]]; then
        echo "$usable_part"
    elif [[ -n "$unformatted_part" ]]; then
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
    if [[ -z "$OVERLAY_DEVICE" ]]; then
        overlay_device=$(auto_detect_overlay_device)
        if [[ -n "$overlay_device" ]]; then
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

    # Safety check
    local disk_size
    disk_size=$(get_disk_size_mb "$disk")
    if ((disk_size < MIN_DISK_SIZE_MB)); then
        die "Disk too small: ${disk_size}MB (minimum: ${MIN_DISK_SIZE_MB}MB)"
    fi

    log_info "Disk size: ${disk_size}MB"

    # Create GPT partition table
    log_info "Creating GPT partition table..."
    parted -s "$disk" mklabel gpt

    # Create partitions
    log_info "Creating ESP partition (${PART_ESP_SIZE})..."
    parted -s "$disk" mkpart ESP fat32 1MiB "${PART_ESP_SIZE}"
    parted -s "$disk" set 1 esp on

    log_info "Creating boot partition (${PART_BOOT_SIZE})..."
    parted -s "$disk" mkpart boot ext4 "${PART_ESP_SIZE}" "$((256 + 512))MiB"

    if [[ "$with_data" == "true" ]]; then
        log_info "Creating data partition (remaining space)..."
        parted -s "$disk" mkpart data ext4 "$((256 + 512))MiB" 100%
    fi

    # Wait for partitions to appear
    sleep 2
    partprobe "$disk" 2>/dev/null || true
    sleep 1

    log_info "Partition layout created"
}

# Get partition device name
get_partition_device() {
    local disk="$1"
    local part_num="$2"

    if [[ "$disk" =~ mmcblk|nvme|loop ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

# Format partitions
format_partitions() {
    local disk="$1"
    local with_data="${2:-true}"

    log_step "Formatting partitions..."

    local esp_dev boot_dev data_dev
    esp_dev=$(get_partition_device "$disk" 1)
    boot_dev=$(get_partition_device "$disk" 2)

    log_info "Formatting ESP ($esp_dev)..."
    mkfs.vfat -F 32 -n ESP "$esp_dev"

    log_info "Formatting boot partition ($boot_dev)..."
    mkfs.ext4 -L ALPINE_BOOT -F "$boot_dev"

    if [[ "$with_data" == "true" ]]; then
        data_dev=$(get_partition_device "$disk" 3)
        log_info "Formatting data partition ($data_dev)..."
        mkfs.ext4 -L ALPINE_DATA -F "$data_dev"
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

# Generate Alpine system squashfs
generate_system_squashfs() {
    local output_dir="$1"
    local slot="$2"

    log_step "Generating system.squashfs for slot $slot..."

    local build_dir
    build_dir=$(mktemp -d)

    # Extract minirootfs as base
    log_info "Extracting base system..."
    tar -xzf "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" -C "$build_dir"

    # Mount for chroot operations
    mount -t proc proc "${build_dir}/proc"
    mount -t sysfs sysfs "${build_dir}/sys"
    mount -t devtmpfs devtmpfs "${build_dir}/dev"

    # Configure APK
    tee "${build_dir}/etc/apk/repositories" > /dev/null << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF

    # Install packages based on mode
    log_info "Installing system packages..."
    chroot "$build_dir" /sbin/apk update

    if [[ "$HARDENED_MODE" == "true" ]]; then
        log_info "Installing hardened packages..."
        chroot "$build_dir" /sbin/apk add --no-cache \
            alpine-base \
            linux-hardened \
            linux-firmware-none \
            openrc \
            busybox-openrc \
            dropbear \
            dropbear-openrc \
            hardened-malloc \
            nftables \
            iptables \
            e2fsprogs \
            dosfstools \
            parted \
            rsync \
            curl \
            ca-certificates \
            chrony

    else
        chroot "$build_dir" /sbin/apk add --no-cache \
            alpine-base \
            linux-lts \
            linux-firmware-none \
            openrc \
            busybox-openrc \
            openssh-server \
            openssh-client \
            e2fsprogs \
            dosfstools \
            parted \
            rsync \
            curl \
            ca-certificates
    fi

    # Add extra packages if specified
    if [[ -n "$EXTRA_PACKAGES" ]]; then
        local pkgs
        pkgs=$(echo "$EXTRA_PACKAGES" | tr ',' ' ')
        chroot "$build_dir" /sbin/apk add --no-cache $pkgs
    fi

    # Configure system
    configure_system_image "$build_dir"

    # Apply hardening if enabled
    if [[ "$HARDENED_MODE" == "true" ]]; then
        apply_hardening_to_image "$build_dir"
    fi

    # Setup SSH (dropbear or openssh)
    setup_system_ssh "$build_dir"

    # Cleanup chroot mounts
    umount "${build_dir}/dev" 2>/dev/null || true
    umount "${build_dir}/sys" 2>/dev/null || true
    umount "${build_dir}/proc" 2>/dev/null || true

    # Create squashfs
    log_info "Creating squashfs image..."
    mksquashfs "$build_dir" "${output_dir}/system.squashfs" \
        -comp zstd \
        -Xcompression-level 19 \
        -noappend \
        -no-progress

    # Cleanup
    rm -rf "$build_dir"

    # Update metadata
    cat > "${output_dir}/meta.conf" << EOF
VERSION=${ALPINE_VERSION}
INSTALLED=$(date -Iseconds)
BOOT_COUNT=0
VERIFIED=false
EOF

    log_info "System image created: $(du -h "${output_dir}/system.squashfs" | cut -f1)"
}

# Configure the system image
configure_system_image() {
    local root="$1"

    log_info "Configuring system..."

    # Hostname
    echo "${DETECTED_HOSTNAME}" > "${root}/etc/hostname"

    # Network
    mkdir -p "${root}/etc/network"
    if [[ "$NETWORK_IS_DHCP" == "true" ]]; then
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
    chroot "$root" /sbin/rc-update add sshd default
    chroot "$root" /sbin/rc-update add local default

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
    if [[ -f "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" ]]; then
        tar -xzf "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" \
            -C "$root" ./root/.ssh/authorized_keys 2>/dev/null || true
    fi

    # Fallback
    if [[ ! -s "${root}/root/.ssh/authorized_keys" ]]; then
        cat ~/.ssh/authorized_keys >> "${root}/root/.ssh/authorized_keys" 2>/dev/null || true
        cat /root/.ssh/authorized_keys >> "${root}/root/.ssh/authorized_keys" 2>/dev/null || true
    fi

    chown -R 0:0 "${root}/root/.ssh"
    chmod 600 "${root}/root/.ssh/authorized_keys" 2>/dev/null || true

    # Configure SSH server
    if [[ "$HARDENED_MODE" == "true" ]]; then
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
    source /current_slot
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
    if [[ "$DETECTED_PLATFORM" == "rpi" ]]; then
        setup_rpi_boot "$boot_mount"
    fi
}

# Setup Raspberry Pi specific boot files
setup_rpi_boot() {
    local boot_mount="$1"

    log_info "Configuring Raspberry Pi boot..."

    # Copy RPi firmware files
    if [[ -f "${INSTALL_CACHE_DIR}/alpine-rpi-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz" ]]; then
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
    if [[ $EUID -ne 0 ]]; then
        die "run_ab_install must be run as root"
    fi

    log_step "Starting A/B installation..."

    local disk
    disk=$(detect_root_disk)
    log_info "Target disk: $disk"

    # Confirm
    if [[ "$DRY_RUN" != "true" ]]; then
        echo ""
        echo "WARNING: This will ERASE ALL DATA on $disk"
        echo ""
        confirm_action "Proceed with installation on $disk?"
    fi

    local with_data=false
    [[ -n "$OVERLAY_DEVICE" ]] && with_data=true

    # Create partitions
    create_partition_layout "$disk" "$with_data"
    format_partitions "$disk" "$with_data"

    # Mount partitions
    local esp_dev boot_dev
    esp_dev=$(get_partition_device "$disk" 1)
    boot_dev=$(get_partition_device "$disk" 2)

    local mnt_base="/mnt/alpine-install"
    mkdir -p "${mnt_base}/esp" "${mnt_base}/boot"

    mount "$boot_dev" "${mnt_base}/boot"
    mount "$esp_dev" "${mnt_base}/esp"

    if [[ "$with_data" == "true" ]]; then
        local data_dev
        data_dev=$(get_partition_device "$disk" 3)
        mkdir -p "${mnt_base}/data"
        mount "$data_dev" "${mnt_base}/data"
        setup_data_partition "${mnt_base}/data"
    fi

    # Setup boot structure
    setup_boot_structure "${mnt_base}/boot"

    # Generate system image for slot A
    generate_system_squashfs "${mnt_base}/boot/slots/A" "A"

    # Copy kernel and initramfs
    copy_kernel_files "${mnt_base}/boot/slots/A"

    # Setup bootloader
    setup_bootloader "${mnt_base}/esp" "${mnt_base}/boot" "$DETECTED_ARCH"

    # Cleanup
    umount "${mnt_base}/esp"
    umount "${mnt_base}/boot"
    [[ "$with_data" == "true" ]] && umount "${mnt_base}/data"

    log_info "A/B installation complete!"
    log_info "Reboot to start Alpine Linux"
}

# Copy kernel files to slot
copy_kernel_files() {
    local slot_dir="$1"

    log_info "Copying kernel files..."

    # Copy from cache (downloaded earlier)
    if [[ -f "${INSTALL_CACHE_DIR}/vmlinuz" ]]; then
        cp "${INSTALL_CACHE_DIR}/vmlinuz" "${slot_dir}/"
        cp "${INSTALL_CACHE_DIR}/initramfs"* "${slot_dir}/initramfs"
    else
        # Extract from installed kernel in squashfs
        local squashfs="${slot_dir}/system.squashfs"
        local mnt=$(mktemp -d)
        mount -o loop,ro "$squashfs" "$mnt"

        cp "$mnt"/boot/vmlinuz* "${slot_dir}/vmlinuz"
        cp "$mnt"/boot/initramfs* "${slot_dir}/initramfs"

        umount "$mnt"
        rmdir "$mnt"
    fi
}
