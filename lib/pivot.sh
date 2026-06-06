#!/bin/sh
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
# Privileged Execution Helper
# =============================================================================

# Run command with sudo if not root
run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

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
            if [ -f /etc/inittab ]; then
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
    run_privileged mkdir -p "${PIVOT_DIR}"
    run_privileged mount -t tmpfs -o size=512M,mode=755 tmpfs "${PIVOT_DIR}"

    # Extract Alpine minirootfs
    log_info "Extracting Alpine minirootfs..."
    run_privileged tar -xzf "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" -C "${PIVOT_DIR}"

    # Create old_root mount point
    run_privileged mkdir -p "${PIVOT_DIR}${OLD_ROOT}"

    # Mount virtual filesystems
    run_privileged mount -t proc proc "${PIVOT_DIR}/proc"
    run_privileged mount -t sysfs sysfs "${PIVOT_DIR}/sys"
    run_privileged mount -t devtmpfs devtmpfs "${PIVOT_DIR}/dev"
    run_privileged mkdir -p "${PIVOT_DIR}/dev/pts"
    run_privileged mount -t devpts devpts "${PIVOT_DIR}/dev/pts"

    # Copy resolv.conf
    run_privileged cp /etc/resolv.conf "${PIVOT_DIR}/etc/resolv.conf"

    # Setup APK repos
    run_privileged tee "${PIVOT_DIR}/etc/apk/repositories" > /dev/null << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF

    # Install essential packages
    log_info "Installing packages in pivot environment..."
    run_privileged chroot "${PIVOT_DIR}" /sbin/apk update

    # SSH package based on mode
    local ssh_pkg="openssh-server"
    if [ "$HARDENED_MODE" = "true" ]; then
        ssh_pkg="dropbear dropbear-openrc"
    fi

    # Base packages for pivot
    local pivot_pkgs="$ssh_pkg openrc busybox-openrc"

    # Add disk tools only for install mode
    if [ "$INSTALL_MODE" = "true" ]; then
        pivot_pkgs="$pivot_pkgs bash e2fsprogs dosfstools parted squashfs-tools rsync"
    fi

    run_privileged chroot "${PIVOT_DIR}" /sbin/apk add --no-cache $pivot_pkgs

    # Setup SSH
    setup_pivot_ssh

    # Generate fakeinit and save config
    generate_pivot_init

    log_info "Pivot environment ready at ${PIVOT_DIR}"
}

# Setup SSH in pivot environment
setup_pivot_ssh() {
    log_info "Configuring SSH for pivot environment..."

    run_privileged mkdir -p "${PIVOT_DIR}/root/.ssh"
    run_privileged chmod 700 "${PIVOT_DIR}/root/.ssh"

    # Copy authorized keys
    if [ -f "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" ]; then
        run_privileged tar -xzf "${INSTALL_CACHE_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz" \
            -C "${PIVOT_DIR}" ./root/.ssh/authorized_keys 2>/dev/null || true
    fi

    # Fallback to current user's keys
    if [ ! -s "${PIVOT_DIR}/root/.ssh/authorized_keys" ]; then
        cat ~/.ssh/authorized_keys 2>/dev/null | run_privileged tee -a "${PIVOT_DIR}/root/.ssh/authorized_keys" > /dev/null || true
        run_privileged sh -c "cat /root/.ssh/authorized_keys >> '${PIVOT_DIR}/root/.ssh/authorized_keys' 2>/dev/null" || true
    fi

    run_privileged chown -R 0:0 "${PIVOT_DIR}/root/.ssh"
    run_privileged chmod 600 "${PIVOT_DIR}/root/.ssh/authorized_keys" 2>/dev/null || true

    # Configure SSH based on mode
    if [ "$HARDENED_MODE" = "true" ]; then
        # Dropbear: generate host keys
        run_privileged mkdir -p "${PIVOT_DIR}/etc/dropbear"
        run_privileged chroot "${PIVOT_DIR}" /usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true
        log_info "Using dropbear (key-only auth)"
    else
        # OpenSSH: generate host keys
        run_privileged chroot "${PIVOT_DIR}" /usr/bin/ssh-keygen -A

        # Configure sshd
        run_privileged tee "${PIVOT_DIR}/etc/ssh/sshd_config" > /dev/null << 'EOF'
Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
Subsystem sftp /usr/lib/ssh/sftp-server
EOF
    fi
}

# =============================================================================
# Pivot Script Generation
# =============================================================================

# Generate fakeinit and save config for after pivot (marcan approach)
generate_pivot_init() {
    # Create directory for our files
    run_privileged mkdir -p "${PIVOT_DIR}/etc/alpine-anywhere"

    # Save full config for after pivot
    run_privileged tee "${PIVOT_DIR}/etc/alpine-anywhere/config.env" > /dev/null << EOF
# Network config
NETWORK_INTERFACE="${DETECTED_INTERFACE}"
NETWORK_IP="${DETECTED_IP_ADDRESS}"
NETWORK_NETMASK="${DETECTED_NETMASK}"
NETWORK_GATEWAY="${DETECTED_GATEWAY}"
NETWORK_DHCP="${NETWORK_IS_DHCP}"

# Installation config
HARDENED_MODE="${HARDENED_MODE}"
ALPINE_VERSION="${ALPINE_VERSION}"
ALPINE_MIRROR="${ALPINE_MIRROR}"
KERNEL_FLAVOR="${KERNEL_FLAVOR}"
OVERLAY_DEVICE="${OVERLAY_DEVICE}"
EXTRA_PACKAGES="${EXTRA_PACKAGES}"
FORCE="${FORCE}"
VERBOSE="${VERBOSE}"
INSTALL_CACHE_DIR="/root/.alpine-anywhere/cache"
EOF

    # Copy install scripts and cache only for install mode (objective 2/3)
    if [ "$INSTALL_MODE" = "true" ]; then
        run_privileged mkdir -p "${PIVOT_DIR}/root/.alpine-anywhere/cache"
        run_privileged cp "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" "${PIVOT_DIR}/root/.alpine-anywhere/cache/" 2>/dev/null || true
        run_privileged cp "${INSTALL_CACHE_DIR}/"*.apkovl.tar.gz "${PIVOT_DIR}/root/.alpine-anywhere/cache/" 2>/dev/null || true

        run_privileged mkdir -p "${PIVOT_DIR}/root/.alpine-anywhere/lib"
        run_privileged cp "${SCRIPT_DIR}/alpine-anywhere" "${PIVOT_DIR}/root/.alpine-anywhere/" 2>/dev/null || \
            run_privileged cp "${INSTALL_BASE_DIR}/alpine-anywhere" "${PIVOT_DIR}/root/.alpine-anywhere/" 2>/dev/null || true
        run_privileged cp "${SCRIPT_DIR}"/lib/*.sh "${PIVOT_DIR}/root/.alpine-anywhere/lib/" 2>/dev/null || \
            run_privileged cp "${INSTALL_BASE_DIR}"/lib/*.sh "${PIVOT_DIR}/root/.alpine-anywhere/lib/" 2>/dev/null || true
        run_privileged chmod +x "${PIVOT_DIR}/root/.alpine-anywhere/alpine-anywhere" 2>/dev/null || true
    fi

    # === FAKEINIT (marcan approach) ===
    # This script replaces the real init/systemd binary via bind mount.
    # When systemd re-execs (telinit u), it loads THIS instead of the real binary.
    # It runs as PID 1, so it can do pivot_root and unmount the old root.
    #
    # NOTE: This shebang MUST remain #!/bin/bash (not #!/bin/sh) because fakeinit
    # runs on the OLD system before pivot_root occurs. At that point, bash is
    # available from the old root filesystem, and the fakeinit needs bash features
    # (or at minimum, the known bash binary path) to function correctly as PID 1
    # during the transition. After pivot_root completes, the old root is unmounted.
    run_privileged tee "${PIVOT_DIR}/sbin/fakeinit" > /dev/null << 'FAKEINIT'
#!/bin/bash
# fakeinit - Runs as PID 1 after systemd re-execs
# Based on marcan/takeover.sh technique
#
# This script intentionally uses #!/bin/bash because it executes on the OLD
# system (before pivot_root) where bash is the known-available shell from the
# original root filesystem. It must use bash to function as PID 1 during the
# transition period.

PIVOT_DIR="/mnt/alpine"
OLD_ROOT="/mnt/oldroot"

# Redirect to console
exec > /dev/console 2>&1

echo "[fakeinit] === PID 1 Takeover ==="
echo "[fakeinit] PID: $$"

# Close all file descriptors > 2 to release old root references
for fd in $(ls /proc/self/fd 2>/dev/null); do
    [ "$fd" -gt 2 ] && eval "exec ${fd}>&-" 2>/dev/null || true
done

# Remount all as private to prevent mount propagation issues
mount --make-rprivate / 2>/dev/null || true

# Move the tmpfs mount to be directly accessible
# (It was mounted under the old root)
echo "[fakeinit] Preparing pivot_root..."
cd "${PIVOT_DIR}"
mkdir -p ".${OLD_ROOT}"

# The actual pivot_root - changes / for entire system
echo "[fakeinit] Executing pivot_root..."
if ! pivot_root . ".${OLD_ROOT}"; then
    echo "[fakeinit] ERROR: pivot_root failed!"
    exec /bin/bash
fi

echo "[fakeinit] Pivot successful! Now in Alpine root."

# We are now PID 1 in the new root
# Old root is at /mnt/oldroot
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Remount proc to see correct process info
mount -t proc proc /proc 2>/dev/null || true

# Kill ALL processes except PID 1 (us)
echo "[fakeinit] Killing processes on old root..."
for sig in TERM KILL; do
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | sort -n); do
        [ "$pid" = "1" ] && continue
        [ "$pid" = "$$" ] && continue
        [ ! -d "/proc/$pid" ] && continue
        kill -${sig} "$pid" 2>/dev/null || true
    done
    [ "$sig" = "TERM" ] && sleep 3
done

sleep 2

# Now unmount everything on old root
echo "[fakeinit] Unmounting old root filesystems..."
for mnt in $(awk '{print $2}' /proc/mounts | grep "^${OLD_ROOT}" | sort -r); do
    echo "[fakeinit]   umount $mnt"
    umount -l "$mnt" 2>/dev/null || true
done

# Final unmount of old root itself
umount -l "${OLD_ROOT}" 2>/dev/null || true

if mountpoint -q "${OLD_ROOT}" 2>/dev/null; then
    echo "[fakeinit] WARNING: ${OLD_ROOT} still mounted"
else
    echo "[fakeinit] Old root unmounted successfully"
fi

# Mount essential filesystems
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null || true
mkdir -p /run

# Load config
echo "[fakeinit] Loading configuration..."
if [ -f /etc/alpine-anywhere/config.env ]; then
    . /etc/alpine-anywhere/config.env
    echo "[fakeinit] Config: iface=${NETWORK_INTERFACE} ip=${NETWORK_IP} hardened=${HARDENED_MODE}"
else
    echo "[fakeinit] WARNING: No config found!"
fi

# Setup networking
echo "[fakeinit] Starting networking..."
/sbin/ifconfig lo 127.0.0.1 up 2>/dev/null || true

if [ -n "$NETWORK_INTERFACE" ]; then
    if [ "$NETWORK_DHCP" = "true" ]; then
        echo "[fakeinit] DHCP on ${NETWORK_INTERFACE}..."
        /sbin/udhcpc -i "$NETWORK_INTERFACE" -b -q 2>/dev/null &
        sleep 3
    else
        echo "[fakeinit] Static IP ${NETWORK_IP} on ${NETWORK_INTERFACE}..."
        /sbin/ifconfig "$NETWORK_INTERFACE" "$NETWORK_IP" netmask "$NETWORK_NETMASK" up
        /sbin/route add default gw "$NETWORK_GATEWAY" 2>/dev/null || true
    fi
fi

# Start SSH
echo "[fakeinit] Starting SSH..."
if [ "$HARDENED_MODE" = "true" ]; then
    echo "[fakeinit] Using dropbear"
    /usr/sbin/dropbear -R -p 22 -E 2>/dev/null &
else
    echo "[fakeinit] Using OpenSSH"
    mkdir -p /run/sshd
    /usr/sbin/sshd
fi

echo "[fakeinit] ==================================="
echo "[fakeinit] Alpine Linux is running!"
echo "[fakeinit] SSH available on port 22"
echo "[fakeinit] ==================================="

# Start A/B installation if scripts are present
if [ -f /root/.alpine-anywhere/alpine-anywhere ]; then
    echo "[fakeinit] Starting A/B installation in background..."
    . /etc/alpine-anywhere/config.env

    INSTALL_CMD="/usr/bin/bash /root/.alpine-anywhere/alpine-anywhere --local --install-continue"
    [ "$VERBOSE" = "true" ] && INSTALL_CMD="$INSTALL_CMD -v"
    [ "$FORCE" = "true" ] && INSTALL_CMD="$INSTALL_CMD -f"
    [ -n "$ALPINE_VERSION" ] && INSTALL_CMD="$INSTALL_CMD -V $ALPINE_VERSION"
    [ -n "$ALPINE_MIRROR" ] && INSTALL_CMD="$INSTALL_CMD -m $ALPINE_MIRROR"
    [ "$HARDENED_MODE" = "true" ] && INSTALL_CMD="$INSTALL_CMD --hardened"
    [ -n "$OVERLAY_DEVICE" ] && INSTALL_CMD="$INSTALL_CMD --overlay=$OVERLAY_DEVICE"

    echo "[fakeinit] Command: $INSTALL_CMD"
    $INSTALL_CMD > /var/log/alpine-install.log 2>&1 &
    echo "[fakeinit] Monitor: tail -f /var/log/alpine-install.log"
fi

# PID 1 must never exit - reap zombies forever
echo "[fakeinit] Entering zombie reaper loop (PID 1)"
while true; do
    wait -n 2>/dev/null || sleep 1
done
FAKEINIT

    run_privileged chmod +x "${PIVOT_DIR}/sbin/fakeinit"
}

# =============================================================================
# Init Replacement Strategies
# =============================================================================

# Strategy for systemd (marcan approach: bind mount over real binary + telinit u)
pivot_systemd() {
    log_info "Using systemd strategy (marcan/takeover.sh)..."

    # Find the REAL systemd binary path (not /sbin/init symlink)
    local systemd_bin
    systemd_bin=$(run_privileged readlink -f /proc/1/exe)
    log_info "Real systemd binary: ${systemd_bin}"

    if [ -z "$systemd_bin" ] || [ ! -f "$systemd_bin" ]; then
        log_error "Cannot find systemd binary, falling back to direct approach"
        pivot_direct
        return
    fi

    # Bind mount our fakeinit over the real systemd binary
    log_info "Bind-mounting fakeinit over ${systemd_bin}..."
    run_privileged mount --bind "${PIVOT_DIR}/sbin/fakeinit" "${systemd_bin}"

    # Trigger systemd re-exec: it will exec() the binary at its own path,
    # but thanks to the bind mount, it will load our fakeinit instead
    log_warn "Triggering telinit u - PID 1 will become fakeinit..."
    log_warn "Connection WILL be lost. Reconnect via: ssh root@${DETECTED_IP_ADDRESS}"

    run_privileged telinit u
}

# Strategy for sysvinit
pivot_sysvinit() {
    log_info "Using sysvinit strategy..."

    # Bind mount our init
    run_privileged mount --bind "${PIVOT_DIR}/sbin/takeover-init" /sbin/init

    # Tell init to re-exec
    log_warn "Triggering init re-exec..."
    run_privileged telinit u
}

# Strategy for runit
pivot_runit() {
    log_info "Using runit strategy..."

    # Runit doesn't support re-exec easily
    # We need to use a different approach: exec directly

    # Stop all services
    run_privileged sv stop /var/service/* 2>/dev/null || true

    # Kill runsv processes
    run_privileged pkill -TERM runsv 2>/dev/null || true
    sleep 2

    # Now exec into our pivot script directly
    # This won't be PID 1 but should work for our purposes
    log_warn "Executing pivot directly (runit workaround)..."

    # We need to do this in a way that survives
    run_privileged nohup sh -c "cd ${PIVOT_DIR} && exec chroot ${PIVOT_DIR} /pivot.sh" &

    # Alternative: try to replace runit
    # run_privileged mount --bind "${PIVOT_DIR}/sbin/takeover-init" /sbin/runit-init
}

# Fallback: chroot approach (no real pivot, Alpine on port 2222)
pivot_direct() {
    log_warn "Using chroot fallback (no real pivot_root)..."
    log_warn "Old root will NOT be unmounted - A/B installation may fail"

    # Mount virtual filesystems
    run_privileged mount -t proc proc "${PIVOT_DIR}/proc" 2>/dev/null || true
    run_privileged mount -t sysfs sysfs "${PIVOT_DIR}/sys" 2>/dev/null || true
    run_privileged mount --bind /dev "${PIVOT_DIR}/dev" 2>/dev/null || true

    # Start SSH on port 2222 in chroot
    if [ "$HARDENED_MODE" = "true" ]; then
        run_privileged chroot "${PIVOT_DIR}" /usr/sbin/dropbear -R -p 2222 2>/dev/null || true
    else
        run_privileged chroot "${PIVOT_DIR}" /bin/mkdir -p /run/sshd 2>/dev/null || true
        run_privileged chroot "${PIVOT_DIR}" /usr/sbin/sshd -p 2222 2>/dev/null || true
    fi

    log_info "Alpine chroot SSH on port 2222: ssh -p 2222 root@${DETECTED_IP_ADDRESS}"
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

    log_info "Alpine environment started successfully"
}

# =============================================================================
# Full Pivot Installation Flow
# =============================================================================

run_pivot_install() {
    log_step "Starting pivot installation..."

    # Ensure we have minirootfs
    if [ ! -f "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" ]; then
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
