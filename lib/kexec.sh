#!/bin/sh
# kexec.sh - kexec preparation and execution for alpine-anywhere

# =============================================================================
# Kernel Command Line
# =============================================================================

# Build kernel command line parameters
build_kernel_cmdline() {
    local cmdline=""

    # Console settings (both serial and VGA)
    cmdline="${cmdline}console=tty0 console=ttyS0,115200n8 "

    # Alpine repository
    cmdline="${cmdline}alpine_repo=${ALPINE_MIRROR}/v${ALPINE_VERSION}/main "

    # Modloop path (will be at this path after transfer)
    cmdline="${cmdline}modloop=${REMOTE_WORK_DIR}/modloop "

    # Required modules
    cmdline="${cmdline}modules=loop,squashfs,sd-mod,usb-storage "

    # Network configuration
    local ip_param
    ip_param=$(generate_kernel_ip_param)
    cmdline="${cmdline}$ip_param "

    # apkovl location
    cmdline="${cmdline}apkovl=${REMOTE_WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz "

    # SSH authorized keys path (optional, as backup)
    cmdline="${cmdline}ssh_key=${REMOTE_WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz "

    # Quiet boot (remove for debug)
    if [ "$VERBOSE" != "true" ]; then
        cmdline="${cmdline}quiet "
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

    # Create a private, unpredictable remote work dir. /tmp is world-writable,
    # so a fixed PID-based name lets a local attacker pre-create or race the
    # path; mktemp -d gives an O_EXCL 0700 directory.
    if [ "$DRY_RUN" = "true" ]; then
        REMOTE_WORK_DIR="/tmp/alpine-anywhere-dryrun"
    else
        REMOTE_WORK_DIR=$(ssh_exec_capture 'mktemp -d /tmp/alpine-anywhere.XXXXXX') \
            || die "could not create remote work dir"
        [ -n "$REMOTE_WORK_DIR" ] || die "remote mktemp returned empty path"
    fi
    log_debug "Remote work dir: $REMOTE_WORK_DIR"

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
    ssh_exec "ls -la ${REMOTE_WORK_DIR}/"

    log_info "All files transferred successfully"
}

# =============================================================================
# kexec Installation
# =============================================================================

# Ensure kexec-tools is installed on remote
ensure_kexec_installed() {
    log_step "Ensuring kexec-tools is installed..."

    # Check if kexec exists (may be in /sbin which is not in user PATH)
    if ssh_exec_capture "test -x /sbin/kexec || test -x /usr/sbin/kexec || command -v kexec" >/dev/null 2>&1; then
        log_info "kexec is already installed"
        return 0
    fi

    # In dry-run mode, just show what would be installed
    if [ "$DRY_RUN" = "true" ]; then
        local distro
        distro=$(ssh_exec_capture "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"'" || true)
        log_info "[DRY-RUN] Would install kexec-tools on $distro"
        return 0
    fi

    # Try to install based on distribution
    local distro
    distro=$(ssh_exec_capture "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"'" || true)

    case "$distro" in
        debian|ubuntu|armbian)
            log_info "Installing kexec-tools via apt..."
            ssh_exec_sudo "apt-get update -qq"
            ssh_exec_sudo "sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y kexec-tools'"
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

    # Verify installation (kexec is usually in /sbin which may not be in user PATH)
    if ! ssh_exec_capture "test -x /sbin/kexec || test -x /usr/sbin/kexec || command -v kexec" >/dev/null 2>&1; then
        die "Failed to install kexec-tools"
    fi

    log_info "kexec-tools installed successfully"
}

# =============================================================================
# kexec Execution
# =============================================================================

# Load the kernel, VERIFY it loaded, then schedule the reboot.
#
# Two structural fixes over the old single-line version:
#  1. Injection-safe: the command line and paths are passed to the remote shell
#     as positional parameters ("$1".."$4"), never interpolated into the script
#     body, so metacharacters in the cmdline cannot break out.
#  2. Honest failure: `kexec -l` runs synchronously and we read
#     /sys/kernel/kexec_loaded - if the load failed we abort here with the
#     system still on its original OS, instead of masking it behind a
#     backgrounded `&& (... &)` that always returns success.
load_and_execute_kexec() {
    log_step "Loading kernel and verifying kexec load..."

    local cmdline
    cmdline=$(build_kernel_cmdline)

    log_debug "Kernel command line: $cmdline"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] kexec -l ${REMOTE_WORK_DIR}/vmlinuz --initrd=${REMOTE_WORK_DIR}/initramfs --command-line=\"$cmdline\""
        echo "[DRY-RUN] verify /sys/kernel/kexec_loaded == 1"
        echo "[DRY-RUN] sleep ${REBOOT_DELAY} && kexec -e"
        log_info "[DRY-RUN] Skipping actual kexec execution"
        return 0
    fi

    # Phase 1: load synchronously and verify. Args: $1=vmlinuz $2=initramfs
    # $3=cmdline. The script body is a fixed literal.
    local load_script
    load_script='set -e
/sbin/kexec -l "$1" --initrd="$2" --command-line="$3"
sleep 1
loaded=$(cat /sys/kernel/kexec_loaded 2>/dev/null || echo 0)
if [ "$loaded" != "1" ]; then
    echo "kexec load did not stick (kexec_loaded=$loaded)" >&2
    exit 1
fi
echo "kexec-loaded-ok"'

    if ! ssh_exec_script_sudo "$load_script" \
            "${REMOTE_WORK_DIR}/vmlinuz" \
            "${REMOTE_WORK_DIR}/initramfs" \
            "$cmdline" | grep -q "kexec-loaded-ok"; then
        die "kexec load failed on remote - system is UNCHANGED and still reachable. Check kexec support and file integrity."
    fi
    log_info "Kernel loaded and verified (kexec_loaded=1)"

    log_warn "System will reboot in ${REBOOT_DELAY} seconds..."
    log_warn "The SSH connection will be lost."
    echo ""

    # Phase 2: schedule the detached reboot. Now that the load is confirmed,
    # a backgrounded kexec -e is fine - we verify the new system from the
    # control host afterwards (run_kexec -> wait_for_host/verify_alpine_boot).
    local exec_script
    exec_script='nohup sh -c "sleep $1; /sbin/kexec -e" >/dev/null 2>&1 &
echo started'
    ssh_exec_script_sudo "$exec_script" "$REBOOT_DELAY" >/dev/null 2>&1 || true

    log_info "kexec scheduled, waiting for system to reboot..."
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

    # Load kernel and execute kexec (single sudo prompt)
    load_and_execute_kexec

    if [ "$DRY_RUN" != "true" ]; then
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
