#!/bin/bash
# remote.sh - Remote script generation for alpine-anywhere

# Remote paths (detected)
REMOTE_HOME=""
REMOTE_WORK_DIR=""

# Detect remote home directory
detect_remote_home() {
    REMOTE_HOME=$(ssh_exec_capture 'echo $HOME')
    REMOTE_WORK_DIR="${REMOTE_HOME}/alpine-anywhere"
    log_debug "Remote home: $REMOTE_HOME"
    log_debug "Remote work dir: $REMOTE_WORK_DIR"
}

# =============================================================================
# Remote Execution
# =============================================================================

# Run installation on remote host
run_remote_install() {
    local apkovl_file="$1"
    local apkovl_name
    apkovl_name=$(basename "$apkovl_file")

    # Detect remote home first
    detect_remote_home

    log_step "Setting up remote installation..."

    # Create remote directory
    ssh_exec "mkdir -p ${REMOTE_WORK_DIR}"

    # Transfer apkovl (contains custom network/SSH config)
    log_info "Transferring apkovl..."
    scp_to_remote "$apkovl_file" "${REMOTE_WORK_DIR}/"

    # Download Alpine files directly on remote
    log_info "Downloading Alpine files on remote host..."
    local base_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/netboot"

    ssh_exec "cd ${REMOTE_WORK_DIR} && curl -fSL --progress-bar -o vmlinuz '${base_url}/vmlinuz-${KERNEL_FLAVOR}'"
    ssh_exec "cd ${REMOTE_WORK_DIR} && curl -fSL --progress-bar -o initramfs '${base_url}/initramfs-${KERNEL_FLAVOR}'"
    ssh_exec "cd ${REMOTE_WORK_DIR} && curl -fSL --progress-bar -o modloop '${base_url}/modloop-${KERNEL_FLAVOR}'"

    # Verify downloads
    log_info "Verifying downloads..."
    ssh_exec "ls -lh ${REMOTE_WORK_DIR}/"

    # Generate kexec script
    log_info "Generating kexec.sh script..."
    generate_and_install_kexec_script "$apkovl_name"

    # Write install log
    ssh_exec "echo '[$(date -Iseconds)] Installation complete' >> ${REMOTE_WORK_DIR}/install.log"

    log_info "Remote installation complete"
    log_info "Files installed in ${REMOTE_WORK_DIR}/"
}

# Generate and install kexec script on remote
generate_and_install_kexec_script() {
    local apkovl_name="$1"
    local cmdline
    cmdline=$(build_kernel_cmdline_for_remote)

    # Generate script content
    local script_content
    read -r -d '' script_content << KEXECSCRIPT || true
#!/bin/bash
# alpine-anywhere kexec launcher
# Generated: $(date -Iseconds)
# Target: ${DETECTED_HOSTNAME}
#
# Usage: sudo ./kexec.sh [--dry-run]

set -e

WORK_DIR="${REMOTE_WORK_DIR}"
LOG_FILE="\${WORK_DIR}/kexec.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG_FILE"
}

cd "\$WORK_DIR"

log "=== Alpine Anywhere Kexec ==="

# Verify files
for f in vmlinuz initramfs modloop ${apkovl_name}; do
    if [[ ! -f "\$f" ]]; then
        log "ERROR: Missing file: \$f"
        exit 1
    fi
done
log "All files present"

CMDLINE="${cmdline}"

if [[ "\$1" == "--dry-run" ]]; then
    log "[DRY-RUN] kexec -l \$WORK_DIR/vmlinuz --initrd=\$WORK_DIR/initramfs"
    log "[DRY-RUN] cmdline: \$CMDLINE"
    exit 0
fi

if [[ \$EUID -ne 0 ]]; then
    log "ERROR: Must run as root (use sudo)"
    exit 1
fi

log "Loading kernel..."
kexec -l "\$WORK_DIR/vmlinuz" --initrd="\$WORK_DIR/initramfs" --command-line="\$CMDLINE"

log "Kernel loaded. Executing in 5 seconds..."
sleep 5
log "kexec -e"
exec kexec -e
KEXECSCRIPT

    # Write script to remote using heredoc via ssh
    ssh_exec "cat > ${REMOTE_WORK_DIR}/kexec.sh << 'ENDSCRIPT'
${script_content}
ENDSCRIPT"
    ssh_exec "chmod +x ${REMOTE_WORK_DIR}/kexec.sh"
}

# Build kernel cmdline for remote execution (absolute paths)
build_kernel_cmdline_for_remote() {
    local cmdline=""

    # Console settings
    cmdline+="console=tty0 console=ttyS0,115200n8 "

    # Alpine repository
    cmdline+="alpine_repo=${ALPINE_MIRROR}/v${ALPINE_VERSION}/main "

    # Modloop path (absolute)
    cmdline+="modloop=${REMOTE_WORK_DIR}/modloop "

    # Required modules
    cmdline+="modules=loop,squashfs,sd-mod,usb-storage "

    # Network configuration
    local ip_param
    ip_param=$(generate_kernel_ip_param)
    cmdline+="$ip_param "

    # apkovl location (absolute)
    cmdline+="apkovl=${REMOTE_WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz "

    echo "$cmdline"
}

# Execute kexec on remote
run_remote_kexec() {
    log_step "Executing kexec on remote host..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would run: sudo ${REMOTE_WORK_DIR}/kexec.sh"
        ssh_exec "${REMOTE_WORK_DIR}/kexec.sh --dry-run"
        return 0
    fi

    # Show summary
    echo ""
    echo "==================================================="
    echo "Ready to boot into Alpine Linux!"
    echo "==================================================="
    echo "Alpine Version: ${ALPINE_VERSION}"
    echo "Kernel Flavor:  ${KERNEL_FLAVOR}"
    echo "Target Host:    ${TARGET_HOST}"
    echo "IP Address:     ${DETECTED_IP_ADDRESS}"
    echo "Remote Dir:     ${REMOTE_WORK_DIR}"
    echo "==================================================="
    echo ""

    # Confirm
    confirm_action "This will reboot ${TARGET_HOST} into Alpine Linux."

    log_warn "System will reboot..."

    # Execute kexec script with sudo
    ssh_exec_sudo "${REMOTE_WORK_DIR}/kexec.sh"
}
