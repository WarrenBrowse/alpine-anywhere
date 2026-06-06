#!/bin/bash
# validate.sh - Pre-flight validations for alpine-anywhere

# =============================================================================
# Local Validations
# =============================================================================

# Check required local commands
validate_local_commands() {
    log_step "Validating local commands..."

    local required_commands=("ssh" "scp" "curl" "tar" "gzip")
    local missing=()

    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
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

    if [[ -z "$mem_kb" ]]; then
        die "Could not determine remote system memory"
    fi

    local mem_mb=$((mem_kb / 1024))
    local min_mb=512

    log_debug "Remote memory: ${mem_mb}MB"

    if ((mem_mb < min_mb)); then
        die "Insufficient memory: ${mem_mb}MB (minimum: ${min_mb}MB)"
    fi

    log_info "Memory check passed: ${mem_mb}MB available"
}

# Check if kexec is enabled
validate_kexec_enabled() {
    log_step "Validating kexec capability..."

    # Check if kexec_load is disabled via sysctl
    local kexec_disabled
    kexec_disabled=$(ssh_exec_capture "cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null || echo 0")

    if [[ "$kexec_disabled" == "1" ]]; then
        die "kexec is disabled on the remote system. Check /proc/sys/kernel/kexec_load_disabled"
    fi

    # Check if secureboot might block kexec
    local secureboot
    secureboot=$(ssh_exec_capture "cat /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | od -An -tu1 | tail -c 2 | tr -d ' '" || echo "0")

    if [[ "$secureboot" == "1" ]]; then
        log_warn "Secure Boot appears to be enabled. kexec may not work."
        if [[ "$FORCE" != "true" ]]; then
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

    if [[ -z "$space_kb" ]]; then
        log_warn "Could not determine /tmp disk space"
        return 0
    fi

    local space_mb=$((space_kb / 1024))
    local min_mb=500  # Need ~300-400MB for files

    log_debug "Remote /tmp space: ${space_mb}MB"

    if ((space_mb < min_mb)); then
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

    if [[ -z "$os_info" ]]; then
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
    validate_kexec_enabled
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
    echo "kexec enabled:   OK"
    echo "Disk space:      OK"
    echo ""
}
