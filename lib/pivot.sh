#!/bin/bash
# pivot.sh - Real pivot_root implementation for alpine-anywhere
# Based on techniques from https://github.com/marcan/takeover.sh
#
# This allows unmounting the old root filesystem to format/partition disks.
# Works by replacing PID 1 (init) with a new init running from tmpfs.

# =============================================================================
# Constants
# =============================================================================

PIVOT_DIR="/mnt/alpine"
OLD_ROOT="/mnt/oldroot"

# =============================================================================
# Init System Detection
# =============================================================================

detect_init_system() {
    local init_comm
    init_comm=$(cat /proc/1/comm 2>/dev/null)

    case "$init_comm" in
        systemd)
            echo "systemd"
            ;;
        init)
            # Could be sysvinit or busybox init
            if [[ -f /etc/inittab ]]; then
                echo "sysvinit"
            else
                echo "unknown"
            fi
            ;;
        runit)
            echo "runit"
            ;;
        runsvdir)
            echo "runit"
            ;;
        openrc-init)
            echo "openrc"
            ;;
        *)
            echo "unknown:$init_comm"
            ;;
    esac
}

# =============================================================================
# Pivot Preparation
# =============================================================================

# Create the Alpine environment in tmpfs with pivot support
setup_pivot_environment() {
    log_step "Setting up pivot environment..."

    # Create tmpfs mount point
    mkdir -p "${PIVOT_DIR}"
    mount -t tmpfs -o size=512M,mode=755 tmpfs "${PIVOT_DIR}"

    # Extract Alpine minirootfs
    log_info "Extracting Alpine minirootfs..."
    tar -xzf "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" -C "${PIVOT_DIR}"

    # Create old_root mount point
    mkdir -p "${PIVOT_DIR}${OLD_ROOT}"

    # Mount virtual filesystems
    mount -t proc proc "${PIVOT_DIR}/proc"
    mount -t sysfs sysfs "${PIVOT_DIR}/sys"
    mount -t devtmpfs devtmpfs "${PIVOT_DIR}/dev"
    mkdir -p "${PIVOT_DIR}/dev/pts"
    mount -t devpts devpts "${PIVOT_DIR}/dev/pts"

    # Copy resolv.conf
    cp /etc/resolv.conf "${PIVOT_DIR}/etc/resolv.conf"

    # Setup APK repos
    cat > "${PIVOT_DIR}/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF

    # Install essential packages
    log_info "Installing packages in pivot environment..."
    chroot "${PIVOT_DIR}" /sbin/apk update
    chroot "${PIVOT_DIR}" /sbin/apk add --no-cache \
        openssh-server \
        openrc \
        busybox-openrc \
        e2fsprogs \
        dosfstools \
        parted \
        squashfs-tools \
        rsync

    # Setup SSH
    setup_pivot_ssh

    # Generate the pivot script
    generate_pivot_script

    # Generate the new init wrapper
    generate_pivot_init

    log_info "Pivot environment ready at ${PIVOT_DIR}"
}

# Setup SSH in pivot environment
setup_pivot_ssh() {
    log_info "Configuring SSH for pivot environment..."

    mkdir -p "${PIVOT_DIR}/root/.ssh"
    chmod 700 "${PIVOT_DIR}/root/.ssh"

    # Copy authorized keys
    if [[ -f "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" ]]; then
        tar -xzf "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" \
            -C "${PIVOT_DIR}" ./root/.ssh/authorized_keys 2>/dev/null || true
    fi

    # Fallback to current user's keys
    if [[ ! -s "${PIVOT_DIR}/root/.ssh/authorized_keys" ]]; then
        cat ~/.ssh/authorized_keys >> "${PIVOT_DIR}/root/.ssh/authorized_keys" 2>/dev/null || true
        cat /root/.ssh/authorized_keys >> "${PIVOT_DIR}/root/.ssh/authorized_keys" 2>/dev/null || true
    fi

    chown -R 0:0 "${PIVOT_DIR}/root/.ssh"
    chmod 600 "${PIVOT_DIR}/root/.ssh/authorized_keys" 2>/dev/null || true

    # Generate host keys
    chroot "${PIVOT_DIR}" /usr/bin/ssh-keygen -A

    # Configure sshd
    cat > "${PIVOT_DIR}/etc/ssh/sshd_config" << 'EOF'
Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
Subsystem sftp /usr/lib/ssh/sftp-server
EOF
}

# =============================================================================
# Pivot Script Generation
# =============================================================================

# Generate the script that performs the actual pivot
generate_pivot_script() {
    cat > "${PIVOT_DIR}/pivot.sh" << 'PIVOTSCRIPT'
#!/bin/sh
# Alpine Anywhere Pivot Script
# This runs after we've become PID 1 in the new root

set -e

PIVOT_DIR="/mnt/alpine"
OLD_ROOT="/mnt/oldroot"

log() {
    echo "[pivot] $*" | tee /dev/console 2>/dev/null || echo "[pivot] $*"
}

log "=== Starting pivot_root ==="

# We should already be running from PIVOT_DIR at this point
cd /

# Kill all processes still using old root
log "Terminating processes on old root..."
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$$" ] && continue

    root=$(readlink /proc/$pid/root 2>/dev/null) || continue
    if [ "$root" = "${OLD_ROOT}" ] || [ "$root" = "/" ]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
done

sleep 2

# Force kill remaining
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$$" ] && continue

    root=$(readlink /proc/$pid/root 2>/dev/null) || continue
    if [ "$root" = "${OLD_ROOT}" ] || [ "$root" = "/" ]; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
done

sleep 1

# Unmount old root filesystems
log "Unmounting old filesystems..."
for mnt in $(awk '{print $2}' /proc/mounts | grep "^${OLD_ROOT}" | sort -r); do
    umount -l "$mnt" 2>/dev/null || true
done

# Try to unmount old root itself
umount -l "${OLD_ROOT}" 2>/dev/null || log "Warning: could not unmount ${OLD_ROOT}"

# Check if old root is unmounted
if mountpoint -q "${OLD_ROOT}" 2>/dev/null; then
    log "Warning: ${OLD_ROOT} still mounted, some operations may fail"
else
    log "Old root unmounted successfully"
fi

# Start networking
log "Starting networking..."
/sbin/ifconfig lo 127.0.0.1 up 2>/dev/null || true

# Network config will be passed via environment or file
if [ -f /etc/alpine-anywhere/network.conf ]; then
    . /etc/alpine-anywhere/network.conf
    if [ "$NETWORK_DHCP" = "true" ]; then
        /sbin/udhcpc -i "$NETWORK_INTERFACE" -b 2>/dev/null || true
    else
        /sbin/ifconfig "$NETWORK_INTERFACE" "$NETWORK_IP" netmask "$NETWORK_NETMASK" up 2>/dev/null || true
        /sbin/route add default gw "$NETWORK_GATEWAY" 2>/dev/null || true
    fi
fi

# Start SSH
log "Starting SSH daemon..."
mkdir -p /run/sshd
/usr/sbin/sshd

log "=== Pivot complete ==="
log "SSH is now available"
log "Old root was at ${OLD_ROOT}"

# Start a shell or continue to real init
exec /sbin/init
PIVOTSCRIPT

    chmod +x "${PIVOT_DIR}/pivot.sh"
}

# Generate a fake init that will be executed by PID 1
generate_pivot_init() {
    # Create directory for our files
    mkdir -p "${PIVOT_DIR}/etc/alpine-anywhere"

    # Save network config for after pivot
    cat > "${PIVOT_DIR}/etc/alpine-anywhere/network.conf" << EOF
NETWORK_INTERFACE="${DETECTED_INTERFACE}"
NETWORK_IP="${DETECTED_IP_ADDRESS}"
NETWORK_NETMASK="${DETECTED_NETMASK}"
NETWORK_GATEWAY="${DETECTED_GATEWAY}"
NETWORK_DHCP="${NETWORK_IS_DHCP}"
EOF

    # Create the init replacement script
    # This will be copied over /sbin/init in the OLD root
    # When init re-execs, it will run this script which does pivot_root
    cat > "${PIVOT_DIR}/sbin/takeover-init" << TAKEOVERINIT
#!/bin/sh
# Takeover init - replaces original init to perform pivot_root

PIVOT_DIR="${PIVOT_DIR}"
OLD_ROOT="${OLD_ROOT}"

# Redirect output
exec > /dev/console 2>&1

echo "[takeover-init] Starting..."

# Do the pivot_root
cd "\${PIVOT_DIR}"
mkdir -p ".\${OLD_ROOT}"

echo "[takeover-init] Executing pivot_root..."
pivot_root . ".\${OLD_ROOT}"

# Update paths
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "[takeover-init] Pivot successful, now in Alpine"

# Execute the pivot script
exec /pivot.sh
TAKEOVERINIT

    chmod +x "${PIVOT_DIR}/sbin/takeover-init"
}

# =============================================================================
# Init Replacement Strategies
# =============================================================================

# Strategy for systemd
pivot_systemd() {
    log_info "Using systemd strategy..."

    # Bind mount our init over the real one
    mount --bind "${PIVOT_DIR}/sbin/takeover-init" /sbin/init

    # Tell systemd to re-exec
    log_warn "Triggering systemd re-exec..."
    systemctl daemon-reexec
}

# Strategy for sysvinit
pivot_sysvinit() {
    log_info "Using sysvinit strategy..."

    # Bind mount our init
    mount --bind "${PIVOT_DIR}/sbin/takeover-init" /sbin/init

    # Tell init to re-exec
    log_warn "Triggering init re-exec..."
    telinit u
}

# Strategy for runit
pivot_runit() {
    log_info "Using runit strategy..."

    # Runit doesn't support re-exec easily
    # We need to use a different approach: exec directly

    # Stop all services
    sv stop /var/service/* 2>/dev/null || true

    # Kill runsv processes
    pkill -TERM runsv 2>/dev/null || true
    sleep 2

    # Now exec into our pivot script directly
    # This won't be PID 1 but should work for our purposes
    log_warn "Executing pivot directly (runit workaround)..."

    # We need to do this in a way that survives
    nohup sh -c "cd ${PIVOT_DIR} && exec chroot ${PIVOT_DIR} /pivot.sh" &

    # Alternative: try to replace runit
    # mount --bind "${PIVOT_DIR}/sbin/takeover-init" /sbin/runit-init
}

# Strategy using direct exec (fallback)
pivot_direct() {
    log_info "Using direct pivot strategy..."

    # This is a simplified approach that may not fully unmount old root
    # but should work for most cases

    cd "${PIVOT_DIR}"
    mkdir -p ".${OLD_ROOT}"

    # Try pivot_root directly
    log_warn "Attempting direct pivot_root..."

    if pivot_root . ".${OLD_ROOT}"; then
        log_info "Pivot successful"
        exec chroot . /pivot.sh
    else
        log_error "Direct pivot_root failed"
        return 1
    fi
}

# =============================================================================
# Main Pivot Execution
# =============================================================================

execute_pivot() {
    log_step "Executing pivot_root..."

    local init_system
    init_system=$(detect_init_system)

    log_info "Detected init system: $init_system"

    case "$init_system" in
        systemd)
            pivot_systemd
            ;;
        sysvinit)
            pivot_sysvinit
            ;;
        runit)
            pivot_runit
            ;;
        openrc)
            pivot_sysvinit  # OpenRC uses similar mechanism
            ;;
        *)
            log_warn "Unknown init system, trying direct approach"
            pivot_direct
            ;;
    esac

    # If we get here with systemd/sysvinit, init should re-exec soon
    log_info "Pivot initiated, waiting for system to switch..."
    sleep 5
}

# =============================================================================
# Full Pivot Installation Flow
# =============================================================================

run_pivot_install() {
    log_step "Starting pivot installation..."

    # Ensure we have minirootfs
    if [[ ! -f "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" ]]; then
        download_minirootfs
    fi

    # Setup the environment
    setup_pivot_environment

    # Execute pivot
    execute_pivot

    log_info "Pivot installation complete"
    log_info "Connect via: ssh root@${DETECTED_IP_ADDRESS}"
}

# Download minirootfs if needed
download_minirootfs() {
    local url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz"

    log_info "Downloading Alpine minirootfs..."
    curl -fSL --progress-bar -o "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" "$url"
}
