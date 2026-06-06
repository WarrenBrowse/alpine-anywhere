#!/bin/bash
# upgrade.sh - A/B upgrade management for alpine-anywhere
#
# Handles atomic upgrades with automatic rollback support

# =============================================================================
# Constants
# =============================================================================

BOOT_MOUNT="/boot"
MAX_BOOT_ATTEMPTS=3

# =============================================================================
# Slot Management
# =============================================================================

# Get current boot slot
get_current_slot() {
    if [[ -f "${BOOT_MOUNT}/current_slot" ]]; then
        cat "${BOOT_MOUNT}/current_slot"
    else
        echo "A"
    fi
}

# Get inactive slot
get_inactive_slot() {
    local current
    current=$(get_current_slot)
    if [[ "$current" == "A" ]]; then
        echo "B"
    else
        echo "A"
    fi
}

# Get slot directory
get_slot_dir() {
    local slot="$1"
    echo "${BOOT_MOUNT}/slots/${slot}"
}

# Read slot metadata
get_slot_meta() {
    local slot="$1"
    local key="$2"
    local meta_file
    meta_file="$(get_slot_dir "$slot")/meta.conf"

    if [[ -f "$meta_file" ]]; then
        grep "^${key}=" "$meta_file" | cut -d= -f2
    fi
}

# Update slot metadata
set_slot_meta() {
    local slot="$1"
    local key="$2"
    local value="$3"
    local meta_file
    meta_file="$(get_slot_dir "$slot")/meta.conf"

    if grep -q "^${key}=" "$meta_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$meta_file"
    else
        echo "${key}=${value}" >> "$meta_file"
    fi
}

# =============================================================================
# Upgrade Process
# =============================================================================

# Download new system image
download_new_version() {
    local target_slot="$1"
    local version="${2:-$ALPINE_VERSION}"

    log_step "Downloading Alpine $version..."

    local slot_dir
    slot_dir=$(get_slot_dir "$target_slot")

    # Download minirootfs
    local minirootfs_url="${ALPINE_MIRROR}/v${version}/releases/${DETECTED_ARCH}/alpine-minirootfs-${version}.0-${DETECTED_ARCH}.tar.gz"

    log_info "Downloading minirootfs..."
    curl -fSL --progress-bar -o "${INSTALL_CACHE_DIR}/minirootfs-${version}.tar.gz" "$minirootfs_url"

    # Store version info
    set_slot_meta "$target_slot" "VERSION" "$version"
    set_slot_meta "$target_slot" "DOWNLOADED" "$(date -Iseconds)"
}

# Install new version to inactive slot
install_to_slot() {
    local target_slot="$1"
    local version="${2:-$ALPINE_VERSION}"

    log_step "Installing to slot $target_slot..."

    local slot_dir
    slot_dir=$(get_slot_dir "$target_slot")

    # Clear old files
    rm -f "${slot_dir}/system.squashfs"
    rm -f "${slot_dir}/vmlinuz"
    rm -f "${slot_dir}/initramfs"

    # Generate new system image
    # Use the install.sh function
    INSTALL_CACHE_DIR="${INSTALL_CACHE_DIR:-/var/cache/alpine-anywhere}"
    mkdir -p "$INSTALL_CACHE_DIR"

    # Download if not cached
    if [[ ! -f "${INSTALL_CACHE_DIR}/minirootfs-${version}.tar.gz" ]]; then
        download_new_version "$target_slot" "$version"
    fi

    # Link for generation
    ln -sf "minirootfs-${version}.tar.gz" "${INSTALL_CACHE_DIR}/minirootfs.tar.gz"

    # Generate squashfs
    generate_system_squashfs "$slot_dir" "$target_slot"

    # Copy kernel
    copy_kernel_files "$slot_dir"

    # Update metadata
    set_slot_meta "$target_slot" "INSTALLED" "$(date -Iseconds)"
    set_slot_meta "$target_slot" "BOOT_COUNT" "0"
    set_slot_meta "$target_slot" "VERIFIED" "false"

    log_info "Slot $target_slot updated to version $version"
}

# Switch to new slot
switch_slot() {
    local new_slot="$1"

    log_step "Switching to slot $new_slot..."

    # Update current slot marker
    echo "$new_slot" > "${BOOT_MOUNT}/current_slot"

    # Update bootloader
    update_bootloader_slot "$new_slot"

    log_info "Boot slot switched to $new_slot"
    log_warn "Reboot to activate new system"
}

# Update bootloader to point to new slot
update_bootloader_slot() {
    local slot="$1"

    # Update extlinux if present
    if [[ -f "${BOOT_MOUNT}/extlinux/extlinux.conf" ]]; then
        sed -i "s|/slots/[AB]/|/slots/${slot}/|g" "${BOOT_MOUNT}/extlinux/extlinux.conf"
    fi

    # Update cmdline.txt for RPi
    if [[ -f "${BOOT_MOUNT}/cmdline.txt" ]]; then
        sed -i "s|/slots/[AB]/|/slots/${slot}/|g" "${BOOT_MOUNT}/cmdline.txt"
    fi

    # Update GRUB if present
    if [[ -f "${BOOT_MOUNT}/bootloader/grub.cfg" ]]; then
        echo "set slot=${slot}" > "${BOOT_MOUNT}/current_slot.cfg"
    fi
}

# =============================================================================
# Rollback Support
# =============================================================================

# Mark current slot as verified (called after successful boot)
verify_current_slot() {
    local current
    current=$(get_current_slot)

    set_slot_meta "$current" "VERIFIED" "true"
    log_info "Slot $current verified as working"
}

# Increment boot counter (called at boot)
increment_boot_counter() {
    local current
    current=$(get_current_slot)

    local count
    count=$(get_slot_meta "$current" "BOOT_COUNT")
    count=$((count + 1))

    set_slot_meta "$current" "BOOT_COUNT" "$count"

    # Check if we've exceeded max attempts
    if ((count > MAX_BOOT_ATTEMPTS)); then
        local verified
        verified=$(get_slot_meta "$current" "VERIFIED")
        if [[ "$verified" != "true" ]]; then
            log_warn "Boot count exceeded, triggering rollback..."
            rollback_slot
        fi
    fi
}

# Rollback to previous slot
rollback_slot() {
    local current
    current=$(get_current_slot)

    local previous
    previous=$(get_inactive_slot)

    log_warn "Rolling back from $current to $previous..."

    # Check if previous slot is valid
    local prev_version
    prev_version=$(get_slot_meta "$previous" "VERSION")
    if [[ -z "$prev_version" ]]; then
        log_error "Cannot rollback: previous slot has no valid version"
        return 1
    fi

    # Switch
    switch_slot "$previous"

    log_info "Rollback complete. Rebooting..."
    reboot
}

# =============================================================================
# Upgrade Command
# =============================================================================

# Run upgrade process
run_upgrade() {
    local version="${1:-$ALPINE_VERSION}"

    log_step "Starting upgrade to Alpine $version..."

    local current
    current=$(get_current_slot)

    local target
    target=$(get_inactive_slot)

    log_info "Current slot: $current"
    log_info "Target slot: $target"

    # Show current version
    local current_version
    current_version=$(get_slot_meta "$current" "VERSION")
    log_info "Current version: ${current_version:-unknown}"
    log_info "Target version: $version"

    # Confirm
    if [[ "$DRY_RUN" != "true" && "$FORCE" != "true" ]]; then
        echo ""
        echo "This will:"
        echo "  1. Download Alpine $version"
        echo "  2. Install to slot $target"
        echo "  3. Switch boot to slot $target"
        echo ""
        echo "Current slot $current will be preserved for rollback."
        echo ""
        confirm_action "Proceed with upgrade?"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would upgrade to $version in slot $target"
        return 0
    fi

    # Install to inactive slot
    install_to_slot "$target" "$version"

    # Switch slot
    switch_slot "$target"

    echo ""
    echo "=========================================="
    echo "         UPGRADE COMPLETE"
    echo "=========================================="
    echo ""
    echo "Alpine $version installed to slot $target"
    echo ""
    echo "To activate:"
    echo "  sudo reboot"
    echo ""
    echo "If the new version fails to boot $MAX_BOOT_ATTEMPTS times,"
    echo "automatic rollback to slot $current will occur."
    echo ""
    echo "After successful boot, run:"
    echo "  alpine-anywhere verify"
    echo ""
}

# =============================================================================
# Status Command
# =============================================================================

# Show current status
show_status() {
    echo "Alpine Anywhere A/B Status"
    echo "=========================="
    echo ""

    local current
    current=$(get_current_slot)
    echo "Current slot: $current"
    echo ""

    for slot in A B; do
        local slot_dir
        slot_dir=$(get_slot_dir "$slot")

        echo "Slot $slot:"
        if [[ -f "${slot_dir}/meta.conf" ]]; then
            echo "  Version:    $(get_slot_meta "$slot" "VERSION")"
            echo "  Installed:  $(get_slot_meta "$slot" "INSTALLED")"
            echo "  Boot count: $(get_slot_meta "$slot" "BOOT_COUNT")"
            echo "  Verified:   $(get_slot_meta "$slot" "VERIFIED")"
        else
            echo "  (empty)"
        fi

        if [[ -f "${slot_dir}/system.squashfs" ]]; then
            local size
            size=$(du -h "${slot_dir}/system.squashfs" | cut -f1)
            echo "  Image size: $size"
        fi
        echo ""
    done
}
