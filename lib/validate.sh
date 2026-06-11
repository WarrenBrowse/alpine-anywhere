#!/bin/sh
# validate.sh - Pre-flight validations for alpine-anywhere

# =============================================================================
# Input sanitization
# =============================================================================
#
# Values that end up on the kernel command line (root=, ip=, modloop=, apkovl=,
# alpine_repo=) are placed inside `--command-line="..."`, where shell quoting
# does NOT protect us (the kernel re-parses the string). The only safe defence
# is to constrain these inputs to a benign character set at the source. Anything
# that reaches a remote shell is additionally shell_quote'd, but these tokens
# get a charset check on top.

# Abort unless VALUE matches the safe-token charset (alnum and . _ / : = , @ + -).
# Empty values pass (callers gate on emptiness separately where it matters).
# Usage: assert_safe_token NAME "$VALUE"
assert_safe_token() {
    _ast_name="$1"; _ast_val="$2"
    case "$_ast_val" in
        '') return 0 ;;
        *[!A-Za-z0-9._/:=,@+-]*)
            die "unsafe characters in ${_ast_name}: '${_ast_val}' (allowed: alphanumerics and . _ / : = , @ + -)"
            ;;
    esac
    return 0
}

# Validate the inputs that flow into remote shells and the kernel cmdline.
# Call after parse_arguments and after network detection populates DETECTED_*.
validate_safe_inputs() {
    assert_safe_token "alpine-version" "$ALPINE_VERSION"
    assert_safe_token "mirror" "$ALPINE_MIRROR"
    assert_safe_token "kernel-flavor" "$KERNEL_FLAVOR"
    assert_safe_token "ssh-port" "$SSH_PORT"
    assert_safe_token "target-disk" "$TARGET_DISK"
    assert_safe_token "target-slot" "$TARGET_SLOT"
    assert_safe_token "overlay-device" "$OVERLAY_DEVICE"
    assert_safe_token "extra-packages" "$EXTRA_PACKAGES"
    # DETECTED_* may be empty before network detection; checked again post-detect
    assert_safe_token "detected-hostname" "$DETECTED_HOSTNAME"
    assert_safe_token "detected-interface" "$DETECTED_INTERFACE"
    assert_safe_token "detected-ip" "$DETECTED_IP_ADDRESS"
    assert_safe_token "detected-netmask" "$DETECTED_NETMASK"
    assert_safe_token "detected-gateway" "$DETECTED_GATEWAY"
    assert_safe_token "detected-cidr" "$DETECTED_CIDR"
    # SSH_PORT must be numeric on top of the charset check
    case "$SSH_PORT" in
        ''|*[!0-9]*) die "SSH port must be numeric: '$SSH_PORT'" ;;
    esac
    # TARGET_DISK, when set, must look like a device path
    if [ -n "$TARGET_DISK" ]; then
        case "$TARGET_DISK" in
            /dev/*) : ;;
            *) die "target disk must be a /dev path: '$TARGET_DISK'" ;;
        esac
    fi

    # Data-persistence inputs
    assert_safe_token "key-url" "$KEY_URL"
    assert_safe_token "key-file" "$KEY_FILE"
    case "$DATA_FS" in btrfs|ext4) ;; *) die "invalid --data-fs '$DATA_FS' (btrfs|ext4)" ;; esac
    case "$UNLOCK_METHOD" in ssh|keyfile|passphrase) ;; *) die "invalid --unlock-method '$UNLOCK_METHOD' (ssh|keyfile|passphrase)" ;; esac
    case "$CONTAINERS" in none|podman|docker|both) ;; *) die "invalid --containers '$CONTAINERS' (none|podman|docker|both)" ;; esac
    case "$CONTAINER_RUNTIME" in crun|runsc) ;; *) die "invalid --container-runtime '$CONTAINER_RUNTIME' (crun|runsc)" ;; esac
    # keyfile method: --key-url fetches the key at boot, --key-file bakes a provided
    # key onto the boot partition; with NEITHER, aa generates a random key and
    # stages it there itself (zero-config autonomous unlock).

    # Customization inputs: fail early on the control host if the path is missing
    # (run_custom_script re-checks inside the chroot, but a clear message here
    # avoids deploying only to abort mid-build).
    if [ -n "$CUSTOM_SCRIPT" ] && [ ! -f "$CUSTOM_SCRIPT" ]; then
        die "custom script not found: '$CUSTOM_SCRIPT'"
    fi
    if [ -n "$CUSTOM_FILES" ] && [ ! -e "$CUSTOM_FILES" ]; then
        die "custom files path not found: '$CUSTOM_FILES'"
    fi
}

# =============================================================================
# Local Validations
# =============================================================================

# Check required local commands
validate_local_commands() {
    log_step "Validating local commands..."

    # In local mode we run ON the target, so ssh/scp (control-host tools) are
    # not needed there; only the archive tools are. A download tool (curl OR
    # busybox wget) is required in both modes.
    local required_commands
    if [ "$LOCAL_MODE" = "true" ]; then
        required_commands="tar gzip"
    else
        required_commands="ssh tar gzip"
    fi
    local missing=""

    for cmd in $required_commands; do
        if ! command_exists "$cmd"; then
            missing="${missing:+$missing }$cmd"
        fi
    done

    # Need at least one HTTP download tool
    if ! command_exists curl && ! command_exists wget; then
        missing="${missing:+$missing }curl-or-wget"
    fi

    if [ -n "$missing" ]; then
        die "Missing required commands: $missing"
    fi

    log_info "All required local commands are available"
}

# =============================================================================
# Remote Validations
# =============================================================================

# Check remote system memory
validate_remote_memory() {
    log_step "Validating remote memory..."

    local mem_kb
    mem_kb=$(ssh_exec_capture "grep MemTotal /proc/meminfo | awk '{print \$2}'")

    if [ -z "$mem_kb" ]; then
        die "Could not determine remote system memory"
    fi

    local mem_mb=$((mem_kb / 1024))
    local min_mb=512

    log_debug "Remote memory: ${mem_mb}MB"

    if [ "$mem_mb" -lt "$min_mb" ]; then
        die "Insufficient memory: ${mem_mb}MB (minimum: ${min_mb}MB)"
    fi

    log_info "Memory check passed: ${mem_mb}MB available"
}

# Check if kexec is enabled
validate_kexec_enabled() {
    log_step "Validating kexec capability..."

    # Check if kernel has CONFIG_KEXEC compiled in
    local kexec_config=""

    # Try /proc/config.gz first (requires CONFIG_IKCONFIG_PROC)
    kexec_config=$(ssh_exec_capture "zcat /proc/config.gz 2>/dev/null | grep '^CONFIG_KEXEC=' || true")

    # Fallback to /boot/config-*
    if [ -z "$kexec_config" ]; then
        local kernel_version
        kernel_version=$(ssh_exec_capture "uname -r")
        kexec_config=$(ssh_exec_capture "grep '^CONFIG_KEXEC=' /boot/config-${kernel_version} 2>/dev/null || true")
    fi

    if [ -n "$kexec_config" ]; then
        if [ "$kexec_config" != "CONFIG_KEXEC=y" ]; then
            log_error "Kernel does not have kexec support compiled in"
            log_error "Found: $kexec_config"
            log_error ""
            log_error "The running kernel needs CONFIG_KEXEC=y to use kexec."
            log_error ""
            log_error "On Raspberry Pi / Armbian, you may need to:"
            log_error "  1. Install a kernel with kexec support"
            log_error "  2. Or recompile the kernel with CONFIG_KEXEC=y"
            log_error ""
            log_error "Check available kernels: apt search linux-image"
            die "Kernel kexec support not available"
        fi
        log_debug "Kernel kexec support: CONFIG_KEXEC=y"
    else
        log_warn "Could not verify kernel kexec support (config not accessible)"
        log_warn "Will attempt kexec anyway - it may fail at runtime"
    fi

    # Check if kexec_load is disabled via sysctl
    local kexec_disabled
    kexec_disabled=$(ssh_exec_capture "cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null || echo 0")

    if [ "$kexec_disabled" = "1" ]; then
        die "kexec is disabled on the remote system. Check /proc/sys/kernel/kexec_load_disabled"
    fi

    # Check if secureboot might block kexec
    local secureboot
    secureboot=$(ssh_exec_capture "cat /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | od -An -tu1 | tail -c 2 | tr -d ' '" || echo "0")

    if [ "$secureboot" = "1" ]; then
        log_warn "Secure Boot appears to be enabled. kexec may not work."
        if [ "$FORCE" != "true" ]; then
            die "Secure Boot is enabled and may prevent kexec. Use --force to try anyway."
        fi
    fi

    log_info "kexec capability check passed"
}

# Check remote disk space in /tmp
validate_remote_disk_space() {
    log_step "Validating remote disk space..."

    local space_kb
    space_kb=$(ssh_exec_capture "df /tmp 2>/dev/null | tail -1 | awk '{print \$4}'")

    if [ -z "$space_kb" ]; then
        log_warn "Could not determine /tmp disk space"
        return 0
    fi

    local space_mb=$((space_kb / 1024))
    local min_mb=500  # Need ~300-400MB for files

    log_debug "Remote /tmp space: ${space_mb}MB"

    if [ "$space_mb" -lt "$min_mb" ]; then
        die "Insufficient disk space in /tmp: ${space_mb}MB (minimum: ${min_mb}MB)"
    fi

    log_info "Disk space check passed: ${space_mb}MB available in /tmp"
}

# Check if the system is a VM or physical (informational)
detect_virtualization() {
    log_step "Detecting virtualization..."

    local virt_type
    virt_type=$(ssh_exec_capture "systemd-detect-virt 2>/dev/null || cat /sys/class/dmi/id/product_name 2>/dev/null | head -1 || echo 'unknown'")

    case "$virt_type" in
        none|"")
            log_info "System appears to be bare metal"
            ;;
        kvm|qemu)
            log_info "System is running under KVM/QEMU"
            ;;
        vmware)
            log_info "System is running under VMware"
            ;;
        xen*)
            log_info "System is running under Xen"
            ;;
        microsoft|hyperv)
            log_info "System is running under Hyper-V"
            ;;
        *)
            log_info "Virtualization: $virt_type"
            ;;
    esac
}

# Check current OS (informational)
detect_current_os() {
    log_step "Detecting current OS..."

    local os_info
    os_info=$(ssh_exec_capture "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'" || true)

    if [ -z "$os_info" ]; then
        os_info=$(ssh_exec_capture "uname -a")
    fi

    log_info "Current OS: $os_info"
}

# =============================================================================
# Run All Validations
# =============================================================================

# Run all local validations
run_local_validations() {
    log_step "Running local validations..."

    validate_local_commands
}

# Run all remote validations
run_remote_validations() {
    log_step "Running remote validations..."

    validate_remote_memory
    # Note: kexec validation moved to determine_install_method (after method selection)
    validate_remote_disk_space
    detect_virtualization
    detect_current_os
}

# Run complete validation suite
run_all_validations() {
    log_step "Running pre-flight validations..."

    run_local_validations

    # Test SSH connection first
    test_ssh_connection
    check_root_access

    run_remote_validations

    log_info "All validations passed"
}

# =============================================================================
# Method Selection
# =============================================================================

# Check if kexec is available (for auto method selection)
is_kexec_available() {
    # Check if kernel has CONFIG_KEXEC compiled in
    local kexec_config=""

    # Try /proc/config.gz first
    kexec_config=$(ssh_exec_capture "zcat /proc/config.gz 2>/dev/null | grep '^CONFIG_KEXEC=' || true")

    # Fallback to /boot/config-*
    if [ -z "$kexec_config" ]; then
        local kernel_version
        kernel_version=$(ssh_exec_capture "uname -r")
        kexec_config=$(ssh_exec_capture "grep '^CONFIG_KEXEC=' /boot/config-${kernel_version} 2>/dev/null || true")
    fi

    if [ "$kexec_config" = "CONFIG_KEXEC=y" ]; then
        return 0
    fi

    # If we can't determine, assume not available (safer)
    if [ -z "$kexec_config" ]; then
        # Try to check if kexec_load syscall works
        # This is a more reliable test but requires attempting to call it
        return 1
    fi

    return 1
}

# Determine the installation method to use
determine_install_method() {
    log_step "Determining installation method..."

    if [ "$INSTALL_METHOD" = "auto" ]; then
        log_info "Auto-detecting best installation method..."

        if is_kexec_available; then
            INSTALL_METHOD="kexec"
            log_info "kexec is available - using kexec method"
        else
            INSTALL_METHOD="takeover"
            log_info "kexec not available - using takeover method"
        fi
    fi

    log_info "Installation method: ${INSTALL_METHOD}"

    # Additional validation for selected method
    case "$INSTALL_METHOD" in
        kexec)
            # Validate kexec is actually usable
            validate_kexec_enabled
            ;;
        takeover)
            # Check takeover prerequisites (done later in run_takeover_install)
            log_debug "Takeover method selected - will validate during installation"
            ;;
    esac
}

# =============================================================================
# Validation Summary
# =============================================================================

print_validation_summary() {
    echo ""
    echo "Validation Summary:"
    echo "==================="
    echo "Local commands:  OK"
    echo "SSH connection:  OK"
    echo "Root access:     OK"
    echo "Remote memory:   OK"
    echo "Disk space:      OK"
    echo "Install method:  ${INSTALL_METHOD}"
    echo ""
}
