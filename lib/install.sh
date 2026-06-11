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

    log_info "Creating boot partition (${PART_BOOT_SIZE_MB}MB)..."
    require parted -s "$disk" mkpart boot fat32 1MiB "${PART_BOOT_SIZE_MB}MiB"
    require parted -s "$disk" set 1 boot on
    # x86_64 BIOS: gptmbr.bin chainloads the partition carrying the GPT
    # "legacy BIOS bootable" attribute (bit 2). extlinux's VBR lives there.
    if [ "$DETECTED_PLATFORM" != "rpi" ]; then
        parted -s "$disk" set 1 legacy_boot on 2>/dev/null \
            || log_warn "could not set legacy_boot attribute on ${disk}1"
    fi

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

    # RPi firmware reads the boot files from a FAT partition; x86_64 boots via
    # extlinux, which installs onto an ext filesystem (not FAT), so use ext4
    # there. install_boot_config + init.aa + upgrade.sh all key off extlinux.conf.
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        log_info "Formatting boot partition ($boot_dev, FAT32)..."
        require mkfs.vfat -F 32 -n ALPINE_BOOT "$boot_dev"
    else
        log_info "Formatting boot partition ($boot_dev, ext4)..."
        require mkfs.ext4 -q -L ALPINE_BOOT -F "$boot_dev"
    fi

    # Slot A and B are raw (squashfs written directly), no formatting needed
    log_info "Slot A and B: raw partitions (squashfs will be written directly)"

    if [ "$with_data" = "true" ]; then
        data_dev=$(get_part_dev "$disk" 4)
        if persist_enabled; then
            format_data_partition "$disk" "$data_dev"
        else
            log_info "Formatting data partition ($data_dev, ext4)..."
            require mkfs.ext4 -L ALPINE_DATA -q -F "$data_dev"
        fi
    fi

    log_info "Partitions formatted"
}

# Path to the LUKS key material (the passphrase bytes) staged by the control
# host; used at format time and never left on the installed system.
DATA_KEYFILE="${DATA_KEYFILE:-/tmp/aa-data.key}"
# Mapper name for the unlocked data device.
DATA_MAPPER="${DATA_MAPPER:-aa-data}"

# True if the kernel supports the chosen data filesystem (btrfs/ext4) and, when
# encrypting, dm-crypt. Guards against building an unmountable data partition.
data_stack_supported() {
    _dss_root="$1"
    if encrypt_enabled && ! grep -hqs '^CONFIG_DM_CRYPT=[ym]' "${_dss_root}"/boot/config-* 2>/dev/null \
        && ! ls "${_dss_root}"/lib/modules/*/kernel/drivers/md/dm-crypt.ko* >/dev/null 2>&1; then
        return 1
    fi
    if [ "$DATA_FS" = "btrfs" ] && ! grep -hqs '^CONFIG_BTRFS_FS=[ym]' "${_dss_root}"/boot/config-* 2>/dev/null \
        && ! ls "${_dss_root}"/lib/modules/*/kernel/fs/btrfs/btrfs.ko* >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Format the data partition for persistence: optional LUKS2, then the chosen FS
# (btrfs with subvolumes, or ext4), and write data.meta onto the boot FAT so the
# boot-time mount service knows the layout deterministically.
# Subvolumes: @var @srv @home @containers @snapshots (btrfs only).
format_data_partition() {
    _fdp_disk="$1"; _fdp_dev="$2"
    is_block_device "$_fdp_dev" || die "format_data_partition: $_fdp_dev is not a block device"

    # These tools run on the BUILDER (the running system doing the install),
    # which may not have them yet - install on demand.
    if encrypt_enabled && ! command_exists cryptsetup; then
        log_info "Installing cryptsetup on the builder..."; apk add --no-cache cryptsetup >/dev/null 2>&1 || true
    fi
    if [ "$DATA_FS" = "btrfs" ] && ! command_exists mkfs.btrfs; then
        log_info "Installing btrfs-progs on the builder..."; apk add --no-cache btrfs-progs >/dev/null 2>&1 || true
    fi
    # The filesystem/crypto kernel modules may be modules not yet loaded on the
    # builder (e.g. linux-rpi BTRFS_FS=m) - mount -t btrfs would fail with EINVAL.
    encrypt_enabled && modprobe dm-crypt 2>/dev/null || true
    [ "$DATA_FS" = "btrfs" ] && modprobe btrfs 2>/dev/null || true

    local fs_dev="$_fdp_dev" luks_uuid=""
    if encrypt_enabled; then
        command_exists cryptsetup || die "cryptsetup not found (needed for --encrypt-data)"
        # Resolve key material. For ssh/passphrase methods the control host staged
        # the passphrase bytes at DATA_KEYFILE; for keyfile+URL we fetch it now.
        if [ "$UNLOCK_METHOD" = "keyfile" ] && [ -n "$KEY_URL" ] && [ ! -f "$DATA_KEYFILE" ]; then
            log_info "Fetching LUKS key from $KEY_URL..."
            http_fetch_file "$KEY_URL" "$DATA_KEYFILE" || die "could not fetch LUKS key from $KEY_URL"
        fi
        [ -f "$DATA_KEYFILE" ] || die "LUKS key material not found at $DATA_KEYFILE (control host must stage it)"
        log_info "Creating LUKS2 container on $_fdp_dev..."
        require cryptsetup luksFormat --type luks2 --batch-mode --key-file "$DATA_KEYFILE" "$_fdp_dev"
        require cryptsetup open --key-file "$DATA_KEYFILE" "$_fdp_dev" "$DATA_MAPPER"
        fs_dev="/dev/mapper/${DATA_MAPPER}"
        luks_uuid=$(cryptsetup luksUUID "$_fdp_dev" 2>/dev/null)
    fi

    if [ "$DATA_FS" = "btrfs" ]; then
        command_exists mkfs.btrfs || die "mkfs.btrfs not found (install btrfs-progs)"
        log_info "Creating BTRFS on $fs_dev with subvolumes..."
        require mkfs.btrfs -q -L ALPINE_DATA -f "$fs_dev"
        local m="/mnt/aa-data-fmt"; mkdir -p "$m"
        require mount "$fs_dev" "$m"
        assert_mounted "$m"
        local sv
        for sv in @var @srv @home @containers @snapshots; do
            require btrfs subvolume create "${m}/${sv}"
        done
        # nodatacow on container storage to avoid CoW fragmentation
        chattr +C "${m}/@containers" 2>/dev/null || true
        require umount "$m"
    else
        log_info "Creating ext4 on $fs_dev..."
        require mkfs.ext4 -L ALPINE_DATA -q -F "$fs_dev"
    fi

    # Close LUKS; the boot service / aa-unlock will reopen it.
    if encrypt_enabled; then
        require cryptsetup close "$DATA_MAPPER"
        # Securely remove the staged key material from the builder.
        if command_exists shred; then shred -u "$DATA_KEYFILE" 2>/dev/null || true; else rm -f "$DATA_KEYFILE"; fi
    fi

    write_data_meta "$_fdp_disk" "$_fdp_dev" "$luks_uuid"
    log_info "Data partition ready (fs=${DATA_FS}, encrypted=$(encrypt_enabled && echo yes || echo no))"
}

# Write data.meta onto the FAT boot partition (partition 1), alongside slots.meta.
# Read by aa-mount-data / aa-unlock at boot.
write_data_meta() {
    _wdm_disk="$1"; _wdm_dev="$2"; _wdm_uuid="$3"
    # Mount point overridable for tests (AA_BOOTMETA_MNT).
    local boot_dev boot_mnt="${AA_BOOTMETA_MNT:-/mnt/aa-bootmeta}"
    boot_dev=$(get_part_dev "$_wdm_disk" 1)
    mkdir -p "$boot_mnt"
    require mount "$boot_dev" "$boot_mnt"
    assert_mounted "$boot_mnt"
    cat <<EOF | atomic_write "${boot_mnt}/data.meta"
DATA_DEV=${_wdm_dev}
DATA_FS=${DATA_FS}
DATA_ENCRYPTED=$(encrypt_enabled && echo true || echo false)
DATA_LUKS_UUID=${_wdm_uuid}
DATA_UNLOCK=${UNLOCK_METHOD}
DATA_MAPPER=${DATA_MAPPER}
KEY_URL=${KEY_URL}
CONTAINERS=${CONTAINERS}
EOF
    require umount "$boot_mnt"
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

    # Ensure chroot'd build steps resolve Alpine binaries regardless of the build
    # HOST's PATH. A host that symlinks /sbin and /bin into /usr/bin (Arch /
    # SystemRescue rescue env) has a PATH without /sbin or /bin, which `chroot`
    # passes through - then bare commands in the Alpine chroot (apk in /sbin,
    # s6-rc-compile / s6-linux-init-maker in /bin) are "not found". Prepend the
    # standard set; nonexistent dirs in PATH are harmless on any host.
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

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

    # Data persistence: cryptsetup (LUKS unlock) + btrfs-progs (subvolumes,
    # snapshots) must be on the INSTALLED system for the boot-mount service and
    # aa-snapshot. cryptsetup dedups with verity_pkg via apk.
    local persist_pkg=""
    if persist_enabled; then
        persist_pkg="cryptsetup"
        [ "$DATA_FS" = "btrfs" ] && persist_pkg="$persist_pkg btrfs-progs"
    fi

    # Container runtime baked onto the image (data-root on the persistent volume).
    local container_pkg=""
    container_is podman && container_pkg="podman crun fuse-overlayfs"
    container_is docker && container_pkg="$container_pkg docker docker-cli"

    # squashfs-tools is needed on the installed system so `alpine-anywhere
    # upgrade` can build the next slot's image in place.
    chroot "$build_dir" /sbin/apk add --no-cache \
        alpine-base $init_pkg \
        "$kernel_pkg" linux-firmware-none \
        mkinitfs \
        $ssh_pkg \
        e2fsprogs dosfstools squashfs-tools $verity_pkg \
        $persist_pkg $container_pkg \
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

    # Data-persistence feasibility: the kernel must support the chosen data FS
    # (and dm-crypt when encrypting), or the data partition would be unmountable.
    if persist_enabled && ! data_stack_supported "$build_dir"; then
        die "data persistence requested but the kernel ($kernel_pkg) lacks support for ${DATA_FS}$(encrypt_enabled && echo ' / dm-crypt'). Use --data-fs ext4 / drop --encrypt-data, or a kernel with that support."
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

    # Data persistence: bake the persistence services + a factory copy of /var so
    # the boot-time mount can seed an empty @var (first boot) and `cp -n` missing
    # skeleton dirs after an OS upgrade, without clobbering existing data.
    if persist_enabled; then
        setup_persistence_image "$build_dir"
    fi

    # s6 init: build s6-rc db + s6-linux-init basedir, make s6 PID 1
    if [ "$INIT_SYSTEM" = "s6" ]; then
        setup_s6_init "$build_dir"
    else
        # OpenRC: wire any custom services declared by --custom-script (the s6
        # path does the equivalent slurp inside setup_s6_init).
        wire_custom_openrc_services "$build_dir"
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

    # Stage --custom-files (file or dir) into the chroot and expose its location
    # to the hook via $AA_CUSTOM_FILES_DIR. Lets a build hook install a pre-built
    # artifact (e.g. a binary) without needing network access at build time.
    local files_env=""
    if [ -n "$CUSTOM_FILES" ]; then
        [ -e "$CUSTOM_FILES" ] || die "Custom files path not found: $CUSTOM_FILES"
        rm -rf "${root}/tmp/aa-custom-files"
        mkdir -p "${root}/tmp/aa-custom-files"
        if [ -d "$CUSTOM_FILES" ]; then
            cp -R "$CUSTOM_FILES"/. "${root}/tmp/aa-custom-files/"
        else
            cp "$CUSTOM_FILES" "${root}/tmp/aa-custom-files/"
        fi
        files_env="AA_CUSTOM_FILES_DIR=/tmp/aa-custom-files"
        log_info "Staged custom files into chroot: $CUSTOM_FILES"
    fi

    log_info "Running custom build hook: $CUSTOM_SCRIPT"
    cp "$CUSTOM_SCRIPT" "${root}/tmp/aa-custom.sh"
    chmod +x "${root}/tmp/aa-custom.sh"
    # Set an explicit PATH for the hook: chroot otherwise inherits the host's
    # PATH, and a host that merges /sbin into /usr/bin (e.g. Arch/SystemRescue)
    # leaves the Alpine chroot's /sbin off PATH, so bare `apk` (in /sbin) is not
    # found. Absolute-path apk calls elsewhere are unaffected; this fixes hooks
    # that call apk/rc-update/etc. by name.
    local hook_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if ! chroot "$root" /usr/bin/env $hook_path $files_env /bin/sh /tmp/aa-custom.sh; then
        rm -f "${root}/tmp/aa-custom.sh"
        rm -rf "${root}/tmp/aa-custom-files"
        die "Custom script failed: $CUSTOM_SCRIPT"
    fi
    rm -f "${root}/tmp/aa-custom.sh"
    rm -rf "${root}/tmp/aa-custom-files"
    log_info "Custom build hook completed"
}

# Wire custom OpenRC services declared by --custom-script. Each file
# /etc/aa/custom-services.d/<name>.openrc is installed as /etc/init.d/<name>
# (executable) and added to the default runlevel. The s6 equivalent lives in
# setup_s6_init (which slurps /etc/aa/custom-services.d/<name>/ directories).
wire_custom_openrc_services() {
    local root="$1"
    local dir="${root}/etc/aa/custom-services.d"
    [ -d "$dir" ] || return 0
    local f name
    for f in "$dir"/*.openrc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .openrc)
        cp "$f" "${root}/etc/init.d/${name}"
        chmod +x "${root}/etc/init.d/${name}"
        chroot "$root" /sbin/rc-update add "$name" default 2>/dev/null \
            || log_warn "could not enable custom OpenRC service: $name"
        log_info "Wired custom OpenRC service: ${name}"
    done
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

# Bake the data-persistence machinery into the image: a factory copy of /var
# (to seed an empty @var / fill in new skeleton dirs after an OS upgrade), the
# /etc/fstab entries (noauto: mounted explicitly by our service/command, never
# by localmount - sidesteps the /var ordering problem), the workhorse
# /usr/local/sbin/aa-data (read data.meta, unlock, mount subvols, seed), the
# operator commands aa-unlock / aa-snapshot, and the OpenRC boot service. The s6
# oneshot is added by setup_s6_init. Hardened mount opts: nodev,nosuid
# everywhere; noexec only where safe (/srv, /var/log).
setup_persistence_image() {
    local root="$1"
    log_info "Baking data-persistence (/var on ${DATA_FS}$(encrypt_enabled && echo '+LUKS'))..."

    # 1. Factory copy of the pristine /var so the runtime can seed @var.
    mkdir -p "${root}/usr/share/factory"
    cp -a "${root}/var" "${root}/usr/share/factory/var" 2>/dev/null || true

    # 2. fstab (noauto - mounted by aa-data, not localmount). Container storage
    #    only when containers are baked in.
    {
        echo "# Alpine Anywhere - persistent data (mounted by aa-data / aa-unlock)"
        echo "/dev/mapper/${DATA_MAPPER} /var   ${DATA_FS} subvol=@var,noatime,nodev,nosuid,noauto 0 0"
        echo "/dev/mapper/${DATA_MAPPER} /srv   ${DATA_FS} subvol=@srv,noatime,nodev,nosuid,noexec,noauto 0 0"
        echo "/dev/mapper/${DATA_MAPPER} /home  ${DATA_FS} subvol=@home,noatime,nodev,nosuid,noauto 0 0"
        if containers_enabled; then
            echo "/dev/mapper/${DATA_MAPPER} /var/lib/containers ${DATA_FS} subvol=@containers,noatime,nodev,nosuid,noauto 0 0"
        fi
    } >> "${root}/etc/fstab"
    # When NOT encrypted the data device is the raw partition, not a mapper.
    if ! encrypt_enabled; then
        sed -i "s#/dev/mapper/${DATA_MAPPER}#LABEL=ALPINE_DATA#g" "${root}/etc/fstab"
    fi

    # 3. Workhorse + operator commands. Ensure /usr/local/{sbin,bin} are on PATH
    #    for interactive logins (minimal s6 images don't include them), so the
    #    operator can just type `aa-unlock` / `aa-snapshot`.
    mkdir -p "${root}/usr/local/sbin" "${root}/usr/local/bin" "${root}/etc/profile.d"
    cat > "${root}/etc/profile.d/aa-path.sh" << 'EOF'
case ":$PATH:" in *:/usr/local/sbin:*) ;; *) PATH="/usr/local/sbin:/usr/local/bin:$PATH"; export PATH ;; esac
EOF
    install_aa_data_helper "$root"
    install_aa_unlock "$root"
    install_aa_snapshot "$root"

    # 4. OpenRC boot service for AUTOMATIC unlock methods (keyfile/passphrase).
    #    With the default ssh method it is a no-op at boot (aa-unlock does it).
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        cat > "${root}/etc/init.d/aa-mount-data" << 'EOF'
#!/sbin/openrc-run
description="Alpine Anywhere: unlock + mount persistent data (auto methods)"
depend() {
    before bootmisc localmount sshd dropbear nftables net
    keyword -timeout
}
start() {
    ebegin "Mounting persistent data"
    /usr/local/sbin/aa-data autoboot || true
    eend 0
}
EOF
        chmod +x "${root}/etc/init.d/aa-mount-data"
        chroot "$root" /sbin/rc-update add aa-mount-data boot 2>/dev/null || true
    fi

    # 5. Container setup (graphroot/data-root on the persistent subvol).
    containers_enabled && setup_container_image "$root"
}

# /usr/local/sbin/aa-data — the workhorse. Standalone POSIX (no lib deps): it
# re-derives the boot disk from /proc/cmdline, reads data.meta from the FAT boot
# partition, and unlocks/mounts/seeds. Subcommands:
#   autoboot   - boot service: only acts for non-ssh unlock methods
#   open KEY?  - open LUKS (KEY from stdin/file) and mount everything
#   mount      - mount subvolumes (assumes already unlocked / unencrypted)
#   status     - print state
install_aa_data_helper() {
    local root="$1"
    cat > "${root}/usr/local/sbin/aa-data" << 'AADATA'
#!/bin/sh
# Persistent-data workhorse (reads data.meta from the FAT boot partition).
set -u
BOOT_MNT=/run/aa-boot
READY=/run/aa-data-ready

_boot_disk() {
    r=$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -n1)
    case "$r" in
        *mmcblk*|*nvme*) echo "${r%p[0-9]}" ;;
        *) echo "$r" | sed 's/[0-9]*$//' ;;
    esac
}
_part() {
    d=$(_boot_disk)
    case "$d" in *mmcblk*|*nvme*) echo "${d}p$1" ;; *) echo "${d}$1" ;; esac
}
_read_meta() {
    DATA_ENCRYPTED=false; DATA_UNLOCK=ssh; DATA_MAPPER=aa-data; DATA_DEV=""; DATA_FS=btrfs; KEY_URL=""; CONTAINERS=none
    mkdir -p "$BOOT_MNT"
    mount -o ro "$(_part 1)" "$BOOT_MNT" 2>/dev/null || mount "$(_part 1)" "$BOOT_MNT" 2>/dev/null || return 1
    [ -f "$BOOT_MNT/data.meta" ] && . "$BOOT_MNT/data.meta"
    umount "$BOOT_MNT" 2>/dev/null || true
    [ -n "$DATA_DEV" ] || DATA_DEV=$(_part 4)
}
_unlock() {
    # $1 = path to key material (file) or "-" for stdin; only for encrypted data.
    [ "$DATA_ENCRYPTED" = "true" ] || return 0
    [ -b "/dev/mapper/${DATA_MAPPER}" ] && return 0
    if [ "${1:-}" = "-" ]; then
        cryptsetup open "$DATA_DEV" "$DATA_MAPPER"            # prompt / stdin passphrase
    else
        cryptsetup open --key-file "$1" "$DATA_DEV" "$DATA_MAPPER"
    fi
}
_seed_var() {
    [ -d /usr/share/factory/var ] || return 0
    cp -an /usr/share/factory/var/. /var/ 2>/dev/null || true
}
_mount_all() {
    # /etc/fstab has the persist mounts as noauto; mount them explicitly.
    for m in /var /srv /home /var/lib/containers; do
        grep -q " $m " /etc/fstab 2>/dev/null || continue
        mkdir -p "$m" 2>/dev/null || true
        mountpoint -q "$m" 2>/dev/null || mount "$m" 2>/dev/null || \
            echo "aa-data: WARN could not mount $m" >&2
    done
    _seed_var
    touch "$READY"
}
_start_data_services() {
    # Bring up services that need /var (containers, app services) post-unlock.
    if command -v rc-service >/dev/null 2>&1; then
        for s in aa-container-setup docker; do
            [ -f "/etc/init.d/$s" ] && rc-service "$s" start 2>/dev/null || true
        done
    fi
    [ -x /usr/local/sbin/aa-data-deps ] && /usr/local/sbin/aa-data-deps 2>/dev/null || true
}

cmd="${1:-status}"
_read_meta || { echo "aa-data: no data.meta; persistence not configured" >&2; exit 0; }

case "$cmd" in
    autoboot)
        # Boot service: only auto methods act here. ssh stays locked until aa-unlock.
        case "$DATA_UNLOCK" in
            ssh) echo "aa-data: data is encrypted; run 'aa-unlock' to mount /var" >&2; exit 0 ;;
            keyfile)
                kf=/run/aa.key
                if [ -n "$KEY_URL" ]; then curl -fsS "$KEY_URL" -o "$kf" 2>/dev/null || true; fi
                [ -f "$BOOT_MNT.key" ] && kf="$BOOT_MNT.key"
                _unlock "$kf" && _mount_all || echo "aa-data: auto unlock failed (system stays up)" >&2
                rm -f "$kf" 2>/dev/null || true
                ;;
            passphrase) _unlock - && _mount_all || true ;;
        esac
        ;;
    open)  _unlock "${2:--}" && _mount_all && _start_data_services ;;
    mount) _mount_all && _start_data_services ;;
    status)
        echo "encrypted=$DATA_ENCRYPTED unlock=$DATA_UNLOCK fs=$DATA_FS dev=$DATA_DEV"
        [ -e "$READY" ] && echo "data: MOUNTED" || echo "data: not mounted"
        ;;
    *) echo "usage: aa-data {autoboot|open [keyfile|-]|mount|status}" >&2; exit 1 ;;
esac
AADATA
    chmod +x "${root}/usr/local/sbin/aa-data"
}

# /usr/local/bin/aa-unlock — operator command (ssh method). Prompts for the
# passphrase (or reads --key-file), opens LUKS, mounts /var, starts data services.
install_aa_unlock() {
    local root="$1"
    cat > "${root}/usr/local/bin/aa-unlock" << 'AAUNLOCK'
#!/bin/sh
# Unlock + mount the persistent data partition (run after SSHing in).
# Calls aa-data by ABSOLUTE path (/usr/local/sbin may not be in PATH).
set -u
if [ "${1:-}" = "--key-file" ] && [ -n "${2:-}" ]; then
    /usr/local/sbin/aa-data open "$2"
else
    echo "Enter data passphrase to unlock /var:" >&2
    /usr/local/sbin/aa-data open -   # cryptsetup reads the passphrase from the tty/stdin
fi
AAUNLOCK
    chmod +x "${root}/usr/local/bin/aa-unlock"
}

# Container runtime config: storage on the persistent volume, rootless-friendly.
setup_container_image() {
    local root="$1"
    log_info "Configuring containers (${CONTAINERS}, runtime ${CONTAINER_RUNTIME})..."

    if container_is podman; then
        mkdir -p "${root}/etc/containers"
        # graphroot on the persistent @containers subvol; fuse-overlayfs for rootless.
        cat > "${root}/etc/containers/storage.conf" << 'EOF'
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
        # subuid/subgid for rootless podman (a dedicated user is the operator's job;
        # seed root's range so `podman` works out of the box).
        echo "root:100000:65536" > "${root}/etc/subuid"
        echo "root:100000:65536" > "${root}/etc/subgid"
        if [ "$CONTAINER_RUNTIME" = "runsc" ]; then
            mkdir -p "${root}/etc/containers"
            cat > "${root}/etc/containers/containers.conf" << 'EOF'
[engine]
runtime = "runsc"
[engine.runtimes]
runsc = ["/usr/local/bin/runsc"]
EOF
        fi
    fi

    # aa-container-setup: prepare the data-root on the persistent volume (run by
    # aa-data after /var is mounted).
    cat > "${root}/etc/init.d/aa-container-setup" << 'EOF'
#!/sbin/openrc-run
description="Alpine Anywhere: prepare container storage on persistent data"
depend() { after net; }
start() {
    ebegin "Preparing container storage"
    mkdir -p /var/lib/containers/storage /var/lib/docker 2>/dev/null
    eend 0
}
EOF
    chmod +x "${root}/etc/init.d/aa-container-setup"
    if container_is docker && [ "$INIT_SYSTEM" = "openrc" ]; then
        # docker daemon: data-root on the persistent subvol (set via conf.d).
        mkdir -p "${root}/etc/conf.d"
        echo 'DOCKER_OPTS="--data-root=/var/lib/docker"' > "${root}/etc/conf.d/docker"
        chroot "$root" /sbin/rc-update add docker default 2>/dev/null || true
    fi
}

# /usr/local/bin/aa-snapshot — BTRFS snapshot + optional incremental send.
install_aa_snapshot() {
    local root="$1"
    cat > "${root}/usr/local/bin/aa-snapshot" << 'AASNAP'
#!/bin/sh
# Read-only BTRFS snapshots of the persistent subvolumes (+ optional send).
# Usage: aa-snapshot [create|list|send <ssh-dest>]
set -u
SNAPROOT=/var/.snapshots   # @snapshots is mounted here if you add it to fstab
[ -d "$SNAPROOT" ] || SNAPROOT=/.snapshots
ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || cat /proc/uptime | cut -d. -f1)
case "${1:-create}" in
    create)
        mkdir -p "$SNAPROOT"
        for sv in /var /srv /home; do
            mountpoint -q "$sv" || continue
            btrfs subvolume snapshot -r "$sv" "$SNAPROOT/$(basename "$sv")-$ts" 2>/dev/null \
                && echo "snapshot: $SNAPROOT/$(basename "$sv")-$ts" || true
        done
        ;;
    list) ls -1 "$SNAPROOT" 2>/dev/null ;;
    send)
        dest="${2:?usage: aa-snapshot send user@host:/path}"
        for s in "$SNAPROOT"/*; do
            [ -d "$s" ] || continue
            btrfs send "$s" 2>/dev/null | ssh "${dest%%:*}" "btrfs receive ${dest#*:}" 2>/dev/null || true
        done
        ;;
    *) echo "usage: aa-snapshot {create|list|send <ssh-dest>}" >&2; exit 1 ;;
esac
AASNAP
    chmod +x "${root}/usr/local/bin/aa-snapshot"
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

    # PARTUUID resolver: copy aa-resolve-root and insert a call BEFORE the root
    # mount so a tag-style root=PARTUUID=... is turned into a concrete /dev node.
    # The busybox-only initramfs cannot resolve PARTUUID= (no util-linux blkid;
    # busybox mount/findfs only grok filesystem UUID=/LABEL=), so without this the
    # init mounts the literal "PARTUUID=..." string and dies with
    #   mount: ... on /media/root-ro failed: No such file or directory
    # Must run AFTER nlplug-findfs has plugged the disk nodes and BEFORE both the
    # verity-open and the root mount, so anchor on the same root-mount line and
    # inject this pass FIRST (verity's pass below then lands between us and the
    # mount, using the node we resolved). On resolution failure aa-resolve-root
    # prints nothing and KOPT_root is left as-is (boot behaviour unchanged).
    # Locate a root-mount anchor (the real mkinitfs overlay path mounts $KOPT_root
    # at /media/root-ro; the plain path mounts onto $sysroot). Best-effort: a fake
    # or future init without a recognizable root mount just skips the resolver
    # injection (boot behaviour unchanged) rather than failing the wrap.
    local rmount_anchor=""
    if grep -qE '^[[:space:]]*mkdir -p /media/root-ro' "$tmp/init"; then
        rmount_anchor='^[[:space:]]*mkdir -p /media/root-ro'
    elif grep -qE 'mount .*\$sysroot' "$tmp/init"; then
        rmount_anchor='mount .*\$sysroot'
    fi
    if [ -n "$rmount_anchor" ]; then
        local rr_src=""
        for cand in \
            "${SCRIPT_DIR}/lib/initramfs/aa-resolve-root" \
            "${INSTALL_LIB_DIR}/initramfs/aa-resolve-root" \
            "${INSTALL_BASE_DIR}/lib/initramfs/aa-resolve-root" \
            "/boot/alpine-anywhere/lib/initramfs/aa-resolve-root"; do
            [ -f "$cand" ] && { rr_src="$cand"; break; }
        done
        if [ -n "$rr_src" ]; then
            require cp "$rr_src" "$tmp/sbin/aa-resolve-root"
            chmod +x "$tmp/sbin/aa-resolve-root"
            if ! grep -q '/sbin/aa-resolve-root' "$tmp/init"; then
                awk -v anchor="$rmount_anchor" '
                    $0 ~ anchor && !done {
                        match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
                        print ind "if [ -n \"$KOPT_root\" ]; then _aart=$(/sbin/aa-resolve-root \"$KOPT_root\" 2>/dev/null); [ -n \"$_aart\" ] && KOPT_root=\"$_aart\" && root=\"$_aart\"; fi"
                        done=1
                    }
                    { print }
                ' "$tmp/init" > "$tmp/init.rr.new" && mv "$tmp/init.rr.new" "$tmp/init"
                chmod +x "$tmp/init"
            fi
        else
            log_warn "aa-resolve-root source not found; root=PARTUUID may be unresolvable in the initramfs"
        fi
    else
        log_warn "no root-mount anchor in init; skipping PARTUUID resolver injection"
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

# Verify the network-dependent image build's prerequisites (required tools +
# Alpine mirror reachable) BEFORE the first destructive disk operation. This is
# what lets the in-RAM pivot install fail safe: if networking did not return
# after the takeover, abort here with the disk untouched.
assert_build_prerequisites() {
    log_step "Verifying prerequisites before any destructive disk change..."
    local c missing=""
    for c in parted mksquashfs tar mkfs.ext4; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] || die "missing required tools before install:$missing"
    # The image build runs apk against the Alpine mirror - require it reachable.
    local root="${ALPINE_MIRROR:-http://dl-cdn.alpinelinux.org/alpine}"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O /dev/null "${root%/}/" 2>/dev/null \
            || die "network check failed: cannot reach ${root%/}/ (aborting BEFORE any disk change)"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsS -m 15 -o /dev/null "${root%/}/" 2>/dev/null \
            || die "network check failed: mirror unreachable (aborting BEFORE any disk change)"
    fi
    log_info "Prerequisites OK (tools present, mirror reachable)"
}

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

    # Step 1: Build the system image FIRST (network-dependent: apk downloads).
    # Doing this before ANY destructive disk operation means a build/network
    # failure leaves the existing system bootable - essential for the in-RAM
    # pivot install, where a post-pivot network loss must not brick the box (a
    # reboot then returns to the untouched prior OS).
    assert_build_prerequisites
    local squashfs="/tmp/system.squashfs"
    generate_system_squashfs "$squashfs"

    # Step 2: Partition disk (DESTRUCTIVE - reached only once the image built ok).
    # First release anything still holding the target disk. After a pivot the old
    # root's filesystems are unmounted, but SWAP is not a mount and is missed - an
    # active swap partition keeps parted from informing the kernel of the new
    # table ("Partition(s) ... in use ... reboot now"). Turn swap off and lazily
    # unmount any lingering mounts on the target before partitioning.
    swapoff -a 2>/dev/null || true
    # busybox `swapoff -a` can miss /proc/swaps entries whose path is
    # non-canonical (e.g. "/sdb5" rather than "/dev/sdb5"), so swap off each
    # active device explicitly too - an active swap on the target keeps parted
    # from re-reading the table.
    local _s
    for _s in $(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null); do
        swapoff "$_s" 2>/dev/null || swapoff "/dev${_s}" 2>/dev/null || true
    done
    local _p
    for _p in $(awk -v d="$disk" '$1 ~ ("^" d) {print $2}' /proc/mounts 2>/dev/null | sort -r); do
        umount -l "$_p" 2>/dev/null || true
    done
    create_partition_layout "$disk" "$with_data"
    format_partitions "$disk" "$with_data"

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
    # x86_64 BIOS: write the actual boot code (extlinux + gptmbr). No-op on RPi.
    install_bios_bootloader "$disk" "$boot_mnt"

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

    # Step 6: Setup data partition. With --persist, format_partitions already
    # built the LUKS/BTRFS persistence stack (+ data.meta), so skip the legacy
    # ext4 overlay-dir prep here.
    if [ "$with_data" = "true" ] && ! persist_enabled; then
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

# Ensure the data partition (sda4) is set up for persistence on an EXISTING
# layout. If data.meta already exists on the boot FAT, assume it's configured
# and do nothing. Otherwise format sda4 as the persistence stack - this WIPES
# sda4, so confirm unless --force.
ensure_persist_data_partition() {
    local disk="$1" data_dev boot_dev boot_mnt="/mnt/aa-datachk" has_meta=""
    boot_dev=$(get_part_dev "$disk" 1)
    mkdir -p "$boot_mnt"
    if mount -o ro "$boot_dev" "$boot_mnt" 2>/dev/null; then
        [ -f "$boot_mnt/data.meta" ] && has_meta=1
        umount "$boot_mnt" 2>/dev/null || true
    fi
    if [ -n "$has_meta" ]; then
        log_info "Data partition already configured for persistence (data.meta present)"
        return 0
    fi
    data_dev=$(get_part_dev "$disk" 4)
    [ -b "$data_dev" ] || die "no data partition ($data_dev) to set up for persistence"
    confirm_action "Persistence requested: this will FORMAT $data_dev (sda4) as ${DATA_FS}$(encrypt_enabled && echo '+LUKS') and ERASE its current contents."
    format_data_partition "$disk" "$data_dev"
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

    # Persistence on an existing layout: the data partition (sda4) was formatted
    # by the ORIGINAL install (likely plain ext4). If persistence is requested
    # and not already set up, format it now (DESTROYS sda4 - confirm first).
    if persist_enabled; then
        ensure_persist_data_partition "$disk"
    fi

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
    else
        # Non-verity image: clear any stale verity metadata from a prior verity
        # install of this slot, so `switch` won't spuriously add aaverity=1.
        clear_slot_verity_meta "$slot"
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

# Print a partition's GPT PARTUUID. Robust to busybox blkid, which ignores
# -s/-o and never prints PARTUUID (it would emit the whole "/dev/x: TYPE=..."
# line, producing a malformed root=PARTUUID=...). Returns empty if it cannot be
# determined (caller then falls back to the /dev path). The in-RAM pivot install
# carries util-linux so a real PARTUUID is available there.
_partuuid() {
    local dev="$1" pu=""
    command -v blkid >/dev/null 2>&1 || { printf ''; return 0; }
    pu=$(blkid -s PARTUUID -o value "$dev" 2>/dev/null)
    case "$pu" in
        ''|*[!0-9a-fA-F-]*) pu="" ;;   # reject busybox's full-line output
    esac
    [ -n "$pu" ] || pu=$(blkid "$dev" 2>/dev/null | sed -n 's/.*PARTUUID="\([^"]*\)".*/\1/p')
    printf '%s' "$pu"
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
        # x86_64 / generic: extlinux with per-slot kernels. Use root=PARTUUID
        # rather than /dev/sdaX: kernel device naming (sda/sdb) is assigned by
        # probe order and can swap between boots on multi-disk machines, which
        # would point root= at the wrong disk. PARTUUID is the GPT partition's
        # stable id; the kernel resolves it without udev. init.aa resolves it
        # back to a device via findfs for its A/B logic.
        local slota_dev slotb_dev slota_root slotb_root pu
        slota_dev=$(get_part_dev "$disk" 2)
        slotb_dev=$(get_part_dev "$disk" 3)
        pu=$(_partuuid "$slota_dev")
        slota_root="${pu:+PARTUUID=$pu}"; slota_root="${slota_root:-$slota_dev}"
        pu=$(_partuuid "$slotb_dev")
        slotb_root="${pu:+PARTUUID=$pu}"; slotb_root="${slotb_root:-$slotb_dev}"
        mkdir -p "${boot_mnt}/extlinux"
        cat > "${boot_mnt}/extlinux/extlinux.conf" << EOF
DEFAULT alpine-${slot}
TIMEOUT 30
PROMPT 1

LABEL alpine-A
    MENU LABEL Alpine Linux (Slot A)
    LINUX /vmlinuz-A
    INITRD /initramfs-A
    APPEND root=${slota_root} $(slot_kernel_opts)

LABEL alpine-B
    MENU LABEL Alpine Linux (Slot B)
    LINUX /vmlinuz-B
    INITRD /initramfs-B
    APPEND root=${slotb_root} $(slot_kernel_opts)
EOF
        log_info "Boot config: extlinux default slot $slot (root=${slota_root})"
    fi
}

# Install the extlinux bootloader so an x86_64 BIOS firmware can actually boot
# the disk. install_boot_config only WRITES extlinux.conf; without this the disk
# has no boot code. No-op on RPi (firmware reads the FAT directly). The boot
# partition must be mounted at $boot_mnt (ext4) and hold extlinux/extlinux.conf.
# Layout: GPT + "legacy BIOS bootable" attr on part 1 (set in partition_disk) +
# gptmbr.bin in the protective MBR bootstrap, which chainloads that partition's
# extlinux VBR.
install_bios_bootloader() {
    local disk="$1" boot_mnt="$2"
    [ "$DETECTED_PLATFORM" = "rpi" ] && return 0

    # Ensure an extlinux installer is present (host tool: apk on Alpine, apt on
    # Debian-family installers running without a pivot).
    local extlinux_bin
    extlinux_bin=$(command -v extlinux 2>/dev/null || true)
    if [ -z "$extlinux_bin" ]; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache syslinux >/dev/null 2>&1 || true
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get -qq install -y extlinux syslinux-common >/dev/null 2>&1 || true
        fi
        extlinux_bin=$(command -v extlinux 2>/dev/null || true)
    fi
    [ -n "$extlinux_bin" ] || { log_warn "extlinux not available; x86_64 boot code NOT installed (disk will not boot)"; return 1; }

    # Locate gptmbr.bin + .c32 modules across distro layouts.
    local gptmbr="" c32dir="" d
    for d in /usr/share/syslinux /usr/lib/syslinux/mbr /usr/lib/syslinux/bios \
             /usr/lib/syslinux/modules/bios /usr/lib/SYSLINUX /usr/lib/syslinux; do
        [ -z "$gptmbr" ] && [ -f "$d/gptmbr.bin" ] && gptmbr="$d/gptmbr.bin"
        [ -z "$c32dir" ] && [ -f "$d/ldlinux.c32" ] && c32dir="$d"
    done

    # ldlinux.c32 must sit next to extlinux.conf for extlinux >= 5.
    [ -n "$c32dir" ] && cp "$c32dir"/*.c32 "${boot_mnt}/extlinux/" 2>/dev/null || true

    log_info "Installing extlinux bootloader to ${boot_mnt}/extlinux ..."
    "$extlinux_bin" --install "${boot_mnt}/extlinux" >/dev/null 2>&1 \
        || { log_warn "extlinux --install failed; disk may not boot"; return 1; }

    if [ -n "$gptmbr" ]; then
        log_info "Writing GPT MBR bootstrap ($(basename "$gptmbr")) to $disk ..."
        dd if="$gptmbr" of="$disk" bs=440 count=1 conv=notrunc 2>/dev/null \
            || log_warn "failed to write gptmbr.bin to $disk MBR"
    else
        log_warn "gptmbr.bin not found; BIOS may not find the boot partition"
    fi
    sync
    log_info "x86_64 BIOS bootloader installed (extlinux + gptmbr, legacy_boot on part 1)"
}
