#!/bin/sh
# init_s6.sh - Set up s6-linux-init + s6-rc as the init system (replaces OpenRC)
#
# Produces, inside the image root:
#   /etc/s6-rc/source/*        service definitions + the `default` bundle
#   /etc/s6-rc/compiled        compiled s6-rc database
#   /etc/s6-linux-init/current basedir built by s6-linux-init-maker (bin/init = PID1)
#   /sbin/init -> .../bin/init
#   /usr/local/libexec/aa-s6/* tiny POSIX-sh service helpers
#
# Boot flow: initramfs switch_root -> /sbin/init (s6-linux-init) -> copies basedir
# to /run/s6-linux-init -> scripts/rc.init -> s6-rc-init + s6-rc up `default`.

# Write a oneshot service: name + up-helper path
_s6_oneshot() {
    local src="$1" name="$2" up="$3"
    mkdir -p "${src}/${name}"
    echo oneshot > "${src}/${name}/type"
    printf '%s' "$up" > "${src}/${name}/up"
}

# Write a longrun service: name + execline run body (daemon in foreground)
_s6_longrun() {
    local src="$1" name="$2" runbody="$3"
    mkdir -p "${src}/${name}"
    echo longrun > "${src}/${name}/type"
    printf '#!/bin/execlineb -P\n%s\n' "$runbody" > "${src}/${name}/run"
    chmod +x "${src}/${name}/run"
}

_s6_dep() { mkdir -p "$1/$2/dependencies.d"; touch "$1/$2/dependencies.d/$3"; }

setup_s6_init() {
    local root="$1"
    local src="${root}/etc/s6-rc/source"
    local hd="${root}/usr/local/libexec/aa-s6"

    log_step "Setting up s6 init (s6-linux-init + s6-rc)..."
    rm -rf "$src"; mkdir -p "$src" "$hd"

    # --- service helper scripts (POSIX sh) ---------------------------------
    cat > "${hd}/mounts-up" << 'EOF'
#!/bin/sh
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc
mountpoint -q /sys  2>/dev/null || mount -t sysfs sysfs /sys
mount -o remount,rw / 2>/dev/null || true
# Standard /dev fd symlinks. The kernel devtmpfs + minimal s6 init do not create
# them (OpenRC's devfs service normally does), yet many tools open /dev/stdin etc.
# -- e.g. `nft -f -` opens /dev/stdin and fails "No such file or directory" without
# it, breaking any nftables ruleset load. Needs /proc mounted (done above).
ln -sf /proc/self/fd  /dev/fd     2>/dev/null || true
ln -sf /proc/self/fd/0 /dev/stdin  2>/dev/null || true
ln -sf /proc/self/fd/1 /dev/stdout 2>/dev/null || true
ln -sf /proc/self/fd/2 /dev/stderr 2>/dev/null || true
# Coldplug hardware: load a driver for every present device by modalias, exactly
# like OpenRC's hwdrivers. Without this the minimal s6 image never autoloads the
# NIC driver (ixgbe/igb/tg3/...) and the box comes up with NO network. mdev.conf's
# $MODALIAS->modprobe rule only fires on hotplug uevents, not for hardware already
# present at boot, and nothing else in the s6 path triggers a coldplug.
find /sys -name modalias -type f -print0 2>/dev/null \
    | xargs -0 sort -u 2>/dev/null | xargs modprobe -b -a 2>/dev/null
# Load explicitly-requested modules (/etc/modules + /etc/modules-load.d/*.conf,
# like systemd-modules-load / OpenRC) plus the filesystem drivers needed to mount
# the boot+data partitions. busybox mount only tries filesystems already in
# /proc/filesystems and will NOT autoload a fs module, so an ext4/btrfs partition
# otherwise fails to mount with "Invalid argument".
for mf in /etc/modules /etc/modules-load.d/*.conf; do
    [ -f "$mf" ] || continue
    sed 's/#.*//' "$mf" | while read -r m _; do
        [ -n "$m" ] && modprobe -b "$m" 2>/dev/null || true
    done
done
for m in ext4 vfat btrfs; do modprobe -b "$m" 2>/dev/null || true; done
true
EOF

    # Network helper baked from detected config. The interface NAME is resolved
    # at runtime: the build/detection host may use systemd-predictable names
    # (eno1, ens..) while this Alpine image uses mdev kernel names (eth0..), so a
    # baked name can be wrong. Prefer the detected name if present, else bring
    # all non-lo links up and pick the one with carrier (the cabled port), else
    # the first non-lo. Keeps the box reachable across host/runtime naming.
    cat > "${hd}/network-up" << EOF
#!/bin/sh
# Baked by alpine-anywhere. Configures networking through ifupdown:
# regenerates /etc/network/interfaces from the values below (for this boot's
# resolved interface) then runs ifup. A direct-ip safety net follows so a
# misbehaving/absent ifupdown can never strand a remotely-installed box.
#
# Configurable without rebaking: drop /etc/alpine-anywhere/network.conf
# (same AA_NET_* vars) on a persistent overlay and it is sourced here.
AA_NET_DHCP="${NETWORK_IS_DHCP}"
AA_NET_IF="${DETECTED_INTERFACE}"
AA_NET_V4_ADDR="${DETECTED_IP_ADDRESS}"
AA_NET_V4_NETMASK="${DETECTED_NETMASK}"
AA_NET_V4_GW="${DETECTED_GATEWAY}"
AA_NET_V6_ADDR="${DETECTED_IPV6_ADDRESS}"
AA_NET_V6_CIDR="${DETECTED_IPV6_CIDR}"
AA_NET_V6_GW="${DETECTED_IPV6_GATEWAY}"

[ -r /etc/alpine-anywhere/network.conf ] && . /etc/alpine-anywhere/network.conf

ifconfig lo 127.0.0.1 up 2>/dev/null || true

# Resolve the interface: the baked name may differ from this image's kernel
# naming, so fall back to the carrier-up port, else the first non-lo.
IF="\$AA_NET_IF"
if [ ! -e "/sys/class/net/\$IF" ]; then
    for d in /sys/class/net/*; do b=\${d##*/}; [ "\$b" = lo ] && continue; ifconfig "\$b" up 2>/dev/null || true; done
    sleep 3; IF=""
    for d in /sys/class/net/*; do b=\${d##*/}; [ "\$b" = lo ] && continue; [ "\$(cat \$d/carrier 2>/dev/null)" = 1 ] && { IF="\$b"; break; }; done
    [ -n "\$IF" ] || for d in /sys/class/net/*; do b=\${d##*/}; [ "\$b" = lo ] || { IF="\$b"; break; }; done
fi

# Regenerate /etc/network/interfaces for the resolved interface (v4 + opt v6).
mkdir -p /etc/network
{
    echo "auto lo"
    echo "iface lo inet loopback"
    echo ""
    echo "auto \$IF"
    if [ "\$AA_NET_DHCP" = "true" ]; then
        echo "iface \$IF inet dhcp"
    else
        echo "iface \$IF inet static"
        echo "    address \$AA_NET_V4_ADDR"
        echo "    netmask \$AA_NET_V4_NETMASK"
        echo "    gateway \$AA_NET_V4_GW"
    fi
    if [ -n "\$AA_NET_V6_ADDR" ]; then
        echo ""
        echo "iface \$IF inet6 static"
        echo "    address \$AA_NET_V6_ADDR"
        echo "    netmask \${AA_NET_V6_CIDR:-64}"
        [ -n "\$AA_NET_V6_GW" ] && echo "    gateway \$AA_NET_V6_GW"
    fi
} > /etc/network/interfaces

# Primary path: ifupdown.
if command -v ifup >/dev/null 2>&1; then
    ifup -a 2>/dev/null || ifup "\$IF" 2>/dev/null || true
fi

# Safety net (never lose remote access): if v4 is still unset, apply directly.
if ! ip -4 addr show dev "\$IF" 2>/dev/null | grep -q 'inet '; then
    if [ "\$AA_NET_DHCP" = "true" ]; then
        udhcpc -i "\$IF" -b -q 2>/dev/null || true
    else
        ifconfig "\$IF" "\$AA_NET_V4_ADDR" netmask "\$AA_NET_V4_NETMASK" up 2>/dev/null || true
        route add default gw "\$AA_NET_V4_GW" 2>/dev/null || true
    fi
fi

# IPv6 safety net.
if [ -n "\$AA_NET_V6_ADDR" ] && ! ip -6 addr show dev "\$IF" scope global 2>/dev/null | grep -q inet6; then
    ip -6 addr add "\$AA_NET_V6_ADDR/\${AA_NET_V6_CIDR:-64}" dev "\$IF" 2>/dev/null || true
    [ -n "\$AA_NET_V6_GW" ] && ip -6 route add default via "\$AA_NET_V6_GW" dev "\$IF" 2>/dev/null || true
fi
EOF

    cat > "${hd}/verify" << 'EOF'
#!/bin/sh
/usr/local/bin/aa verify || true
EOF
    cat > "${hd}/nftables-up" << 'EOF'
#!/bin/sh
[ -f /etc/nftables.nft ] && nft -f /etc/nftables.nft 2>/dev/null || true
EOF
    cat > "${hd}/sysctl-up" << 'EOF'
#!/bin/sh
for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
    [ -f "$f" ] && sysctl -p "$f" >/dev/null 2>&1 || true
done
EOF
    # Persistent data: only acts for automatic unlock methods; the default ssh
    # method stays locked until the operator runs aa-unlock.
    cat > "${hd}/mount-data-up" << 'EOF'
#!/bin/sh
[ -x /usr/local/sbin/aa-data ] && /usr/local/sbin/aa-data autoboot || true
EOF
    chmod +x "${hd}"/*

    # --- s6-rc source services --------------------------------------------
    # NOTE: boot-attempt counting is done by the PID 1 shim (/sbin/aa-boot-init),
    # not an s6 service, so it works even if s6 itself fails to come up.
    _s6_oneshot "$src" mounts    "/usr/local/libexec/aa-s6/mounts-up"
    _s6_oneshot "$src" network   "/usr/local/libexec/aa-s6/network-up"
    _s6_oneshot "$src" aa-verify "/usr/local/libexec/aa-s6/verify"

    _s6_dep "$src" network mounts

    local contents="mounts network aa-verify"

    # Persistent data unlock+mount (auto methods) - runs after mounts.
    if [ "$PERSIST_DATA" = "true" ]; then
        _s6_oneshot "$src" mount-data "/usr/local/libexec/aa-s6/mount-data-up"
        _s6_dep "$src" mount-data mounts
        _s6_dep "$src" network mount-data
        contents="$contents mount-data"
    fi

    # SSH daemon (supervised longrun). -s disables all password logins and -g
    # disables password logins for root: key-only auth as defence in depth on an
    # Internet-exposed exit (root's shadow is already '*', so this closes the
    # gap belt-and-suspenders). -F foreground (s6 supervises), -R regenerates a
    # host key only if one is missing (baked keys make this a no-op normally).
    if [ "$HARDENED_MODE" = "true" ]; then
        _s6_longrun "$src" dropbear "/usr/sbin/dropbear -F -R -s -g -p 22"
        _s6_dep "$src" dropbear network
        _s6_dep "$src" aa-verify dropbear
        contents="$contents dropbear"
        # firewall + sysctl
        _s6_oneshot "$src" nftables "/usr/local/libexec/aa-s6/nftables-up"
        _s6_oneshot "$src" sysctl   "/usr/local/libexec/aa-s6/sysctl-up"
        _s6_dep "$src" nftables mounts
        _s6_dep "$src" sysctl mounts
        contents="$contents nftables sysctl"
    else
        _s6_longrun "$src" sshd "/usr/sbin/sshd -D -e"
        _s6_dep "$src" sshd network
        _s6_dep "$src" aa-verify sshd
        contents="$contents sshd"
    fi

    # chronyd (time sync)
    _s6_longrun "$src" chronyd "/usr/sbin/chronyd -d"
    _s6_dep "$src" chronyd network
    contents="$contents chronyd"

    # aa-verify last: also depend on network
    _s6_dep "$src" aa-verify network

    # default bundle
    mkdir -p "${src}/default/contents.d"
    echo bundle > "${src}/default/type"
    local c
    for c in $contents; do touch "${src}/default/contents.d/${c}"; done

    # Custom services declared by --custom-script (the source dir was wiped by
    # the rm -rf above, so these live under /etc/aa/custom-services.d and are
    # slurped in here). Each <name>/ is a raw s6-rc definition (type + run/up +
    # dependencies.d); it is copied verbatim and added to the default bundle.
    if [ -d "${root}/etc/aa/custom-services.d" ]; then
        local svc name
        for svc in "${root}/etc/aa/custom-services.d"/*/; do
            [ -d "$svc" ] || continue
            name=$(basename "$svc")
            rm -rf "${src}/${name}"
            cp -R "$svc" "${src}/${name}"
            touch "${src}/default/contents.d/${name}"
            log_info "Wired custom s6 service: ${name}"
        done
    fi

    # --- compile the database (in chroot so paths/users resolve) -----------
    log_info "Compiling s6-rc database..."
    rm -rf "${root}/etc/s6-rc/compiled"
    chroot "$root" /bin/sh -c 's6-rc-compile /etc/s6-rc/compiled /etc/s6-rc/source' \
        || die "s6-rc-compile failed"

    # --- customise the s6-linux-init skel to drive s6-rc -------------------
    local skel="${root}/etc/s6-linux-init/skel"
    mkdir -p "$skel"
    # rc.init: NOT `set -e` (a failing s6-rc must not abort the whole init).
    # Logs breadcrumbs to the FAT boot partition (sda1) so a failed s6 boot can
    # be diagnosed offline, and brings up an emergency network+dropbear so the
    # box stays reachable even if the s6-rc services fail to come up.
    cat > "${skel}/rc.init" << 'EOF'
#!/bin/sh
rl="$1"; shift
exec >/dev/console 2>&1

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null

# Apply the baked hostname. s6 (unlike OpenRC) has no hostname service, so
# without this the kernel hostname stays "(none)" regardless of /etc/hostname.
[ -s /etc/hostname ] && hostname "$(cat /etc/hostname)" 2>/dev/null

bootdev=$(sed -n 's|.*root=/dev/\([a-z0-9]*\)[0-9].*|/dev/\11|p' /proc/cmdline)
[ -n "$bootdev" ] || bootdev=/dev/sda1
mkdir -p /run/aa-log
mount "$bootdev" /run/aa-log 2>/dev/null
slog() { echo "[s6-rc.init] $*"; echo "[$(cat /proc/uptime 2>/dev/null|cut -d. -f1)] $*" >> /run/aa-log/s6-boot.log 2>/dev/null; sync 2>/dev/null; }

slog "rc.init start rl=$rl"
if s6-rc-init -c /etc/s6-rc/compiled -l /run/s6-rc /run/service; then
    slog "s6-rc-init OK"
else
    slog "s6-rc-init FAILED rc=$?"
fi
up_ok=1
if s6-rc -v2 -l /run/s6-rc -up change "$rl"; then
    slog "s6-rc up '$rl' OK"
else
    up_ok=0
    slog "s6-rc up '$rl' FAILED rc=$?"
fi

# Emergency reachability: only when service bring-up FAILED, so a healthy boot
# does not run a second, unsupervised SSH daemon fighting the supervised one for
# port 22. Key-only (-s -g) here too.
if [ "$up_ok" = 0 ]; then
    ( /usr/local/libexec/aa-s6/network-up 2>/dev/null
      if [ -x /usr/sbin/dropbear ]; then /usr/sbin/dropbear -R -s -g -p 22 2>/dev/null
      else mkdir -p /run/sshd; /usr/sbin/sshd 2>/dev/null; fi ) &
fi

slog "rc.init done"
umount /run/aa-log 2>/dev/null
EOF
    cat > "${skel}/runlevel" << 'EOF'
#!/bin/sh
exec s6-rc -v2 -l /run/s6-rc -up change "$1"
EOF
    chmod +x "${skel}/rc.init" "${skel}/runlevel"

    # --- build the basedir + install as PID 1 ------------------------------
    log_info "Building s6-linux-init basedir..."
    rm -rf "${root}/etc/s6-linux-init/current"
    # CRITICAL: -c is the STATIC basedir where stage 1 reads its read-only data
    # (notably run-image), i.e. the maker's OUTPUT dir = /etc/s6-linux-init/current.
    # It is NOT the runtime live dir. Passing -c /run/s6-linux-init made bin/init
    # do `s6-linux-init -c /run/s6-linux-init`, so at boot it looked for the
    # run-image at /run/s6-linux-init/run-image — which does not exist yet (that's
    # the tmpfs being created) -> fatal "unable to copy run-image to /run: No such
    # file or directory" -> PID 1 dies (the s6 brick). The runtime live dir is
    # /run/s6-linux-init by default and is created by s6-linux-init itself.
    # NOTE: no -d /dev — the Alpine initramfs already mounted devtmpfs on /dev;
    # having s6-linux-init mount a second devtmpfs over it can kill stage 1.
    chroot "$root" /bin/sh -c \
        's6-linux-init-maker -c /etc/s6-linux-init/current -p "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" -m 0022 -1 -f /etc/s6-linux-init/skel /etc/s6-linux-init/current' \
        || die "s6-linux-init-maker failed"

    ln -sf /etc/s6-linux-init/current/bin/init "${root}/sbin/init"

    # Route the standard shutdown commands to s6-linux-init-shutdownd. Alpine's
    # /sbin/{reboot,halt,poweroff} are busybox applets that signal PID 1 — but
    # PID 1 here is s6-svscan, which ignores that signal, so `reboot` is a SILENT
    # NO-OP (the box never reboots: breaks upgrade activation AND auto-rollback).
    # The maker emits working reboot/halt/poweroff/shutdown in the basedir bin;
    # point /sbin at them (fallback: a wrapper around s6-linux-init-hpr).
    for _c in reboot halt poweroff shutdown; do
        if [ -e "${root}/etc/s6-linux-init/current/bin/${_c}" ]; then
            ln -sf "/etc/s6-linux-init/current/bin/${_c}" "${root}/sbin/${_c}"
        else
            case "$_c" in
                reboot)   _f="-r" ;;
                poweroff) _f="-p" ;;
                halt)     _f="-h" ;;
                *)        _f="-r" ;;
            esac
            printf '#!/bin/sh\nexec s6-linux-init-hpr %s "$@"\n' "$_f" > "${root}/sbin/${_c}"
            chmod +x "${root}/sbin/${_c}"
        fi
    done
    log_info "s6 init configured (PID 1 = s6-linux-init, services via s6-rc, shutdown wired)"
}
