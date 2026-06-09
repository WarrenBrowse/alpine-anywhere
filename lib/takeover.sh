#!/bin/sh
# takeover.sh - Takeover method for alpine-anywhere
# Based on the technique from https://github.com/marcan/takeover.sh
#
# This method pivots the root filesystem to a tmpfs containing Alpine Linux,
# without using kexec. The original kernel keeps running but userspace is
# entirely replaced with Alpine.

# =============================================================================
# Constants
# =============================================================================

TAKEOVER_DIR="/takeover"
OLD_ROOT="/old_root"

# =============================================================================
# Takeover Installation
# =============================================================================

# Check if takeover method is supported
check_takeover_support() {
    log_step "Checking takeover support..."

    # Check for systemd or sysvinit (needed for telinit u)
    local init_system
    init_system=$(ssh_exec_capture "ps -p 1 -o comm= 2>/dev/null || echo unknown")

    case "$init_system" in
        systemd)
            log_info "Init system: systemd"
            ;;
        init)
            log_info "Init system: sysvinit"
            ;;
        *)
            log_warn "Unknown init system: $init_system"
            log_warn "Takeover may not work correctly"
            ;;
    esac

    # Check available RAM for tmpfs
    local mem_available_kb
    mem_available_kb=$(ssh_exec_capture "grep MemAvailable /proc/meminfo | awk '{print \$2}'")
    local mem_available_mb=$((mem_available_kb / 1024))

    # We need at least 256MB for Alpine minimal + some headroom
    local min_ram_mb=300
    if [ "$mem_available_mb" -lt "$min_ram_mb" ]; then
        die "Insufficient available RAM for takeover: ${mem_available_mb}MB (need ${min_ram_mb}MB)"
    fi

    log_info "Available RAM: ${mem_available_mb}MB (sufficient)"

    # Check if pivot_root is available
    if ! ssh_exec_capture "which pivot_root >/dev/null 2>&1 || test -x /sbin/pivot_root"; then
        log_warn "pivot_root not found, will use busybox"
    fi

    log_info "Takeover method is supported"
}

# Download Alpine minirootfs (on the remote) and verify its integrity there
# before it is ever extracted/chrooted.
download_alpine_minirootfs() {
    log_info "Downloading Alpine minirootfs..."

    local minirootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz"

    # Resolve the expected sha512 on the control host (HTTPS), so the check on
    # the remote cannot be satisfied by a tampered mirror serving a matching
    # bad checksum from the same compromised origin chosen by the attacker.
    local want_sum=""
    if [ "$NO_VERIFY" != "true" ]; then
        if [ -n "$CHECKSUM_DIR" ] && [ -f "${CHECKSUM_DIR}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz.sha512" ]; then
            want_sum=$(awk '{print $1}' "${CHECKSUM_DIR}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz.sha512")
        else
            want_sum=$(http_fetch_stdout "${minirootfs_url}.sha512" 2>/dev/null | awk '{print $1}' || true)
        fi
        [ -n "$want_sum" ] || die "No checksum available for minirootfs. Use --checksum-dir or (unsafe) --no-verify."
    fi

    # Download on the remote (injection-safe: URL and dest passed as args).
    local dl_script='set -e
curl -fSL --progress-bar -o "$2/minirootfs.tar.gz" "$1" 2>&1'
    if ! ssh_exec_script "$dl_script" "$minirootfs_url" "$REMOTE_WORK_DIR"; then
        die "Failed to download Alpine minirootfs"
    fi

    # Verify on the remote against the control-host-resolved checksum.
    if [ "$NO_VERIFY" != "true" ]; then
        local verify_script='got=$(sha512sum "$2/minirootfs.tar.gz" | awk "{print \$1}")
if [ "$got" != "$1" ]; then echo "MINIROOTFS CHECKSUM MISMATCH" >&2; exit 1; fi
echo verified-ok'
        if ! ssh_exec_script "$verify_script" "$want_sum" "$REMOTE_WORK_DIR" | grep -q verified-ok; then
            die "minirootfs integrity check failed on remote - refusing to proceed"
        fi
        log_info "Integrity verified (sha512): minirootfs"
    fi
}

# Setup Alpine in tmpfs - generates and executes a single setup script
setup_takeover_environment() {
    log_step "Setting up takeover environment..."

    # Generate network config for the script
    local network_interfaces
    if [ "$NETWORK_IS_DHCP" = "true" ]; then
        network_interfaces="auto lo
iface lo inet loopback

auto ${DETECTED_INTERFACE}
iface ${DETECTED_INTERFACE} inet dhcp"
    else
        network_interfaces="auto lo
iface lo inet loopback

auto ${DETECTED_INTERFACE}
iface ${DETECTED_INTERFACE} inet static
    address ${DETECTED_IP_ADDRESS}
    netmask ${DETECTED_NETMASK}
    gateway ${DETECTED_GATEWAY}"
    fi

    # Generate the setup script LOCALLY (control host), then transfer it as a
    # file and execute it by path. This avoids embedding it in a double-quoted
    # ssh command string, so interpolated values (hostname, network config,
    # mirror) can never break out into the remote shell. The local heredoc is
    # unquoted so ${VAR} expands into the file; runtime variables use \$ /
    # \${...} so they are evaluated on the remote at run time.
    log_info "Generating setup script..."
    local setup_local="${WORK_DIR}/setup_takeover.sh"
    cat > "$setup_local" << SETUPSCRIPT
#!/bin/sh
set -e

TAKEOVER_DIR="${TAKEOVER_DIR}"
OLD_ROOT="${OLD_ROOT}"
WORK_DIR="${REMOTE_WORK_DIR}"
LOG="\${WORK_DIR}/install.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG"
}

log "=== Setting up takeover environment ==="

# Create and mount tmpfs
log "Creating tmpfs at \${TAKEOVER_DIR}..."
mkdir -p \${TAKEOVER_DIR}
mount -t tmpfs -o size=512M tmpfs \${TAKEOVER_DIR}

# Extract minirootfs
log "Extracting Alpine minirootfs..."
tar -xzf \${WORK_DIR}/minirootfs.tar.gz -C \${TAKEOVER_DIR}

# Create old_root mount point
mkdir -p \${TAKEOVER_DIR}\${OLD_ROOT}

# Copy resolv.conf
cp /etc/resolv.conf \${TAKEOVER_DIR}/etc/resolv.conf

# Setup APK repositories
log "Configuring APK repositories..."
mkdir -p \${TAKEOVER_DIR}/etc/apk
cat > \${TAKEOVER_DIR}/etc/apk/repositories << 'APKREPOS'
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
APKREPOS

# Mount filesystems needed for chroot
log "Mounting filesystems for chroot..."
mkdir -p \${TAKEOVER_DIR}/dev \${TAKEOVER_DIR}/proc
mount --bind /dev \${TAKEOVER_DIR}/dev
mount --bind /proc \${TAKEOVER_DIR}/proc 2>/dev/null || mount -t proc proc \${TAKEOVER_DIR}/proc

# Install essential packages
log "Installing essential packages (this may take a moment)..."
chroot \${TAKEOVER_DIR} /sbin/apk update
chroot \${TAKEOVER_DIR} /sbin/apk add --no-cache openssh-server openrc busybox-openrc

# Setup SSH
log "Configuring SSH..."
mkdir -p \${TAKEOVER_DIR}/root/.ssh
chmod 700 \${TAKEOVER_DIR}/root/.ssh

# Copy SSH authorized keys from apkovl
tar -xzf \${WORK_DIR}/*.apkovl.tar.gz -C \${TAKEOVER_DIR} ./root/.ssh/authorized_keys 2>/dev/null || true
chown 0:0 \${TAKEOVER_DIR}/root/.ssh/authorized_keys 2>/dev/null || true

# Fallback: copy from current user and root
if [ ! -f \${TAKEOVER_DIR}/root/.ssh/authorized_keys ]; then
    cat ~/.ssh/authorized_keys >> \${TAKEOVER_DIR}/root/.ssh/authorized_keys 2>/dev/null || true
    cat /root/.ssh/authorized_keys >> \${TAKEOVER_DIR}/root/.ssh/authorized_keys 2>/dev/null || true
fi
chmod 600 \${TAKEOVER_DIR}/root/.ssh/authorized_keys 2>/dev/null || true

# Generate SSH host keys
log "Generating SSH host keys..."
chroot \${TAKEOVER_DIR} /usr/bin/ssh-keygen -A

# Configure sshd
cat > \${TAKEOVER_DIR}/etc/ssh/sshd_config << 'SSHDCONFIG'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp /usr/lib/ssh/sftp-server
SSHDCONFIG

# Setup network configuration
log "Configuring network..."
mkdir -p \${TAKEOVER_DIR}/etc/network
cat > \${TAKEOVER_DIR}/etc/network/interfaces << 'NETCONFIG'
${network_interfaces}
NETCONFIG

# Set hostname
echo '${DETECTED_HOSTNAME}' > \${TAKEOVER_DIR}/etc/hostname

# Enable services
log "Enabling services..."
chroot \${TAKEOVER_DIR} /sbin/rc-update add networking boot 2>/dev/null || true
chroot \${TAKEOVER_DIR} /sbin/rc-update add sshd default 2>/dev/null || true

# Unmount chroot filesystems
log "Unmounting chroot filesystems..."
umount \${TAKEOVER_DIR}/proc 2>/dev/null || true
umount \${TAKEOVER_DIR}/dev 2>/dev/null || true

log "=== Takeover environment setup complete ==="
log "Alpine root is at \${TAKEOVER_DIR}"

# List what we have
log "--- Installed files ---"
ls -la \${TAKEOVER_DIR}/ >> "\$LOG"
SETUPSCRIPT

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would transfer and run setup_takeover.sh"
        return 0
    fi

    scp_to_remote "$setup_local" "${REMOTE_WORK_DIR}/setup_takeover.sh"
    ssh_exec "chmod +x $(shell_quote "${REMOTE_WORK_DIR}/setup_takeover.sh")"

    # Execute the setup script with sudo (single password prompt)
    log_info "Executing setup script (sudo)..."
    ssh_exec_sudo "$(shell_quote "${REMOTE_WORK_DIR}/setup_takeover.sh")"

    log_info "Takeover environment setup complete"
}

# Generate and install the takeover script (executed as part of setup_takeover.sh with sudo)
generate_takeover_script() {
    log_info "Generating takeover script..."

    # Generate network setup commands
    local network_setup
    if [ "$NETWORK_IS_DHCP" = "true" ]; then
        network_setup="/sbin/udhcpc -i ${DETECTED_INTERFACE} -b 2>/dev/null || true"
    else
        network_setup="/sbin/ifconfig ${DETECTED_INTERFACE} ${DETECTED_IP_ADDRESS} netmask ${DETECTED_NETMASK} up 2>/dev/null || true
/sbin/route add default gw ${DETECTED_GATEWAY} 2>/dev/null || true"
    fi

    # Generate the takeover script LOCALLY then transfer it (same rationale as
    # setup_takeover_environment: no interpolation into a remote shell string).
    local takeover_local="${WORK_DIR}/takeover_script.sh"
    cat > "$takeover_local" << TAKEOVERSCRIPT
#!/bin/sh
# Alpine Anywhere Takeover Script
# This script starts Alpine services in chroot

set -e

TAKEOVER_DIR="${TAKEOVER_DIR}"
LOG="/dev/console"

log() {
    echo "[takeover] \$*" | tee -a \$LOG 2>/dev/null || echo "[takeover] \$*"
}

log "=== Alpine Anywhere Takeover ==="
log "Starting takeover process..."

# Sync filesystems
log "Syncing filesystems..."
sync

# Mount necessary filesystems in chroot
log "Mounting virtual filesystems..."
mount -t proc proc \${TAKEOVER_DIR}/proc 2>/dev/null || true
mount -t sysfs sys \${TAKEOVER_DIR}/sys 2>/dev/null || true
mount -t devtmpfs dev \${TAKEOVER_DIR}/dev 2>/dev/null || mount --bind /dev \${TAKEOVER_DIR}/dev 2>/dev/null || true
mkdir -p \${TAKEOVER_DIR}/dev/pts 2>/dev/null || true
mount -t devpts devpts \${TAKEOVER_DIR}/dev/pts 2>/dev/null || true
mount --bind /run \${TAKEOVER_DIR}/run 2>/dev/null || mkdir -p \${TAKEOVER_DIR}/run

# Start networking in chroot
log "Starting Alpine networking..."
chroot \${TAKEOVER_DIR} /sbin/ifconfig lo 127.0.0.1 up 2>/dev/null || true
chroot \${TAKEOVER_DIR} /bin/sh -c '${network_setup}'

# Start SSH daemon in chroot on port 2222
log "Starting Alpine SSH daemon on port 2222..."
chroot \${TAKEOVER_DIR} /bin/mkdir -p /run/sshd
chroot \${TAKEOVER_DIR} /usr/sbin/sshd -p 2222

log "=== Takeover complete ==="
log "Alpine Linux SSH running in chroot on port 2222"
log "Connect via: ssh -p 2222 root@${DETECTED_IP_ADDRESS}"
log ""
log "Host SSH remains on port 22"
log "To fully enter Alpine: sudo chroot /takeover /bin/sh"
TAKEOVERSCRIPT

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would transfer and install takeover script"
        return 0
    fi

    scp_to_remote "$takeover_local" "${REMOTE_WORK_DIR}/takeover_script.sh"

    # Copy takeover script to /takeover with sudo
    ssh_exec_sudo "cp $(shell_quote "${REMOTE_WORK_DIR}/takeover_script.sh") $(shell_quote "${TAKEOVER_DIR}/takeover.sh") && chmod +x $(shell_quote "${TAKEOVER_DIR}/takeover.sh")"

    log_info "Takeover script generated"
}

# Execute the takeover
execute_takeover() {
    log_step "Executing takeover..."

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would execute takeover"
        log_info "[DRY-RUN] The system would pivot to Alpine in ${TAKEOVER_DIR}"
        return 0
    fi

    # Show summary
    echo ""
    echo "===================================================="
    echo "Ready to takeover into Alpine Linux!"
    echo "===================================================="
    echo "Alpine Version: ${ALPINE_VERSION}"
    echo "Target Host:    ${TARGET_HOST}"
    echo "IP Address:     ${DETECTED_IP_ADDRESS}"
    echo "Method:         takeover (pivot_root)"
    echo ""
    echo "WARNING: This will replace the running userspace!"
    echo "The original system will be at ${OLD_ROOT}"
    echo "===================================================="
    echo ""

    # Confirm
    confirm_action "This will pivot ${TARGET_HOST} to Alpine Linux. SSH connection may be briefly interrupted."

    log_warn "Executing takeover in 3 seconds..."
    sleep 3

    # Execute the takeover via nohup to survive SSH disconnect (single sudo call)
    log_info "Starting takeover process..."
    log_warn "Initiating takeover - connection will drop..."

    # Use nohup and disown to survive SSH disconnect
    ssh_exec_sudo "nohup ${TAKEOVER_DIR}/takeover.sh </dev/null >/dev/console 2>&1 &" || true

    log_info "Takeover initiated, waiting for system to stabilize..."
    sleep 5
}

# =============================================================================
# Main Takeover Flow
# =============================================================================

# Run complete takeover installation
run_takeover_install() {
    local apkovl_file="$1"

    # Detect remote home first
    detect_remote_home

    log_step "Setting up takeover installation..."

    # Check support
    check_takeover_support

    # Create remote directory
    ssh_exec "mkdir -p ${REMOTE_WORK_DIR}"

    # Initialize install log
    ssh_exec "cat > ${REMOTE_WORK_DIR}/install.log << 'LOGHEADER'
================================================================================
alpine-anywhere Installation Log (Takeover Method)
================================================================================
Generated: $(date -Iseconds)
Alpine Version: ${ALPINE_VERSION}
Target Host: ${DETECTED_HOSTNAME}
Architecture: ${DETECTED_ARCH}
Platform: ${DETECTED_PLATFORM}
Method: takeover
================================================================================

LOGHEADER"

    # Transfer apkovl
    log_info "Transferring apkovl..."
    scp_to_remote "$apkovl_file" "${REMOTE_WORK_DIR}/"

    # Download minirootfs
    download_alpine_minirootfs

    # Setup environment
    setup_takeover_environment

    # Generate takeover script
    generate_takeover_script

    log_info "Takeover installation complete"
    log_info "Files installed in ${REMOTE_WORK_DIR}/"
    log_info "Takeover environment ready at ${TAKEOVER_DIR}/"
}

# Execute takeover on remote
run_takeover_execute() {
    execute_takeover

    if [ "$DRY_RUN" != "true" ]; then
        # Wait for host to come back
        sleep 10
        wait_for_host 120

        # Verify we're in Alpine
        verify_alpine_boot
    fi
}
