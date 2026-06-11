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

    # The real PID 1 binary disambiguates busybox init from sysvinit (both have
    # comm="init"); they need completely different re-exec mechanisms.
    local init_exe
    init_exe=$(readlink -f /proc/1/exe 2>/dev/null)

    case "$init_comm" in
        systemd)
            echo "systemd"
            ;;
        init)
            case "$init_exe" in
                */busybox)
                    echo "busybox"
                    ;;
                *)
                    if [ -f /etc/inittab ]; then
                        echo "sysvinit"
                    else
                        echo "unknown"
                    fi
                    ;;
            esac
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

    # Create tmpfs mount point (2G: room for tools + kernel modules + an
    # installer initramfs image; the box has several GB of RAM)
    run_privileged mkdir -p "${PIVOT_DIR}"
    run_privileged mount -t tmpfs -o size=2G,mode=755 tmpfs "${PIVOT_DIR}"

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

    # Add disk tools only for install mode. iproute2/ethtool/wget are for the
    # post-pivot network bringup + on-console diagnostics (busybox ifconfig is
    # limited; `ip`/`ethtool` show link/driver state when the link won't come up).
    if [ "$INSTALL_MODE" = "true" ]; then
        # util-linux: full blkid (busybox's cannot read PARTUUID, which the
        # extlinux root=PARTUUID generation needs). swapoff/wipefs also from here.
        pivot_pkgs="$pivot_pkgs bash e2fsprogs dosfstools parted squashfs-tools rsync iproute2 ethtool wget util-linux"
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

    # Save full config for after pivot (DETECTED_* vars needed by install)
    run_privileged tee "${PIVOT_DIR}/etc/alpine-anywhere/config.env" > /dev/null << EOF
# Network (DETECTED_* format for install functions)
DETECTED_INTERFACE="${DETECTED_INTERFACE}"
DETECTED_IP_ADDRESS="${DETECTED_IP_ADDRESS}"
DETECTED_NETMASK="${DETECTED_NETMASK}"
DETECTED_GATEWAY="${DETECTED_GATEWAY}"
DETECTED_DNS="${DETECTED_DNS}"
DETECTED_HOSTNAME="${DETECTED_HOSTNAME}"
DETECTED_ARCH="${DETECTED_ARCH}"
DETECTED_PLATFORM="${DETECTED_PLATFORM}"
DETECTED_RPI_VERSION="${DETECTED_RPI_VERSION:-}"
NETWORK_IS_DHCP="${NETWORK_IS_DHCP}"

# Fakeinit network aliases
NETWORK_INTERFACE="${DETECTED_INTERFACE}"
NETWORK_IP="${DETECTED_IP_ADDRESS}"
NETWORK_NETMASK="${DETECTED_NETMASK}"
NETWORK_GATEWAY="${DETECTED_GATEWAY}"
NETWORK_DHCP="${NETWORK_IS_DHCP}"

# Installation config
HARDENED_MODE="${HARDENED_MODE}"
INSTALL_MODE="${INSTALL_MODE}"
ALPINE_VERSION="${ALPINE_VERSION}"
ALPINE_MIRROR="${ALPINE_MIRROR}"
KERNEL_FLAVOR="${KERNEL_FLAVOR}"
KERNEL_PKG="${KERNEL_PKG}"
OVERLAY_DEVICE="${OVERLAY_DEVICE}"
TARGET_DISK="${TARGET_DISK}"
INIT_SYSTEM="${INIT_SYSTEM}"
EXTRA_PACKAGES="${EXTRA_PACKAGES}"
VERITY_MODE="${VERITY_MODE}"
NO_VERIFY="${NO_VERIFY}"
PERSIST_DATA="${PERSIST_DATA}"
DATA_FS="${DATA_FS}"
ENCRYPT_DATA="${ENCRYPT_DATA}"
UNLOCK_METHOD="${UNLOCK_METHOD}"
KEY_URL="${KEY_URL}"
CONTAINERS="${CONTAINERS}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME}"
FORCE="${FORCE}"
VERBOSE="${VERBOSE}"
INSTALL_CACHE_DIR="/root/.local/share/alpine-anywhere/cache"
EOF

    # Always copy alpine-anywhere scripts to the pivoted system
    local aa_dest="${PIVOT_DIR}/root/.local/share/alpine-anywhere"
    run_privileged mkdir -p "${aa_dest}/lib"
    run_privileged cp "${SCRIPT_DIR}/alpine-anywhere" "${aa_dest}/" 2>/dev/null || \
        run_privileged cp "${INSTALL_BASE_DIR}/alpine-anywhere" "${aa_dest}/" 2>/dev/null || true
    run_privileged cp "${SCRIPT_DIR}"/lib/*.sh "${aa_dest}/lib/" 2>/dev/null || \
        run_privileged cp "${INSTALL_BASE_DIR}"/lib/*.sh "${aa_dest}/lib/" 2>/dev/null || true
    # initramfs payloads (init.aa boot-guard, aa-verity-open) for the in-RAM build
    run_privileged mkdir -p "${aa_dest}/lib/initramfs"
    run_privileged cp "${SCRIPT_DIR}"/lib/initramfs/* "${aa_dest}/lib/initramfs/" 2>/dev/null || \
        run_privileged cp "${INSTALL_BASE_DIR}"/lib/initramfs/* "${aa_dest}/lib/initramfs/" 2>/dev/null || true
    run_privileged chmod +x "${aa_dest}/alpine-anywhere" 2>/dev/null || true

    # Copy cache files for install mode (objective 2/3)
    if [ "$INSTALL_MODE" = "true" ]; then
        run_privileged mkdir -p "${aa_dest}/cache"
        run_privileged cp "${INSTALL_CACHE_DIR}/minirootfs.tar.gz" "${aa_dest}/cache/" 2>/dev/null || true
        run_privileged cp "${INSTALL_CACHE_DIR}/"*.apkovl.tar.gz "${aa_dest}/cache/" 2>/dev/null || true
    fi

    # Transfer image-customization inputs (control-host paths -> pivoted paths).
    # The build runs after pivot, so these files must travel into the pivot env.
    local pivot_aa="/root/.local/share/alpine-anywhere"
    local custom_dest="" hostkeys_dest="" customfiles_dest=""
    if [ -n "$CUSTOM_SCRIPT" ] && [ -f "$CUSTOM_SCRIPT" ]; then
        run_privileged cp "$CUSTOM_SCRIPT" "${aa_dest}/custom-script.sh"
        custom_dest="${pivot_aa}/custom-script.sh"
        log_info "Custom script staged for pivoted build"
    fi
    # --custom-files: the post-pivot build runs run_custom_script, which needs
    # these staged into the pivot env too (else a --custom-script that consumes
    # them fails AFTER the disk is repartitioned). Mirror run_custom_script:
    # a directory's contents (or a single file) land under custom-files/.
    if [ -n "$CUSTOM_FILES" ] && [ -e "$CUSTOM_FILES" ]; then
        run_privileged mkdir -p "${aa_dest}/custom-files"
        if [ -d "$CUSTOM_FILES" ]; then
            run_privileged cp -R "$CUSTOM_FILES"/. "${aa_dest}/custom-files/"
        else
            run_privileged cp "$CUSTOM_FILES" "${aa_dest}/custom-files/"
        fi
        customfiles_dest="${pivot_aa}/custom-files"
        log_info "Custom files staged for pivoted build"
    fi
    if [ -n "$SSH_HOST_KEY_DIR" ] && [ -d "$SSH_HOST_KEY_DIR" ]; then
        run_privileged mkdir -p "${aa_dest}/host-keys"
        run_privileged cp "$SSH_HOST_KEY_DIR"/* "${aa_dest}/host-keys/" 2>/dev/null || true
        hostkeys_dest="${pivot_aa}/host-keys"
        log_info "SSH host keys staged for pivoted build"
    fi
    run_privileged tee -a "${PIVOT_DIR}/etc/alpine-anywhere/config.env" > /dev/null << EOF
CUSTOM_SCRIPT="${custom_dest}"
CUSTOM_FILES="${customfiles_dest}"
SSH_HOST_KEY_DIR="${hostkeys_dest}"
EOF

    # === FAKEINIT (marcan approach) ===
    # This script replaces the real init/systemd binary via bind mount.
    # When systemd re-execs (telinit u), it loads THIS instead of the real binary.
    # It runs as PID 1, so it can do pivot_root and unmount the old root.
    #
    # NOTE: shebang is #!/bin/sh. The body is strict POSIX (no [[ ]], arrays, or
    # declare), and the shebang is resolved against the OLD root at exec time -
    # where /bin/sh always exists but /bin/bash may NOT (e.g. an Alpine origin
    # host). Using bash here would panic PID 1 (and brick an unattended box)
    # whenever the original system lacks bash. The generating code probes the
    # origin for a usable interpreter before committing to the takeover.
    run_privileged tee "${PIVOT_DIR}/sbin/fakeinit" > /dev/null << 'FAKEINIT'
#!/bin/sh
# fakeinit - Runs as PID 1 after systemd re-execs
# Based on marcan/takeover.sh technique
#
# Strict POSIX sh: this runs as PID 1 on the OLD system before pivot_root,
# where only /bin/sh is guaranteed to exist.

PIVOT_DIR="/mnt/alpine"
OLD_ROOT="/mnt/oldroot"

# Redirect to console
exec > /dev/console 2>&1

# Persistent breadcrumb log. It lives on the OLD root (the disk we booted from),
# which survives a failed takeover because the install never reaches the
# partition step before the network is confirmed. After rebooting back to the
# prior OS, read /aa-fakeinit.log to see EXACTLY how far the takeover got - even
# when console output is buffered or lost. Each write is fsync'd so the last
# breadcrumb is on disk even if PID 1 then hangs. Pre-pivot the OLD root is "/";
# post-pivot it is /mnt/oldroot (same physical fs) - bc() switches automatically.
BCLOG=/aa-fakeinit.log
: > "$BCLOG" 2>/dev/null
bc() {
    _t=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
    echo "[fakeinit+${_t}] $*"
    [ -n "$BCLOG" ] && { echo "[${_t}] $*" >> "$BCLOG" 2>/dev/null; sync 2>/dev/null; }
}

bc "=== PID 1 Takeover === PID:$$"

# Load the install config EARLY (network values etc.) so even the pivot_root
# failure path below can bring real networking up for recovery.
bc "loading config.env"
for _cfg in /etc/alpine-anywhere/config.env /mnt/alpine/etc/alpine-anywhere/config.env; do
    [ -f "$_cfg" ] && . "$_cfg" && break
done
bc "config: iface=$NETWORK_INTERFACE ip=$NETWORK_IP mask=$NETWORK_NETMASK gw=$NETWORK_GATEWAY dhcp=$NETWORK_DHCP target=$TARGET_DISK"

# Best-effort: bring the detected interface up with its static IP (or DHCP) and
# start SSH. Used by the recovery paths so a headless box stays reachable.
_recover_net() {
    /sbin/ifconfig lo 127.0.0.1 up 2>/dev/null || true
    _ri="$NETWORK_INTERFACE"
    [ -n "$_ri" ] && [ -e "/sys/class/net/$_ri" ] || _ri=$(for d in /sys/class/net/*; do b=$(basename "$d"); [ "$b" = lo ] || { echo "$b"; break; }; done)
    if [ "$NETWORK_DHCP" = "true" ]; then
        /sbin/udhcpc -i "$_ri" -b -q 2>/dev/null &
    else
        /sbin/ifconfig "$_ri" "$NETWORK_IP" netmask "$NETWORK_NETMASK" up 2>/dev/null
        /sbin/route add default gw "$NETWORK_GATEWAY" 2>/dev/null || true
    fi
    /usr/sbin/dropbear -R -p 22 2>/dev/null || { mkdir -p /run/sshd; /usr/sbin/sshd 2>/dev/null; } || true
    bc "recovery net: iface=$_ri ip=$NETWORK_IP"
}

# NOTE: deliberately NO mass fd-closing here. systemd re-execs this script by
# execve'ing /usr/lib/systemd/systemd (bind-mounted to it), and the shell keeps
# reading the script from that descriptor; closing fds > 2 can close that very
# descriptor, so the interpreter cannot read the rest of the script and the
# takeover dies silently right after the banner. The old root does not need fds
# closed - pivot_root + lazy umount (below) detach it regardless.
bc "skipping fd-close (pivot_root + lazy umount free the old root)"

bc "mount --make-rprivate /"
mount --make-rprivate / 2>/dev/null || true

bc "preparing pivot_root: cd $PIVOT_DIR; mkdir .$OLD_ROOT"
cd "${PIVOT_DIR}" || bc "WARN cd $PIVOT_DIR failed"
mkdir -p ".${OLD_ROOT}"

bc "executing pivot_root . .${OLD_ROOT}"
if ! pivot_root . ".${OLD_ROOT}"; then
    rc=$?
    bc "pivot_root FAILED (rc=$rc) - THIS is the takeover failure point"
    # Still on the OLD root. Bring REAL networking + SSH up (not just lo) so the
    # operator can reconnect, and keep PID 1 alive with a console shell. Never
    # `exec` a shell here: if its stdin EOFs, PID 1 exits and the kernel panics
    # (reboots the box) before anyone can look.
    _recover_net
    bc "pivot_root failed; SSH + console shell up. Reboot to recover the prior OS."
    setsid sh -c 'exec sh </dev/console >/dev/console 2>&1' 2>/dev/null &
    while true; do wait -n 2>/dev/null || sleep 1; done
fi

# Past pivot_root: the OLD root (our breadcrumb disk) is now at /mnt/oldroot.
# Keep logging there (same physical fs) until it is unmounted below.
BCLOG="${OLD_ROOT}/aa-fakeinit.log"
bc "pivot_root OK; now PID 1 in the RAM root"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Remount proc to see correct process info
mount -t proc proc /proc 2>/dev/null || true

# Kill ALL processes except PID 1 (us)
bc "killing old-root processes (TERM then KILL)"
for sig in TERM KILL; do
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | sort -n); do
        [ "$pid" = "1" ] && continue
        [ "$pid" = "$$" ] && continue
        [ ! -d "/proc/$pid" ] && continue
        kill -${sig} "$pid" 2>/dev/null || true
    done
    [ "$sig" = "TERM" ] && sleep 3
done
bc "processes killed"

sleep 2

# Now unmount everything on old root (this is the LAST point breadcrumbs persist
# to disk; afterwards only the console has output).
bc "unmounting old root (final persisted breadcrumb)"
for mnt in $(awk '{print $2}' /proc/mounts | grep "^${OLD_ROOT}" | sort -r); do
    echo "[fakeinit]   umount $mnt"
    umount -l "$mnt" 2>/dev/null || true
done
BCLOG=""   # old root gone - stop trying to persist (console only from here)

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

# Setup networking. The NIC keeps its kernel name across pivot_root, but fall
# back to auto-detection if the configured name is absent in this minimal env
# (predictable names may not be reapplied without systemd/udev).
echo "[fakeinit] Starting networking..."
/sbin/ifconfig lo 127.0.0.1 up 2>/dev/null || true

IFACE="$NETWORK_INTERFACE"
if [ -z "$IFACE" ] || [ ! -e "/sys/class/net/$IFACE" ]; then
    for cand in /sys/class/net/*; do
        c=$(basename "$cand"); [ "$c" = "lo" ] && continue
        [ -e "$cand" ] || continue
        IFACE="$c"; break
    done
    echo "[fakeinit] configured iface absent -> using detected '$IFACE'"
fi

if [ "$NETWORK_DHCP" = "true" ]; then
    echo "[fakeinit] DHCP on ${IFACE}..."
    /sbin/ip link set "$IFACE" up 2>/dev/null || /sbin/ifconfig "$IFACE" up 2>/dev/null || true
    /sbin/udhcpc -i "$IFACE" -b -q 2>/dev/null &
else
    echo "[fakeinit] Static IP ${NETWORK_IP} on ${IFACE}..."
    /sbin/ifconfig "$IFACE" "$NETWORK_IP" netmask "$NETWORK_NETMASK" up
    /sbin/route add default gw "$NETWORK_GATEWAY" 2>/dev/null \
        || /sbin/ip route add default via "$NETWORK_GATEWAY" 2>/dev/null || true
fi

# Start SSH immediately so the box is reachable for diagnosis regardless of
# whether the upstream network is confirmed below.
echo "[fakeinit] Starting SSH..."
if [ "$HARDENED_MODE" = "true" ]; then
    /usr/sbin/dropbear -R -p 22 -E 2>/dev/null &
else
    mkdir -p /run/sshd; /usr/sbin/sshd
fi

# Verify upstream connectivity BEFORE launching anything destructive: the in-RAM
# build needs the Alpine mirror, and the install must NOT touch the disk if the
# network did not come back after the pivot (a reboot then recovers the prior
# OS, untouched).
NET_OK=0; n=0
_mirror_root="${ALPINE_MIRROR:-http://dl-cdn.alpinelinux.org/alpine}"
while [ $n -lt 20 ]; do
    if wget -q -T 5 -O /dev/null "${_mirror_root%/}/" 2>/dev/null \
       || ping -c1 -W2 "${NETWORK_GATEWAY:-1.1.1.1}" >/dev/null 2>&1; then
        NET_OK=1; break
    fi
    sleep 3; n=$((n + 1))
done
echo "[fakeinit] ==================================="
echo "[fakeinit] iface=$IFACE ip=$NETWORK_IP network_confirmed=$NET_OK"
echo "[fakeinit] SSH available on port 22"
echo "[fakeinit] ==================================="

# Always dump network diagnostics to the console so a failure is visible even
# without SSH (the console is the only window once the link is down).
echo "[fakeinit] ---- network diagnostics ----"
ifconfig -a 2>/dev/null || ip addr 2>/dev/null
echo "[fakeinit] routes:"; route -n 2>/dev/null || ip route 2>/dev/null
echo "[fakeinit] link states:"
for _n in /sys/class/net/*; do
    [ -e "$_n" ] || continue
    echo "  $(basename "$_n"): carrier=$(cat "$_n/carrier" 2>/dev/null) operstate=$(cat "$_n/operstate" 2>/dev/null)"
done
echo "[fakeinit] ethtool $IFACE:"; ethtool "$IFACE" 2>&1 | grep -iE "link detected|speed|duplex"
echo "[fakeinit] resolv.conf:"; cat /etc/resolv.conf 2>/dev/null
echo "[fakeinit] gw ping:"; ping -c2 -W2 "$NETWORK_GATEWAY" 2>&1 | tail -3
echo "[fakeinit] recent dmesg:"; dmesg 2>/dev/null | tail -25
echo "[fakeinit] ------------------------------"

# Start A/B installation ONLY if the network is confirmed (prerequisite for the
# destructive partition step). Otherwise leave the disk untouched, stay
# reachable, and open an interactive console shell for live diagnosis.
if [ "$NET_OK" != "1" ]; then
    echo "[fakeinit] NETWORK NOT CONFIRMED - install NOT started; disk left intact."
    echo "[fakeinit] Opening a debug shell on the console. Try: ifconfig -a; route -n; dmesg|tail"
    echo "[fakeinit] Reboot to return to the previous OS (disk untouched)."
    setsid sh -c 'exec sh </dev/console >/dev/console 2>&1' 2>/dev/null &
elif [ -f /root/.local/share/alpine-anywhere/alpine-anywhere ]; then
    echo "[fakeinit] Network OK - starting A/B installation in background..."
    . /etc/alpine-anywhere/config.env

    INSTALL_CMD="sh /root/.local/share/alpine-anywhere/alpine-anywhere --local --install-continue"
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

    # === TAKEOVER-INIT (busybox/OpenRC source) ===
    # busybox init re-execs this (as PID 1) via an inittab `restart` action on
    # SIGQUIT. It runs FIRST on the OLD root, whose userland is a minimal Alpine
    # with no bash — so this MUST be POSIX sh (/bin/sh = busybox), unlike the
    # bash fakeinit used for systemd sources.
    run_privileged tee "${PIVOT_DIR}/sbin/takeover-init" > /dev/null << 'TAKEOVERINIT'
#!/bin/sh
# takeover-init - PID 1 after busybox init re-execs (Alpine/busybox source)
PIVOT_DIR="/mnt/alpine"
OLD_ROOT="/mnt/oldroot"

exec > /dev/console 2>&1

# Persistent breadcrumb log on the FAT boot partition (sda1), so a failed
# takeover can be diagnosed after the fact (no serial console needed).
# NOTE: if the takeover SUCCEEDS, run_ab_install later repartitions the disk
# and this log is overwritten - that's fine, we only need it on failure.
AA_LOGDEV=$(grep -oE '/dev/[a-z0-9]+1\b' /proc/cmdline 2>/dev/null | head -1)
[ -n "$AA_LOGDEV" ] || AA_LOGDEV=/dev/sda1
mkdir -p /aa-log 2>/dev/null
mount "$AA_LOGDEV" /aa-log 2>/dev/null || mount -t vfat "$AA_LOGDEV" /aa-log 2>/dev/null || true
tlog() {
    echo "[takeover-init] $*"
    echo "[$(cat /proc/uptime 2>/dev/null | cut -d. -f1)] $*" >> /aa-log/takeover.log 2>/dev/null || true
    sync 2>/dev/null || true
}

tlog "=== PID 1 takeover (busybox) === pid=$$"

# Release old-root file descriptors
for fd in /proc/self/fd/*; do
    n=${fd##*/}
    [ "$n" -gt 2 ] 2>/dev/null && eval "exec ${n}>&-" 2>/dev/null || true
done

mount --make-rprivate / 2>/dev/null || true

tlog "pre-pivot: PIVOT_DIR=${PIVOT_DIR} ismount=$(grep -c " ${PIVOT_DIR} " /proc/mounts) sh=$(ls -l /bin/sh 2>/dev/null)"
tlog "pivot_root into ${PIVOT_DIR}..."
# On failure: do NOT exec /bin/sh (as PID 1 with no tty it exits -> kernel
# panic -> reboot). Instead hang so PID 1 survives, the old sshd stays alive,
# and the failure can be diagnosed over SSH / from /aa-log.
cd "$PIVOT_DIR" || { tlog "cd failed"; while :; do sleep 5; done; }
mkdir -p ".${OLD_ROOT}"
if ! pivot_root . ".${OLD_ROOT}"; then
    tlog "ERROR: pivot_root failed rc=$?"
    while :; do sleep 5; done
fi
echo "[takeover-init] pivot_root OK"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc 2>/dev/null || true

# Kill every process still on the old root (frees the install disk)
echo "[takeover-init] killing old-root processes..."
for sig in TERM KILL; do
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | sort -n); do
        [ "$pid" = "1" ] && continue
        [ "$pid" = "$$" ] && continue
        kill -"$sig" "$pid" 2>/dev/null || true
    done
    [ "$sig" = "TERM" ] && sleep 3
done
sleep 2

echo "[takeover-init] unmounting old root (frees the disk)..."
for mnt in $(awk '{print $2}' /proc/mounts | grep "^${OLD_ROOT}" | sort -r); do
    umount -l "$mnt" 2>/dev/null || true
done
umount -l "${OLD_ROOT}" 2>/dev/null || true

mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null || true
mkdir -p /run

[ -f /etc/alpine-anywhere/config.env ] && . /etc/alpine-anywhere/config.env

echo "[takeover-init] networking..."
/sbin/ifconfig lo 127.0.0.1 up 2>/dev/null || true
if [ -n "$NETWORK_INTERFACE" ]; then
    if [ "$NETWORK_DHCP" = "true" ]; then
        /sbin/udhcpc -i "$NETWORK_INTERFACE" -b -q 2>/dev/null &
        sleep 3
    else
        /sbin/ifconfig "$NETWORK_INTERFACE" "$NETWORK_IP" netmask "$NETWORK_NETMASK" up 2>/dev/null || true
        /sbin/route add default gw "$NETWORK_GATEWAY" 2>/dev/null || true
    fi
fi

echo "[takeover-init] sshd..."
if [ "$HARDENED_MODE" = "true" ]; then
    /usr/sbin/dropbear -R -p 22 -E 2>/dev/null &
else
    mkdir -p /run/sshd
    /usr/sbin/sshd 2>/dev/null || true
fi

if [ -f /root/.local/share/alpine-anywhere/alpine-anywhere ]; then
    echo "[takeover-init] starting A/B install (--install-continue)..."
    INSTALL_CMD="sh /root/.local/share/alpine-anywhere/alpine-anywhere --local --install-continue"
    [ "$VERBOSE" = "true" ] && INSTALL_CMD="$INSTALL_CMD -v"
    [ "$FORCE" = "true" ] && INSTALL_CMD="$INSTALL_CMD -f"
    [ -n "$ALPINE_VERSION" ] && INSTALL_CMD="$INSTALL_CMD -V $ALPINE_VERSION"
    [ -n "$ALPINE_MIRROR" ] && INSTALL_CMD="$INSTALL_CMD -m $ALPINE_MIRROR"
    # --disk / --custom-script / --ssh-host-keys come from config.env (sourced
    # by --install-continue), so they don't need to be on the command line.
    echo "[takeover-init] $INSTALL_CMD"
    $INSTALL_CMD > /var/log/alpine-install.log 2>&1 &
    echo "[takeover-init] monitor: tail -f /var/log/alpine-install.log"
fi

echo "[takeover-init] entering PID 1 reaper loop"
while :; do
    wait 2>/dev/null
    sleep 1
done
TAKEOVERINIT

    run_privileged chmod +x "${PIVOT_DIR}/sbin/takeover-init"
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

# Strategy: reboot into a RAM installer (no runtime PID 1 takeover).
# Used when the running init can't be re-exec'd at runtime (e.g. busybox init).
# We turn the already-built pivot env (${PIVOT_DIR}: install tools + scripts +
# cache + config) into an initramfs, add the running kernel's modules, write it
# next to the existing vmlinuz on the boot partition, and reboot. The RPi
# firmware then boots that initramfs entirely in RAM (the disk is free), its
# /init runs the A/B install onto the disk, and reboots into the new system.
pivot_reboot_installer() {
    log_info "Using reboot-into-RAM-installer strategy..."

    local kver
    kver=$(uname -r)

    # 1. Kernel modules matching the on-disk vmlinuz (same running kernel)
    if [ -d "/lib/modules/${kver}" ]; then
        log_info "Bundling kernel modules ${kver}..."
        run_privileged mkdir -p "${PIVOT_DIR}/lib/modules"
        run_privileged cp -a "/lib/modules/${kver}" "${PIVOT_DIR}/lib/modules/"
    else
        log_warn "No /lib/modules/${kver}; installer may not see the disk"
    fi

    # 2. Installer /init (PID 1 of the initramfs; disk is free, no pivot needed)
    run_privileged tee "${PIVOT_DIR}/init" > /dev/null << 'INSTALLERINIT'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec > /dev/console 2>&1
echo "[ram-installer] === PID 1 (initramfs) ==="

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null
mkdir -p /run /tmp

echo "[ram-installer] loading storage/fs modules..."
for m in dwc2 phy-generic xhci-pci-renesas xhci-pci xhci-hcd \
         usb-storage uas scsi_mod sd_mod \
         nvme ext4 vfat nls_cp437 nls_iso8859-1 squashfs loop crc32c; do
    modprobe "$m" 2>/dev/null || true
done
# Let USB enumerate
sleep 5
mdev -s 2>/dev/null || true

echo "[ram-installer] block devices:"; ls -l /dev/sd* /dev/nvme* /dev/mmcblk* 2>/dev/null

[ -f /etc/alpine-anywhere/config.env ] && . /etc/alpine-anywhere/config.env

echo "[ram-installer] networking..."
ifconfig lo 127.0.0.1 up 2>/dev/null || true
if [ -n "$NETWORK_INTERFACE" ]; then
    if [ "$NETWORK_DHCP" = "true" ]; then
        udhcpc -i "$NETWORK_INTERFACE" -b -q 2>/dev/null &
        sleep 4
    else
        ifconfig "$NETWORK_INTERFACE" "$NETWORK_IP" netmask "$NETWORK_NETMASK" up 2>/dev/null || true
        route add default gw "$NETWORK_GATEWAY" 2>/dev/null || true
    fi
fi

# Optional SSH for live monitoring/rescue (dropbear in hardened mode)
if [ "$HARDENED_MODE" = "true" ]; then
    /usr/sbin/dropbear -R -p 22 2>/dev/null || true
else
    mkdir -p /run/sshd
    /usr/sbin/sshd 2>/dev/null || true
fi

echo "[ram-installer] starting A/B install onto disk..."
INSTALL_CMD="sh /root/.local/share/alpine-anywhere/alpine-anywhere --local --install-continue"
[ "$VERBOSE" = "true" ] && INSTALL_CMD="$INSTALL_CMD -v"
[ "$FORCE" = "true" ] && INSTALL_CMD="$INSTALL_CMD -f"
[ -n "$ALPINE_VERSION" ] && INSTALL_CMD="$INSTALL_CMD -V $ALPINE_VERSION"
[ -n "$ALPINE_MIRROR" ] && INSTALL_CMD="$INSTALL_CMD -m $ALPINE_MIRROR"
echo "[ram-installer] $INSTALL_CMD"
# Capture the INSTALLER's exit code, not tee's. In a pipeline `rc=$?` reflects
# the last element (tee), which is ~always 0 - so a failed A/B install would
# report success and reboot into a possibly-unbootable disk. BusyBox ash has no
# PIPESTATUS, so stash the real rc through a file.
{ $INSTALL_CMD 2>&1; echo $? > /tmp/aa-install.rc; } | tee /dev/console
rc=$(cat /tmp/aa-install.rc 2>/dev/null || echo 1)
echo "[ram-installer] install finished rc=$rc"
sync
if [ "$rc" -eq 0 ]; then
    echo "[ram-installer] rebooting into installed system in 5s..."
    sleep 5
    reboot -f
else
    echo "[ram-installer] INSTALL FAILED rc=$rc - dropping to shell, system left as-is"
    exec /bin/sh
fi
INSTALLERINIT
    run_privileged chmod +x "${PIVOT_DIR}/init"

    # 3. Unmount the virtual filesystems inside PIVOT_DIR so the cpio doesn't
    #    archive a live /proc /sys /dev (the initramfs /init remounts them).
    for vfs in dev/pts dev sys proc; do
        run_privileged umount "${PIVOT_DIR}/${vfs}" 2>/dev/null || true
    done

    # 4. Package the env as a gzip cpio initramfs onto the boot partition
    local boot_mnt="/mnt/aa-bootstage" disk part1
    disk=$(strip_partition "$(get_root_device)")
    part1=$(get_part_dev "$disk" 1)
    run_privileged mkdir -p "$boot_mnt"
    run_privileged mount "$part1" "$boot_mnt" || die "cannot mount boot partition $part1"
    assert_mounted "$boot_mnt"

    log_info "Building installer initramfs onto ${part1}..."
    # Capture the cpio/gzip status (no 2>/dev/null swallowing) so a failed pack
    # is caught BEFORE we repoint the bootloader at a corrupt installer.img.
    ( cd "$PIVOT_DIR" && run_privileged sh -c "set -o pipefail 2>/dev/null; find . -path ./old_root -prune -o -print0 | cpio -0 -o -H newc | gzip -1 > '${boot_mnt}/installer.img'" ) \
        || die "failed to build installer.img (cpio/gzip error)"

    # Validate the artifact: gzip integrity + the cpio actually contains ./init.
    run_privileged sh -c "gzip -t '${boot_mnt}/installer.img'" \
        || die "installer.img failed gzip integrity check"
    run_privileged sh -c "gzip -dc '${boot_mnt}/installer.img' | cpio -t 2>/dev/null | grep -qx './init'" \
        || die "installer.img does not contain ./init - refusing to repoint bootloader"
    log_info "installer.img: $(run_privileged du -h "${boot_mnt}/installer.img" | cut -f1) (validated)"

    # 4. Point config.txt at vmlinuz + installer.img for the next boot.
    #    The .preinstall backups are the ONLY rollback if the installer is bad,
    #    so they are mandatory (require), not best-effort.
    require run_privileged cp "${boot_mnt}/config.txt" "${boot_mnt}/config.txt.preinstall"
    require run_privileged cp "${boot_mnt}/cmdline.txt" "${boot_mnt}/cmdline.txt.preinstall"
    local kimg
    kimg=$(ls "${boot_mnt}"/vmlinuz* 2>/dev/null | head -1)
    kimg=$(basename "${kimg:-vmlinuz}")
    run_privileged tee "${boot_mnt}/config.txt" > /dev/null << EOF
arm_64bit=1
enable_uart=1
[pi4]
kernel=${kimg}
initramfs installer.img followkernel
[all]
EOF
    echo "console=tty1" | run_privileged tee "${boot_mnt}/cmdline.txt" > /dev/null
    run_privileged sync
    run_privileged umount "$boot_mnt" || true

    log_warn "Rebooting into the RAM installer now..."
    log_warn "Reconnect after install completes: ssh root@${DETECTED_IP_ADDRESS}"
    run_privileged reboot -f || run_privileged reboot
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
        busybox)
            # busybox init can't be re-exec'd at runtime -> reboot into a RAM installer
            pivot_reboot_installer
            ;;
        runit)
            pivot_runit
            ;;
        openrc)
            # Alpine's OpenRC runs on top of busybox init (PID 1)
            pivot_reboot_installer
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
    http_fetch_file "$url" "${INSTALL_CACHE_DIR}/minirootfs.tar.gz"
}
