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
        s6-svscan|s6-linux-init)
            # s6 (what alpine-anywhere's own hardened images run): PID 1 is
            # s6-svscan; it can be told to re-exec into a takeover init.
            echo "s6"
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
DETECTED_IPV6_ADDRESS="${DETECTED_IPV6_ADDRESS}"
DETECTED_IPV6_CIDR="${DETECTED_IPV6_CIDR}"
DETECTED_IPV6_GATEWAY="${DETECTED_IPV6_GATEWAY}"
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
    while true; do wait 2>/dev/null; sleep 1; done
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
# to disk; afterwards only the console has output). CRITICAL: use a REAL (non-lazy)
# unmount so the slot partition actually RELEASES. A lazy `umount -l` only detaches
# the name - the device stays busy (BLKRRPART -> EBUSY), which strands the disk
# half-repartitioned. An immutable aa origin makes this worse: its root is an
# overlay whose lowerdir is the slot squashfs, and the squashfs only frees once
# the overlay ABOVE it is gone. So iterate non-lazy unmounts until nothing more
# releases (the overlay drops first, then its squashfs lowerdir on the next pass).
bc "unmounting old root (non-lazy, multi-pass: overlay then its squashfs lowerdir)"
_pass=0
while [ "$_pass" -lt 6 ]; do
    _did=0
    for mnt in $(awk '{print $2}' /proc/mounts | grep "^${OLD_ROOT}" | sort -r); do
        if umount "$mnt" 2>/dev/null; then echo "[fakeinit]   umount $mnt"; _did=1; fi
    done
    umount "${OLD_ROOT}" 2>/dev/null && _did=1
    [ "$_did" = "0" ] && break
    _pass=$((_pass + 1))
done
BCLOG=""   # old root gone - stop trying to persist (console only from here)

# Anything still stubbornly mounted (unexpected holder): lazy-detach as a last
# resort. This does NOT free the disk, but the disk-busy safety gate in
# create_partition_layout then ABORTS the install before wiping the GPT, so the
# box stays recoverable instead of bricked.
for mnt in $(awk '{print $2}' /proc/mounts | grep "^${OLD_ROOT}" | sort -r); do
    umount -l "$mnt" 2>/dev/null || true
done
umount -l "${OLD_ROOT}" 2>/dev/null || true

if mountpoint -q "${OLD_ROOT}" 2>/dev/null; then
    echo "[fakeinit] WARNING: ${OLD_ROOT} still mounted (disk-busy gate will abort the install safely)"
else
    echo "[fakeinit] Old root unmounted successfully (disk released)"
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

# PID 1 must never exit - reap zombies forever. Bare `wait` (not `wait -n`,
# a bash/ksh-ism BusyBox ash does not implement) so zombies are actually reaped.
echo "[fakeinit] Entering zombie reaper loop (PID 1)"
while true; do
    wait 2>/dev/null
    sleep 1
done
FAKEINIT

    run_privileged chmod +x "${PIVOT_DIR}/sbin/fakeinit"

    # === TAKEOVER-INIT (busybox/OpenRC source) ===
    # busybox init re-execs this (as PID 1) via an inittab `restart` action on
    # SIGQUIT. It runs FIRST on the OLD root, whose userland is a minimal Alpine
    # with no bash - so this MUST be POSIX sh (/bin/sh = busybox), unlike the
    # bash fakeinit used for systemd sources.
    run_privileged tee "${PIVOT_DIR}/sbin/takeover-init" > /dev/null << 'TAKEOVERINIT'
#!/bin/sh
# takeover-init - PID 1 after busybox init re-execs (Alpine/busybox source)
PIVOT_DIR="/mnt/alpine"
OLD_ROOT="/mnt/oldroot"

exec > /dev/console 2>&1

# Persistent breadcrumb log on the boot partition (sda1), so a failed
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

# Strategy for s6 (s6-svscan as PID 1 - alpine-anywhere's own hardened images).
# s6-svscan exec()s its scandir's .s6-svscan/finish script when it exits, so we
# point finish at the takeover fakeinit and ask s6-svscan to TERMINATE (`-t`):
# it brings ALL services down FIRST, then execs finish. The shutdown is essential
# on an immutable aa origin: the root is an overlay whose lowerdir is the slot
# squashfs, and the running services (dropbear, ...) map their binaries from that
# squashfs. If they are left running (`-b` abort), they keep the slot partition
# busy after the lazy unmount, and the subsequent `parted` on the boot disk fails
# with "partition in use". `-t` reaps them before the fakeinit partitions.
# The fakeinit is failure-safe (never exits PID 1), so a botched pivot degrades to
# a reachable recovery shell rather than a panic.
pivot_s6() {
    log_info "Using s6 strategy (s6-svscan -> .s6-svscan/finish)..."

    local scandir
    scandir=$(tr '\0' '\n' < /proc/1/cmdline 2>/dev/null | grep '^/' | tail -1)
    [ -d "${scandir}/.s6-svscan" ] || scandir=/run/service
    if [ ! -d "${scandir}/.s6-svscan" ]; then
        log_error "no ${scandir}/.s6-svscan control dir; falling back to RAM installer"
        pivot_reboot_installer
        return
    fi
    if [ ! -x "${PIVOT_DIR}/sbin/fakeinit" ]; then
        log_error "fakeinit missing at ${PIVOT_DIR}/sbin/fakeinit; falling back"
        pivot_direct
        return
    fi

    local fin="${scandir}/.s6-svscan/finish"
    log_info "Pointing ${fin} at the takeover fakeinit..."
    run_privileged sh -c "printf '#!/bin/sh\nexec %s/sbin/fakeinit\n' '${PIVOT_DIR}' > '${fin}' && chmod +x '${fin}'"

    log_warn "Triggering s6-svscanctl -t ${scandir} - services down, then PID 1 execs fakeinit..."
    log_warn "Connection WILL be lost. Reconnect via: ssh root@${DETECTED_IP_ADDRESS}"
    run_privileged s6-svscanctl -t "${scandir}"
}

# Bundle the running kernel's modules into the initramfs staging dir so the RAM
# installer's /init can modprobe the storage/network drivers it needs to see the
# disk. Shared by the RPi-firmware (pivot_reboot_installer) and the x86-kexec
# (pivot_kexec_installer) installers - both boot the SAME initramfs, only the
# boot mechanism differs.
_bundle_running_kernel_modules() {
    local dest="$1" kver
    kver=$(uname -r)
    if [ -d "/lib/modules/${kver}" ]; then
        log_info "Bundling kernel modules ${kver}..."
        run_privileged mkdir -p "${dest}/lib/modules"
        run_privileged cp -a "/lib/modules/${kver}" "${dest}/lib/modules/"
    else
        log_warn "No /lib/modules/${kver}; installer may not see the disk"
    fi
}

# Write the RAM-installer /init (PID 1 of the initramfs) into $1. The disk is
# free at this point (a fresh kernel/initramfs boot, no pivot), so /init just
# brings up modules + network and runs the A/B install onto the disk. Shared by
# both RAM-installer strategies so the installer logic stays in one place.
_emit_installer_init() {
    local dest="$1"
    run_privileged tee "${dest}/init" > /dev/null << 'INSTALLERINIT'
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
# virtio_* first: cloud/KVM hosts (Hetzner, most VPS) present the disk + NIC as
# virtio-blk/virtio-net, so without these the installer never sees /dev/vd*|/dev/sd*
# or the network. The USB/NVMe/scsi set covers bare metal + Raspberry Pi.
for m in virtio_pci virtio_blk virtio_scsi virtio_net \
         dwc2 phy-generic xhci-pci-renesas xhci-pci xhci-hcd \
         usb-storage uas scsi_mod sd_mod \
         nvme ext4 vfat nls_cp437 nls_iso8859-1 squashfs loop crc32c; do
    modprobe "$m" 2>/dev/null || true
done
# Let USB enumerate
sleep 5
mdev -s 2>/dev/null || true

echo "[ram-installer] block devices:"; ls -l /dev/vd* /dev/sd* /dev/nvme* /dev/mmcblk* 2>/dev/null

[ -f /etc/alpine-anywhere/config.env ] && . /etc/alpine-anywhere/config.env

echo "[ram-installer] networking..."
ifconfig lo 127.0.0.1 up 2>/dev/null || ip link set lo up 2>/dev/null || true
if [ -n "$NETWORK_INTERFACE" ]; then
    ip link set "$NETWORK_INTERFACE" up 2>/dev/null || ifconfig "$NETWORK_INTERFACE" up 2>/dev/null || true
    if [ "$NETWORK_DHCP" = "true" ]; then
        # BusyBox udhcpc only OBTAINS the lease; an apply-script is what actually
        # configures IP/route/DNS, and the minirootfs may not ship one - without it
        # the box gets a lease but no working network, and the installer's mirror
        # pre-check then aborts before touching the disk. Ship our own script. It
        # also handles a cloud /32 + on-link gateway (Hetzner): the router is off
        # the local subnet, so add an explicit on-link route before the default.
        cat > /tmp/udhcpc.script << 'UDHCPC'
#!/bin/sh
case "$1" in
  bound|renew)
    ip addr flush dev "$interface" 2>/dev/null
    ip addr add "$ip/${mask:-32}" dev "$interface" 2>/dev/null \
        || ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.255}" up
    for r in $router; do
        ip route add "$r" dev "$interface" 2>/dev/null
        ip route add default via "$r" dev "$interface" 2>/dev/null \
            || route add default gw "$r" 2>/dev/null
    done
    : > /etc/resolv.conf
    for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
    ;;
esac
UDHCPC
        chmod +x /tmp/udhcpc.script
        udhcpc -i "$NETWORK_INTERFACE" -s /tmp/udhcpc.script -q -n -t 10 -T 2 2>/dev/null \
            || udhcpc -i "$NETWORK_INTERFACE" -s /tmp/udhcpc.script -b 2>/dev/null
    else
        ip addr add "$NETWORK_IP/${NETWORK_CIDR:-32}" dev "$NETWORK_INTERFACE" 2>/dev/null \
            || ifconfig "$NETWORK_INTERFACE" "$NETWORK_IP" netmask "$NETWORK_NETMASK" up 2>/dev/null || true
        ip route add "$NETWORK_GATEWAY" dev "$NETWORK_INTERFACE" 2>/dev/null || true
        ip route add default via "$NETWORK_GATEWAY" dev "$NETWORK_INTERFACE" 2>/dev/null \
            || route add default gw "$NETWORK_GATEWAY" 2>/dev/null || true
    fi
fi
# Ensure name resolution even if DHCP pushed no DNS (the mirror is a hostname).
[ -s /etc/resolv.conf ] || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

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
    run_privileged chmod +x "${dest}/init"
}

# Drop the virtual-fs mounts inside the staging dir so the cpio archive doesn't
# capture a live /proc /sys /dev (the installer /init remounts them itself).
_unmount_pivot_vfs() {
    local dir="$1" vfs
    for vfs in dev/pts dev sys proc; do
        run_privileged umount "${dir}/${vfs}" 2>/dev/null || true
    done
}

# Pack SRC as a gzip cpio initramfs at OUT, then VALIDATE it (gzip integrity +
# the archive really contains ./init) before any caller commits to booting it.
# No 2>/dev/null swallowing on the pack: a corrupt image must abort here, never
# reach the bootloader/kexec. Dies on any failure.
_pack_installer_img() {
    local src="$1" out="$2"
    log_info "Building installer initramfs ${out}..."
    # NOTE: no `set -o pipefail` here. /bin/sh is dash on Debian/Ubuntu, where an
    # unknown `set -o` option is a FATAL error that aborts the whole `sh -c`
    # before the pipeline ever runs (the 2>/dev/null only hid the message, not
    # the abort) - which silently broke the pack on every dash host. Correctness
    # is instead enforced by the explicit post-pack validation below: a truncated
    # or empty image fails the gzip integrity check or the ./init presence check.
    ( cd "$src" && run_privileged sh -c "find . -path ./old_root -prune -o -print0 | cpio -0 -o -H newc | gzip -1 > '${out}'" ) \
        || die "failed to build installer.img (cpio/gzip error)"
    run_privileged sh -c "gzip -t '${out}'" \
        || die "installer.img failed gzip integrity check"
    # Accept both "init" and "./init": GNU cpio (Debian) stores the find paths
    # without the leading ./, BusyBox cpio (Alpine/RPi) keeps it. Both extract to
    # /init and boot the same; pinning one form wrongly rejected a valid image.
    run_privileged sh -c "gzip -dc '${out}' | cpio -t 2>/dev/null | grep -qxE '(\\./)?init'" \
        || die "installer.img does not contain init - refusing to boot it"
    log_info "installer.img: $(run_privileged du -h "${out}" | cut -f1) (validated)"
}

# Strategy: reboot into a RAM installer via the Raspberry Pi firmware (no runtime
# PID 1 takeover). Used when the running init can't be re-exec'd at runtime (e.g.
# busybox init) on a Pi. We build the installer initramfs, write it next to the
# existing vmlinuz on the FAT boot partition, point config.txt at it, and reboot.
# The Pi firmware then boots that initramfs entirely in RAM (the disk is free),
# its /init runs the A/B install onto the disk, and reboots into the new system.
pivot_reboot_installer() {
    log_info "Using reboot-into-RAM-installer strategy (RPi firmware)..."
    _bundle_running_kernel_modules "$PIVOT_DIR"
    _emit_installer_init "$PIVOT_DIR"
    _unmount_pivot_vfs "$PIVOT_DIR"

    local boot_mnt="/mnt/aa-bootstage" disk part1
    disk=$(strip_partition "$(get_root_device)")
    part1=$(get_part_dev "$disk" 1)
    run_privileged mkdir -p "$boot_mnt"
    run_privileged mount "$part1" "$boot_mnt" || die "cannot mount boot partition $part1"
    assert_mounted "$boot_mnt"

    _pack_installer_img "$PIVOT_DIR" "${boot_mnt}/installer.img"

    # Point config.txt at vmlinuz + installer.img for the next boot.
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

# Locate the running kernel's bootable vmlinuz file (needed as the kexec target).
# Cloud/distro kernels keep it at /boot/vmlinuz-$(uname -r); fall back to a bare
# /boot/vmlinuz symlink. Echoes the path, or nothing if none is found.
_find_running_kernel_image() {
    local kver; kver=$(uname -r)
    for k in "/boot/vmlinuz-${kver}" /boot/vmlinuz "/boot/vmlinuz-linux"; do
        [ -f "$k" ] && { printf '%s\n' "$k"; return 0; }
    done
    return 1
}

# Ensure a usable kexec binary exists on the SOURCE OS (we are still pre-pivot,
# so its native package manager is available). Echoes the kexec path on success.
_ensure_kexec_local() {
    local k
    for k in /sbin/kexec /usr/sbin/kexec; do [ -x "$k" ] && { printf '%s\n' "$k"; return 0; }; done
    command -v kexec >/dev/null 2>&1 && { command -v kexec; return 0; }

    local distro=""
    [ -f /etc/os-release ] && distro=$(. /etc/os-release 2>/dev/null; echo "$ID")
    log_info "Installing kexec-tools on source OS ($distro)..."
    case "$distro" in
        debian|ubuntu|armbian|raspbian)
            run_privileged sh -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y kexec-tools" >/dev/null 2>&1 ;;
        centos|rhel|fedora|rocky|almalinux|alma)
            run_privileged sh -c "dnf install -y kexec-tools 2>/dev/null || yum install -y kexec-tools" >/dev/null 2>&1 ;;
        arch|manjaro)
            run_privileged pacman -Sy --noconfirm kexec-tools >/dev/null 2>&1 ;;
        alpine)
            run_privileged apk add --no-cache kexec-tools >/dev/null 2>&1 ;;
        opensuse*|sles|suse)
            run_privileged zypper -n install kexec-tools >/dev/null 2>&1 ;;
        *)  return 1 ;;
    esac
    for k in /sbin/kexec /usr/sbin/kexec; do [ -x "$k" ] && { printf '%s\n' "$k"; return 0; }; done
    return 1
}

# Fetch the Alpine "virt" netboot kernel + matching modloop into the cache.
# Echoes "<vmlinuz> <modloop>" on success. We boot THIS kernel (not the host's
# own) post-kexec because the Alpine virt kernel is built to kexec cleanly on
# cloud hypervisors - a stock distro kernel can panic post-kexec on some KVM
# setups - and its module set covers cloud storage/NICs. arch-aware via
# DETECTED_ARCH (x86_64 / aarch64).
_fetch_alpine_installer_kernel() {
    local flavor=virt base
    base="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/netboot"
    cache_download "${base}/vmlinuz-${flavor}" "aa-installer-vmlinuz" 2>/dev/null || return 1
    cache_download "${base}/modloop-${flavor}" "aa-installer-modloop" 2>/dev/null || return 1
    local v="${INSTALL_CACHE_DIR}/aa-installer-vmlinuz" m="${INSTALL_CACHE_DIR}/aa-installer-modloop"
    [ -s "$v" ] && [ -s "$m" ] || return 1
    printf '%s %s\n' "$v" "$m"
}

# Bundle the Alpine kernel modules from a modloop (squashfs) into the initramfs
# staging dir, so the RAM installer's /init can modprobe the storage/net/fs
# drivers for the kernel we are about to kexec into. Self-contained: nothing has
# to be served over the network or off the (about-to-be-wiped) disk afterwards.
_bundle_modloop_modules() {
    local dest="$1" modloop="$2" mnt
    mnt=$(mktemp -d 2>/dev/null) || return 1
    run_privileged modprobe squashfs 2>/dev/null || true
    run_privileged modprobe loop 2>/dev/null || true
    if ! run_privileged mount -t squashfs -o loop,ro "$modloop" "$mnt" 2>/dev/null; then
        rm -rf "$mnt"; return 1
    fi
    run_privileged mkdir -p "${dest}/lib/modules"
    # modloop layout: modules/<kver>/...  (+ firmware/...)
    run_privileged cp -a "${mnt}/modules/." "${dest}/lib/modules/" 2>/dev/null || true
    if [ -d "${mnt}/firmware" ]; then
        run_privileged mkdir -p "${dest}/lib/firmware"
        run_privileged cp -a "${mnt}/firmware/." "${dest}/lib/firmware/" 2>/dev/null || true
    fi
    run_privileged umount "$mnt" 2>/dev/null || true
    rm -rf "$mnt"
    # A module dir must now exist, named for the kexec'd kernel's uname -r.
    [ -n "$(ls -A "${dest}/lib/modules/" 2>/dev/null)" ] || return 1
    return 0
}

# Strategy: kexec into a RAM installer (x86 BIOS/UEFI cloud + bare metal; the
# general non-RPi equivalent of pivot_reboot_installer). A systemd/sysvinit host
# cannot free its own boot disk in place: PID 1 keeps the original root mounted,
# so the kernel refuses to re-read the new partition table ("device is busy") and
# the in-place repartition fails. kexec sidesteps this entirely: we build the
# installer initramfs in RAM, then boot a FRESH kernel into it. Nothing from the
# disk is mounted in that fresh boot, so the installer repartitions a truly free
# disk, lays down the A/B slots, and reboots into the new system.
pivot_kexec_installer() {
    log_info "Using kexec-into-RAM-installer strategy (x86/cloud)..."

    local kexec_bin kimg="" modloop="" kpair
    kexec_bin=$(_ensure_kexec_local) \
        || die "kexec-tools unavailable on this host; cannot free the boot disk for an in-place install (install kexec-tools, or run from a non-systemd source that can pivot without kexec)"

    # Prefer the Alpine 'virt' netboot kernel + its modloop modules (kexec-clean
    # on cloud KVM, broad driver coverage), bundled into our self-contained
    # initramfs. Fall back to the host's own kernel if the mirror is unreachable.
    kpair=$(_fetch_alpine_installer_kernel) \
        && kimg=$(printf '%s' "$kpair" | awk '{print $1}') \
        && modloop=$(printf '%s' "$kpair" | awk '{print $2}')
    if [ -n "$kimg" ] && [ -f "$kimg" ] && [ -n "$modloop" ] && _bundle_modloop_modules "$PIVOT_DIR" "$modloop"; then
        log_info "installer kernel: Alpine netboot virt ($kimg)"
    else
        log_warn "Alpine netboot kernel/modloop unavailable; falling back to the host kernel"
        kimg=$(_find_running_kernel_image) \
            || die "no installer kernel available (Alpine netboot fetch failed and no /boot/vmlinuz)"
        _bundle_running_kernel_modules "$PIVOT_DIR"
    fi
    log_info "kexec: $kexec_bin  kernel: $kimg"

    _emit_installer_init "$PIVOT_DIR"
    _unmount_pivot_vfs "$PIVOT_DIR"

    # Build the installer initramfs to a RAM path that is NOT the disk we are
    # about to repartition and NOT inside PIVOT_DIR (which we cpio). /dev/shm and
    # /run are tmpfs on the source OS. kexec -l copies the image into reserved
    # kernel memory immediately, so it only needs to exist at load time.
    local img=/dev/shm/aa-installer.img
    [ -d /dev/shm ] || img=/run/aa-installer.img
    _pack_installer_img "$PIVOT_DIR" "$img"

    # Serial console too: cloud servers are headless, so the installer's progress
    # (and the init.aa boot-guard later) must reach the provider serial console.
    local cmdline="console=tty1 console=ttyS0,115200n8 panic=10"

    log_info "Loading installer kernel via kexec..."
    run_privileged "$kexec_bin" -l "$kimg" --initrd="$img" --command-line="$cmdline" \
        || die "kexec -l failed (kernel not kexec-loadable?); system UNCHANGED and still reachable"
    local loaded
    loaded=$(cat /sys/kernel/kexec_loaded 2>/dev/null || echo 0)
    [ "$loaded" = "1" ] \
        || die "kexec load did not stick (kexec_loaded=$loaded); system UNCHANGED and still reachable"
    log_info "Installer kernel loaded (kexec_loaded=1)"

    log_warn "kexec-ing into the RAM installer now - the connection WILL be lost."
    log_warn "The install runs on the freed disk, then reboots into the new system."
    log_warn "Reconnect after it completes: ssh root@${DETECTED_IP_ADDRESS}"
    run_privileged sync
    # Detach so a dropped SSH session can't SIGHUP the reboot mid-flight.
    run_privileged sh -c "nohup sh -c 'sleep 2; ${kexec_bin} -e' >/dev/null 2>&1 &" || true
    sleep 3
}

# Strategy for runit
pivot_runit() {
    # Only reachable in LIVE mode on a runit PID 1 (INSTALL mode always kexecs,
    # see _pivot_takeover_or_kexec). runit re-exec is not implemented here and
    # was never validated, so fail BEFORE stopping any service rather than tear
    # the host's services down and then exec a payload that does not exist (which
    # left the box degraded). Install mode works on runit hosts; live mode does
    # not.
    die "live-mode pivot is not supported on a runit init; use --install (kexec RAM installer) instead"
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

# In LIVE mode the in-place bind-mount takeover is correct: it pivots to Alpine
# in RAM, never touches the disk, and reverts on the next reboot. In INSTALL mode
# that same takeover is fatal on systemd/sysvinit/runit: PID 1 keeps the original
# root mounted, so the boot disk stays busy and cannot be repartitioned. There we
# kexec into a RAM installer instead (fresh kernel, disk free). $1 is the
# live-mode takeover function to use for this init system.
_pivot_takeover_or_kexec() {
    if [ "${INSTALL_MODE:-false}" = "true" ]; then
        pivot_kexec_installer
    else
        "$1"
    fi
}

execute_pivot() {
    log_step "Executing pivot_root..."

    local init_system
    init_system=$(detect_init_system)

    log_info "Detected init system: $init_system"

    case "$init_system" in
        systemd)
            _pivot_takeover_or_kexec pivot_systemd
            ;;
        sysvinit)
            _pivot_takeover_or_kexec pivot_sysvinit
            ;;
        busybox)
            # busybox init can't be re-exec'd at runtime -> reboot into a RAM installer
            pivot_reboot_installer
            ;;
        runit)
            _pivot_takeover_or_kexec pivot_runit
            ;;
        openrc)
            # Alpine's OpenRC runs on top of busybox init (PID 1)
            pivot_reboot_installer
            ;;
        s6)
            # s6 frees the disk in place (it reaps services before partitioning),
            # so it works for install without a kexec.
            pivot_s6
            ;;
        *)
            log_warn "Unknown init system, trying direct approach"
            _pivot_takeover_or_kexec pivot_direct
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

# Download minirootfs if needed. The minirootfs is the root of the entire image
# build, so it must pass the same fail-closed integrity check as every other
# download (a compromised mirror here trojans the whole exit). Verify before it
# lands in the cache, where build_system_image would otherwise extract it blind.
download_minirootfs() {
    local url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${DETECTED_ARCH}.tar.gz"
    local dest="${INSTALL_CACHE_DIR}/minirootfs.tar.gz"

    log_info "Downloading Alpine minirootfs..."
    http_fetch_file "$url" "$dest" || die "Failed to download minirootfs: $url"
    enforce_integrity "$url" "$dest"
}
