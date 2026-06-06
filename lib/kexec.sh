#!/bin/bash
# kexec.sh - kexec preparation and execution for alpine-anywhere

# =============================================================================
# Kernel Command Line
# =============================================================================

# Build kernel command line parameters
build_kernel_cmdline() {
    local cmdline=""

    # Console settings (both serial and VGA)
    cmdline+="console=tty0 console=ttyS0,115200n8 "

    # Alpine repository
    cmdline+="alpine_repo=${ALPINE_MIRROR}/v${ALPINE_VERSION}/main "

    # Modloop path (will be at this path after transfer)
    cmdline+="modloop=${REMOTE_WORK_DIR}/modloop "

    # Required modules
    cmdline+="modules=loop,squashfs,sd-mod,usb-storage "

    # Network configuration
    local ip_param
    ip_param=$(generate_kernel_ip_param)
    cmdline+="$ip_param "

    # apkovl location
    cmdline+="apkovl=${REMOTE_WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz "

    # SSH authorized keys path (optional, as backup)
    cmdline+="ssh_key=${REMOTE_WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz "

    # Quiet boot (remove for debug)
    if [[ "$VERBOSE" != "true" ]]; then
        cmdline+="quiet "
    fi

    echo "$cmdline"
}

# =============================================================================
# File Transfer
# =============================================================================

# Transfer all files to remote host
transfer_files() {
    local apkovl_file="$1"

    log_step "Transferring files to remote host..."

    # Create remote directory
    ssh_exec_sudo "mkdir -p ${REMOTE_WORK_DIR}"
    ssh_exec_sudo "chmod 755 ${REMOTE_WORK_DIR}"

    # Transfer vmlinuz
    log_info "Transferring vmlinuz..."
    scp_to_remote "${WORK_DIR}/alpine/vmlinuz" "${REMOTE_WORK_DIR}/vmlinuz"

    # Transfer initramfs
    log_info "Transferring initramfs..."
    scp_to_remote "${WORK_DIR}/alpine/initramfs" "${REMOTE_WORK_DIR}/initramfs"

    # Transfer modloop
    log_info "Transferring modloop..."
    scp_to_remote "${WORK_DIR}/alpine/modloop" "${REMOTE_WORK_DIR}/modloop"

    # Transfer apkovl
    log_info "Transferring apkovl..."
    scp_to_remote "$apkovl_file" "${REMOTE_WORK_DIR}/"

    # Verify transfers
    log_debug "Verifying transferred files..."
    ssh_exec_sudo "ls -la ${REMOTE_WORK_DIR}/"

    log_info "All files transferred successfully"
}

# =============================================================================
# kexec Installation
# =============================================================================

# Ensure kexec-tools is installed on remote
ensure_kexec_installed() {
    log_step "Ensuring kexec-tools is installed..."

    # Check if kexec exists
    if ssh_exec_capture "command -v kexec" >/dev/null 2>&1; then
        log_info "kexec is already installed"
        return 0
    fi

    # In dry-run mode, just show what would be installed
    if [[ "$DRY_RUN" == "true" ]]; then
        local distro
        distro=$(ssh_exec_capture "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"'" || true)
        log_info "[DRY-RUN] Would install kexec-tools on $distro"
        return 0
    fi

    # Try to install based on distribution
    local distro
    distro=$(ssh_exec_capture "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"'" || true)

    case "$distro" in
        debian|ubuntu)
            log_info "Installing kexec-tools via apt..."
            ssh_exec_sudo "DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq kexec-tools"
            ;;
        centos|rhel|fedora|rocky|alma)
            log_info "Installing kexec-tools via dnf/yum..."
            ssh_exec_sudo "dnf install -y kexec-tools 2>/dev/null || yum install -y kexec-tools"
            ;;
        arch|manjaro)
            log_info "Installing kexec-tools via pacman..."
            ssh_exec_sudo "pacman -Sy --noconfirm kexec-tools"
            ;;
        alpine)
            log_info "Installing kexec-tools via apk..."
            ssh_exec_sudo "apk add --no-cache kexec-tools"
            ;;
        opensuse*|sles)
            log_info "Installing kexec-tools via zypper..."
            ssh_exec_sudo "zypper -n install kexec-tools"
            ;;
        *)
            die "Unable to install kexec-tools: unknown distribution '$distro'"
            ;;
    esac

    # Verify installation
    if ! ssh_exec_capture "command -v kexec" >/dev/null 2>&1; then
        die "Failed to install kexec-tools"
    fi

    log_info "kexec-tools installed successfully"
}

# =============================================================================
# kexec Execution
# =============================================================================

# Load kernel with kexec
load_kernel() {
    log_step "Loading kernel with kexec..."

    local cmdline
    cmdline=$(build_kernel_cmdline)

    log_debug "Kernel command line: $cmdline"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] kexec -l ${REMOTE_WORK_DIR}/vmlinuz --initrd=${REMOTE_WORK_DIR}/initramfs --command-line=\"$cmdline\""
        return 0
    fi

    # Load the kernel
    ssh_exec_sudo "kexec -l ${REMOTE_WORK_DIR}/vmlinuz --initrd=${REMOTE_WORK_DIR}/initramfs --command-line=\"$cmdline\""

    log_info "Kernel loaded successfully"
}

# Execute kexec (this will reboot into Alpine)
execute_kexec() {
    log_step "Executing kexec (rebooting into Alpine)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would execute: sleep ${REBOOT_DELAY} && kexec -e"
        log_info "[DRY-RUN] Skipping actual kexec execution"
        return 0
    fi

    log_warn "System will reboot in ${REBOOT_DELAY} seconds..."
    log_warn "The SSH connection will be lost."
    echo ""

    # Execute kexec in background so we can disconnect
    # Using nohup and disown to ensure it runs after we disconnect
    ssh_exec_sudo "nohup sh -c 'sleep ${REBOOT_DELAY} && kexec -e' >/dev/null 2>&1 &"

    log_info "kexec scheduled, waiting for system to reboot..."

    # Wait a moment for the command to be scheduled
    sleep 2
}

# =============================================================================
# Complete kexec Flow
# =============================================================================

# Run the complete kexec process
run_kexec() {
    local apkovl_file="$1"

    # Ensure kexec is available
    ensure_kexec_installed

    # Transfer all files
    transfer_files "$apkovl_file"

    # Load kernel
    load_kernel

    # Show summary before execution
    echo ""
    echo "==================================================="
    echo "Ready to boot into Alpine Linux!"
    echo "==================================================="
    echo "Alpine Version: ${ALPINE_VERSION}"
    echo "Kernel Flavor:  ${KERNEL_FLAVOR}"
    echo "Target Host:    ${TARGET_HOST}"
    echo "IP Address:     ${DETECTED_IP_ADDRESS}"
    echo "==================================================="
    echo ""

    # Confirm execution
    confirm_action "This will reboot ${TARGET_HOST} into Alpine Linux. The current OS will be replaced in memory."

    # Execute kexec
    execute_kexec

    if [[ "$DRY_RUN" != "true" ]]; then
        # Wait for host to come back
        sleep "$REBOOT_DELAY"
        sleep 5  # Extra time for boot
        wait_for_host 180

        # Verify Alpine is running
        verify_alpine_boot
    fi
}

# =============================================================================
# kexec Diagnostics
# =============================================================================

# Show kexec diagnostic information
show_kexec_diagnostics() {
    local cmdline
    cmdline=$(build_kernel_cmdline)

    echo ""
    echo "kexec Diagnostics:"
    echo "=================="
    echo ""
    echo "Kernel command line:"
    echo "  $cmdline"
    echo ""
    echo "Files to transfer:"
    echo "  - vmlinuz: ${WORK_DIR}/alpine/vmlinuz"
    echo "  - initramfs: ${WORK_DIR}/alpine/initramfs"
    echo "  - modloop: ${WORK_DIR}/alpine/modloop"
    echo "  - apkovl: ${WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz"
    echo ""
    echo "Remote destination: ${REMOTE_WORK_DIR}"
    echo ""
}
