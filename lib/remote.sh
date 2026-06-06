#!/bin/sh
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
# Alpine File Downloads
# =============================================================================

# Download standard netboot files (for generic x86_64 and EFI aarch64)
download_alpine_netboot_files() {
    local base_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/netboot"

    ssh_exec "echo 'Download type: netboot' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo 'Base URL: ${base_url}' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"

    # Download with logging
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Downloading vmlinuz-${KERNEL_FLAVOR}...' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "cd ${REMOTE_WORK_DIR} && curl -fSL --progress-bar -o vmlinuz '${base_url}/vmlinuz-${KERNEL_FLAVOR}' 2>&1 | tee -a install.log"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] vmlinuz download complete' >> ${REMOTE_WORK_DIR}/install.log"

    ssh_exec "echo '['\"$(date -Iseconds)\"'] Downloading initramfs-${KERNEL_FLAVOR}...' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "cd ${REMOTE_WORK_DIR} && curl -fSL --progress-bar -o initramfs '${base_url}/initramfs-${KERNEL_FLAVOR}' 2>&1 | tee -a install.log"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] initramfs download complete' >> ${REMOTE_WORK_DIR}/install.log"

    ssh_exec "echo '['\"$(date -Iseconds)\"'] Downloading modloop-${KERNEL_FLAVOR}...' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "cd ${REMOTE_WORK_DIR} && curl -fSL --progress-bar -o modloop '${base_url}/modloop-${KERNEL_FLAVOR}' 2>&1 | tee -a install.log"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] modloop download complete' >> ${REMOTE_WORK_DIR}/install.log"
}

# Download Raspberry Pi specific files
download_alpine_rpi_files() {
    log_info "Downloading Alpine files for Raspberry Pi..."

    # Determine kernel suffix based on RPi version
    local kernel_suffix="rpi"
    if [ "$DETECTED_RPI_VERSION" = "4" ] || [ "$DETECTED_RPI_VERSION" = "5" ]; then
        kernel_suffix="rpi4"
    fi

    # Find the latest alpine-rpi release
    local releases_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}"
    local tarball_name

    ssh_exec "echo 'Download type: Raspberry Pi' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo 'RPi version: ${DETECTED_RPI_VERSION}' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo 'Kernel suffix: ${kernel_suffix}' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo 'Releases URL: ${releases_url}' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"

    # Find the tarball name from the releases page
    log_info "Finding latest alpine-rpi tarball..."
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Finding latest alpine-rpi tarball...' >> ${REMOTE_WORK_DIR}/install.log"

    tarball_name=$(ssh_exec_capture "curl -fsSL '${releases_url}/' 2>/dev/null | grep -oE 'alpine-rpi-[0-9.]+-aarch64\\.tar\\.gz' | head -1")

    if [ -z "$tarball_name" ]; then
        # Fallback to constructed name
        tarball_name="alpine-rpi-${ALPINE_VERSION}.0-aarch64.tar.gz"
        log_warn "Could not find tarball, trying: $tarball_name"
    fi

    ssh_exec "echo 'Tarball: ${tarball_name}' >> ${REMOTE_WORK_DIR}/install.log"

    local tarball_url="${releases_url}/${tarball_name}"
    log_info "Downloading $tarball_name..."

    # Download tarball
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Downloading ${tarball_name}...' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "cd ${REMOTE_WORK_DIR} && curl -fSL --progress-bar -o alpine-rpi.tar.gz '${tarball_url}' 2>&1 | tee -a install.log"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Tarball download complete' >> ${REMOTE_WORK_DIR}/install.log"

    # Extract required files
    log_info "Extracting kernel files..."
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Extracting kernel files...' >> ${REMOTE_WORK_DIR}/install.log"

    # List contents to log for debugging
    ssh_exec "echo '--- Tarball contents (boot/) ---' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "cd ${REMOTE_WORK_DIR} && tar -tzf alpine-rpi.tar.gz | grep -E 'boot/' | head -20 >> install.log 2>&1"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"

    # Extract boot files (note: paths in tarball start with ./)
    ssh_exec "cd ${REMOTE_WORK_DIR} && tar -xzf alpine-rpi.tar.gz ./boot/ 2>&1 | tee -a install.log"

    # Find and copy the right kernel
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Selecting kernel files...' >> ${REMOTE_WORK_DIR}/install.log"

    # Try kernel suffix (rpi4 for Pi 4/5, rpi for older)
    local vmlinuz_found=false
    local used_suffix=""

    if ssh_exec_capture "test -f ${REMOTE_WORK_DIR}/boot/vmlinuz-${kernel_suffix}" >/dev/null 2>&1; then
        ssh_exec "cp ${REMOTE_WORK_DIR}/boot/vmlinuz-${kernel_suffix} ${REMOTE_WORK_DIR}/vmlinuz"
        ssh_exec "cp ${REMOTE_WORK_DIR}/boot/initramfs-${kernel_suffix} ${REMOTE_WORK_DIR}/initramfs"
        ssh_exec "echo 'Using kernel: vmlinuz-${kernel_suffix}' >> ${REMOTE_WORK_DIR}/install.log"
        vmlinuz_found=true
        used_suffix="${kernel_suffix}"
    fi

    # Fallback to generic rpi if specific not found
    if [ "$vmlinuz_found" != "true" ] && ssh_exec_capture "test -f ${REMOTE_WORK_DIR}/boot/vmlinuz-rpi" >/dev/null 2>&1; then
        ssh_exec "cp ${REMOTE_WORK_DIR}/boot/vmlinuz-rpi ${REMOTE_WORK_DIR}/vmlinuz"
        ssh_exec "cp ${REMOTE_WORK_DIR}/boot/initramfs-rpi ${REMOTE_WORK_DIR}/initramfs"
        ssh_exec "echo 'Using kernel: vmlinuz-rpi (fallback)' >> ${REMOTE_WORK_DIR}/install.log"
        vmlinuz_found=true
        used_suffix="rpi"
    fi

    if [ "$vmlinuz_found" != "true" ]; then
        # List available kernels for debugging
        ssh_exec "echo 'ERROR: No suitable kernel found!' >> ${REMOTE_WORK_DIR}/install.log"
        ssh_exec "echo 'Available files:' >> ${REMOTE_WORK_DIR}/install.log"
        ssh_exec "ls -la ${REMOTE_WORK_DIR}/boot/ >> ${REMOTE_WORK_DIR}/install.log 2>&1"
        die "Could not find suitable kernel for Raspberry Pi ${DETECTED_RPI_VERSION}"
    fi

    # Copy modloop from extracted tarball (it's included in alpine-rpi)
    log_info "Copying modloop..."
    if ssh_exec_capture "test -f ${REMOTE_WORK_DIR}/boot/modloop-${used_suffix}" >/dev/null 2>&1; then
        ssh_exec "cp ${REMOTE_WORK_DIR}/boot/modloop-${used_suffix} ${REMOTE_WORK_DIR}/modloop"
        ssh_exec "echo 'Using modloop: modloop-${used_suffix}' >> ${REMOTE_WORK_DIR}/install.log"
    elif ssh_exec_capture "test -f ${REMOTE_WORK_DIR}/boot/modloop-rpi" >/dev/null 2>&1; then
        ssh_exec "cp ${REMOTE_WORK_DIR}/boot/modloop-rpi ${REMOTE_WORK_DIR}/modloop"
        ssh_exec "echo 'Using modloop: modloop-rpi (fallback)' >> ${REMOTE_WORK_DIR}/install.log"
    else
        ssh_exec "echo 'ERROR: No modloop found in tarball!' >> ${REMOTE_WORK_DIR}/install.log"
        die "Could not find modloop for Raspberry Pi"
    fi

    # Cleanup extracted files
    ssh_exec "rm -rf ${REMOTE_WORK_DIR}/boot ${REMOTE_WORK_DIR}/alpine-rpi.tar.gz"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Cleanup complete' >> ${REMOTE_WORK_DIR}/install.log"
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

    # Initialize install log with header
    ssh_exec "cat > ${REMOTE_WORK_DIR}/install.log << 'LOGHEADER'
================================================================================
alpine-anywhere Installation Log
================================================================================
Generated: $(date -Iseconds)
Alpine Version: ${ALPINE_VERSION}
Kernel Flavor: ${KERNEL_FLAVOR}
Target Host: ${DETECTED_HOSTNAME}
Architecture: ${DETECTED_ARCH}
IP Address: ${DETECTED_IP_ADDRESS}
Network Mode: $([ "$NETWORK_IS_DHCP" = "true" ] && echo "DHCP" || echo "Static")
================================================================================

LOGHEADER"

    # Log system info
    log_info "Collecting system information..."
    ssh_exec "echo '--- System Info ---' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "uname -a >> ${REMOTE_WORK_DIR}/install.log 2>&1 || true"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '--- kexec Info ---' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "which kexec >> ${REMOTE_WORK_DIR}/install.log 2>&1 || echo 'kexec: not in PATH' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "ls -la /sbin/kexec /usr/sbin/kexec >> ${REMOTE_WORK_DIR}/install.log 2>&1 || true"
    ssh_exec "kexec --version >> ${REMOTE_WORK_DIR}/install.log 2>&1 || /sbin/kexec --version >> ${REMOTE_WORK_DIR}/install.log 2>&1 || true"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '--- Secure Boot ---' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "cat /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | xxd | head -1 >> ${REMOTE_WORK_DIR}/install.log || echo 'Cannot read SecureBoot status' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"

    # Transfer apkovl (contains custom network/SSH config)
    log_info "Transferring apkovl..."
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Transferring apkovl: ${apkovl_name}' >> ${REMOTE_WORK_DIR}/install.log"
    scp_to_remote "$apkovl_file" "${REMOTE_WORK_DIR}/"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] apkovl transferred successfully' >> ${REMOTE_WORK_DIR}/install.log"

    # Download Alpine files directly on remote
    log_info "Downloading Alpine files on remote host..."

    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '--- Download ---' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo 'Platform: ${DETECTED_PLATFORM}' >> ${REMOTE_WORK_DIR}/install.log"

    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        download_alpine_rpi_files
    else
        download_alpine_netboot_files
    fi

    # Verify downloads with detailed info
    log_info "Verifying downloads..."
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '--- Downloaded Files ---' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "ls -lh ${REMOTE_WORK_DIR}/ >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '--- File Types ---' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "file ${REMOTE_WORK_DIR}/vmlinuz ${REMOTE_WORK_DIR}/initramfs ${REMOTE_WORK_DIR}/modloop >> ${REMOTE_WORK_DIR}/install.log 2>&1"
    ssh_exec "ls -lh ${REMOTE_WORK_DIR}/"

    # Generate kexec script
    log_info "Generating kexec.sh script..."
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Generating kexec.sh script' >> ${REMOTE_WORK_DIR}/install.log"
    generate_and_install_kexec_script "$apkovl_name"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] kexec.sh generated' >> ${REMOTE_WORK_DIR}/install.log"

    # Final log entry
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '=================================================================================' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '['\"$(date -Iseconds)\"'] Installation complete' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '=================================================================================' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo 'To boot into Alpine Linux:' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '  sudo ${REMOTE_WORK_DIR}/kexec.sh' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo 'Debug options:' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '  ${REMOTE_WORK_DIR}/kexec.sh --info     # Show file info (no root)' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '  ${REMOTE_WORK_DIR}/kexec.sh --dry-run  # Dry run (no root)' >> ${REMOTE_WORK_DIR}/install.log"
    ssh_exec "echo '  sudo ${REMOTE_WORK_DIR}/kexec.sh --debug  # Verbose execution' >> ${REMOTE_WORK_DIR}/install.log"

    log_info "Remote installation complete"
    log_info "Files installed in ${REMOTE_WORK_DIR}/"
}

# Generate and install kexec script on remote
generate_and_install_kexec_script() {
    local apkovl_name="$1"
    local cmdline
    cmdline=$(build_kernel_cmdline_for_remote)

    # Generate script content
    local platform_info="${DETECTED_ARCH}"
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        platform_info="Raspberry Pi ${DETECTED_RPI_VERSION} (${DETECTED_ARCH})"
    fi

    # Write kexec script to local temp, then scp to remote
    local kexec_script="${WORK_DIR}/kexec.sh"
    cat > "$kexec_script" << KEXECSCRIPT
#!/bin/sh
# alpine-anywhere kexec launcher
# Generated: $(date -Iseconds)
# Target: ${DETECTED_HOSTNAME}
# Platform: ${platform_info}
# Architecture: ${DETECTED_ARCH}
#
# Usage: sudo ./kexec.sh [--dry-run] [--debug] [--info]

set -eu

WORK_DIR="${REMOTE_WORK_DIR}"
LOG_FILE="\${WORK_DIR}/kexec.log"
DEBUG=false
DRY_RUN=false
INFO_ONLY=false

# Parse arguments
for arg in "\$@"; do
    case "\$arg" in
        --dry-run) DRY_RUN=true ;;
        --debug)   DEBUG=true ;;
        --info)    INFO_ONLY=true ;;
        --help|-h)
            echo "Usage: sudo ./kexec.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run   Show what would be done without executing"
            echo "  --debug     Enable verbose debug output"
            echo "  --info      Show file info and exit (no root required)"
            echo "  --help      Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: \$arg"
            exit 1
            ;;
    esac
done

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG_FILE"
}

log_error() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: \$*" | tee -a "\$LOG_FILE" >&2
}

debug() {
    if [ "\$DEBUG" = "true" ]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: \$*" | tee -a "\$LOG_FILE"
    fi
}

# Run command and capture output to log
run_cmd() {
    local cmd="\$*"
    debug "Running: \$cmd"

    local output
    local exit_code=0
    output=\$("\$@" 2>&1) || exit_code=\$?

    if [ -n "\$output" ]; then
        echo "\$output" | tee -a "\$LOG_FILE"
    fi

    if [ "\$exit_code" -ne 0 ]; then
        log_error "Command failed with exit code \$exit_code: \$cmd"
        return \$exit_code
    fi

    return 0
}

cd "\$WORK_DIR"

log "=== Alpine Anywhere Kexec ==="
log "Working directory: \$WORK_DIR"
log "Platform: ${platform_info}"

# Show file information
show_file_info() {
    log "--- File Information ---"
    for f in vmlinuz initramfs modloop ${apkovl_name}; do
        if [ -f "\$f" ]; then
            local size=\$(ls -lh "\$f" | awk '{print \$5}')
            local ftype=\$(file -b "\$f" 2>/dev/null || echo "unknown")
            log "  \$f: \$size (\$ftype)"
        else
            log_error "  \$f: MISSING"
        fi
    done
    log "------------------------"
}

# Verify files exist
log "Verifying files..."
MISSING_FILES=false
for f in vmlinuz initramfs modloop ${apkovl_name}; do
    if [ ! -f "\$f" ]; then
        log_error "Missing file: \$f"
        MISSING_FILES=true
    fi
done

if [ "\$MISSING_FILES" = "true" ]; then
    log_error "Some required files are missing. Aborting."
    exit 1
fi

log "All files present"

# Always show file info in debug mode or if requested
if [ "\$DEBUG" = "true" ] || [ "\$INFO_ONLY" = "true" ]; then
    show_file_info
fi

if [ "\$INFO_ONLY" = "true" ]; then
    log "Info mode - exiting without kexec"
    exit 0
fi

# Validate kernel file type
log "Validating kernel..."
KERNEL_TYPE=\$(file -b vmlinuz 2>/dev/null || echo "unknown")
debug "Kernel type: \$KERNEL_TYPE"

# Check for valid kernel formats
VALID_KERNEL=false
case "\$KERNEL_TYPE" in
    *"Linux kernel"*)
        VALID_KERNEL=true
        log "Kernel format: Linux kernel image"
        ;;
    *"PE32+ executable"*"EFI"*)
        VALID_KERNEL=true
        log "Kernel format: EFI stub kernel"
        # EFI kernels may need special handling on some systems
        if [ -f /sys/firmware/efi ]; then
            debug "System booted in EFI mode"
        fi
        ;;
    *"gzip compressed"*)
        log "Kernel format: Compressed kernel"
        VALID_KERNEL=true
        ;;
    *)
        log_error "Unrecognized kernel format: \$KERNEL_TYPE"
        log_error "Expected Linux kernel or EFI executable"
        ;;
esac

if [ "\$VALID_KERNEL" != "true" ]; then
    log_error "Kernel validation failed. Check if correct platform (${platform_info})."
    exit 1
fi

CMDLINE="${cmdline}"

log "Kernel command line:"
log "  \$CMDLINE"

if [ "\$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] Would execute:"
    log "[DRY-RUN]   kexec -l \$WORK_DIR/vmlinuz --initrd=\$WORK_DIR/initramfs --command-line=\"\$CMDLINE\""
    log "[DRY-RUN]   kexec -e"
    exit 0
fi

if [ "\$(id -u)" -ne 0 ]; then
    log_error "Must run as root (use sudo)"
    exit 1
fi

# Check if kexec is available
KEXEC_BIN=""
for kexec_path in /sbin/kexec /usr/sbin/kexec; do
    if [ -x "\$kexec_path" ]; then
        KEXEC_BIN="\$kexec_path"
        break
    fi
done

if [ -z "\$KEXEC_BIN" ]; then
    if command -v kexec >/dev/null 2>&1; then
        KEXEC_BIN=\$(command -v kexec)
    else
        log_error "kexec not found. Install kexec-tools."
        exit 1
    fi
fi

log "Using kexec: \$KEXEC_BIN"
debug "kexec version: \$(\$KEXEC_BIN --version 2>&1 || echo 'unknown')"

# Check if kexec is enabled in kernel
if [ -f /proc/sys/kernel/kexec_load_disabled ]; then
    KEXEC_DISABLED=\$(cat /proc/sys/kernel/kexec_load_disabled)
    if [ "\$KEXEC_DISABLED" = "1" ]; then
        log_error "kexec is disabled in kernel (kexec_load_disabled=1)"
        log_error "This may be due to Secure Boot. Try disabling Secure Boot in BIOS."
        exit 1
    fi
fi

# Check if kernel has kexec support compiled in
KEXEC_SUPPORTED=true
if [ -f /proc/config.gz ]; then
    if ! zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_KEXEC=y"; then
        KEXEC_SUPPORTED=false
    fi
elif [ -f /boot/config-\$(uname -r) ]; then
    if ! grep -q "CONFIG_KEXEC=y" /boot/config-\$(uname -r) 2>/dev/null; then
        KEXEC_SUPPORTED=false
    fi
fi

if [ "\$KEXEC_SUPPORTED" = "false" ]; then
    log_error "Kernel does not have kexec support (CONFIG_KEXEC not enabled)"
    log_error ""
    log_error "To fix this on Raspberry Pi:"
    log_error "  1. Edit /boot/config.txt (or /boot/firmware/config.txt)"
    log_error "  2. Add: kernel=vmlinuz-\$(uname -r)"
    log_error "  3. Or use a kernel with kexec support compiled in"
    log_error ""
    log_error "Alternatively, check if a kexec-enabled kernel is available:"
    log_error "  apt search linux-image | grep kexec"
    exit 1
fi
debug "Kernel kexec support: verified"

# Load kernel
log "Loading kernel..."
if ! run_cmd "\$KEXEC_BIN" -l "\$WORK_DIR/vmlinuz" --initrd="\$WORK_DIR/initramfs" --command-line="\$CMDLINE"; then
    log_error "Failed to load kernel with kexec"
    log_error "Common causes:"
    log_error "  - Wrong kernel for platform (expected: ${platform_info})"
    log_error "  - Secure Boot enabled"
    log_error "  - Kernel format not supported by this kexec version"
    log_error "  - Insufficient memory"
    exit 1
fi

log "Kernel loaded successfully"
log "Executing kexec in 5 seconds..."
log "WARNING: System will reboot NOW"
sleep 5

log "=== Executing kexec -e ==="
sync  # Flush filesystem buffers
exec "\$KEXEC_BIN" -e
KEXECSCRIPT
    chmod +x "$kexec_script"
    scp_to_remote "$kexec_script" "${REMOTE_WORK_DIR}/kexec.sh"
}

# Build kernel cmdline for remote execution (absolute paths)
build_kernel_cmdline_for_remote() {
    local cmdline=""

    # Console settings - different for Raspberry Pi
    if [ "$DETECTED_PLATFORM" = "rpi" ]; then
        # Raspberry Pi uses ttyAMA0 or ttyS0 depending on model
        # Pi 4/5 use ttyAMA0 for primary UART, Pi 3 uses ttyS0
        if [ "$DETECTED_RPI_VERSION" = "4" ] || [ "$DETECTED_RPI_VERSION" = "5" ]; then
            cmdline="console=tty1 console=ttyAMA0,115200 "
        else
            cmdline="console=tty1 console=ttyS0,115200 "
        fi
        # Raspberry Pi specific modules
        cmdline="${cmdline}modules=loop,squashfs,mmc_block,sdhci,sdhci-iproc "
    else
        cmdline="console=tty0 console=ttyS0,115200n8 "
        cmdline="${cmdline}modules=loop,squashfs,sd-mod,usb-storage "
    fi

    # Alpine repository
    cmdline="${cmdline}alpine_repo=${ALPINE_MIRROR}/v${ALPINE_VERSION}/main "

    # Modloop path (absolute)
    cmdline="${cmdline}modloop=${REMOTE_WORK_DIR}/modloop "

    # Network configuration
    local ip_param
    ip_param=$(generate_kernel_ip_param)
    cmdline="${cmdline}$ip_param "

    # apkovl location (absolute)
    cmdline="${cmdline}apkovl=${REMOTE_WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz "

    echo "$cmdline"
}

# Execute kexec on remote
run_remote_kexec() {
    log_step "Executing kexec on remote host..."

    if [ "$DRY_RUN" = "true" ]; then
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
