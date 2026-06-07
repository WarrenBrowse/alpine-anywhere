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
EOF

    # Network helper baked from detected config
    if [ "$NETWORK_IS_DHCP" = "true" ]; then
        cat > "${hd}/network-up" << EOF
#!/bin/sh
ifconfig lo 127.0.0.1 up 2>/dev/null || true
udhcpc -i "${DETECTED_INTERFACE}" -b -q 2>/dev/null || true
EOF
    else
        cat > "${hd}/network-up" << EOF
#!/bin/sh
ifconfig lo 127.0.0.1 up 2>/dev/null || true
ifconfig "${DETECTED_INTERFACE}" "${DETECTED_IP_ADDRESS}" netmask "${DETECTED_NETMASK}" up 2>/dev/null || true
route add default gw "${DETECTED_GATEWAY}" 2>/dev/null || true
EOF
    fi

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
    chmod +x "${hd}"/*

    # --- s6-rc source services --------------------------------------------
    # NOTE: boot-attempt counting is done by the PID 1 shim (/sbin/aa-boot-init),
    # not an s6 service, so it works even if s6 itself fails to come up.
    _s6_oneshot "$src" mounts    "/usr/local/libexec/aa-s6/mounts-up"
    _s6_oneshot "$src" network   "/usr/local/libexec/aa-s6/network-up"
    _s6_oneshot "$src" aa-verify "/usr/local/libexec/aa-s6/verify"

    _s6_dep "$src" network mounts

    local contents="mounts network aa-verify"

    # SSH daemon (supervised longrun)
    if [ "$HARDENED_MODE" = "true" ]; then
        _s6_longrun "$src" dropbear "/usr/sbin/dropbear -F -R -p 22"
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

bootdev=$(sed -n 's|.*root=/dev/\([a-z0-9]*\)[0-9].*|/dev/\11|p' /proc/cmdline)
[ -n "$bootdev" ] || bootdev=/dev/sda1
mkdir -p /aa-log
mount "$bootdev" /aa-log 2>/dev/null
slog() { echo "[s6-rc.init] $*"; echo "[$(cat /proc/uptime 2>/dev/null|cut -d. -f1)] $*" >> /aa-log/s6-boot.log 2>/dev/null; sync 2>/dev/null; }

slog "rc.init start rl=$rl"
if s6-rc-init -c /etc/s6-rc/compiled -l /run/s6-rc /run/service; then
    slog "s6-rc-init OK"
else
    slog "s6-rc-init FAILED rc=$?"
fi
if s6-rc -v2 -l /run/s6-rc -up change "$rl"; then
    slog "s6-rc up '$rl' OK"
else
    slog "s6-rc up '$rl' FAILED rc=$?"
fi

# Emergency reachability (DEBUG): ensure SSH works even if services failed.
( /usr/local/libexec/aa-s6/network-up 2>/dev/null
  if [ -x /usr/sbin/dropbear ]; then /usr/sbin/dropbear -R -p 22 2>/dev/null
  else mkdir -p /run/sshd; /usr/sbin/sshd 2>/dev/null; fi ) &

slog "rc.init done"
umount /aa-log 2>/dev/null
EOF
    cat > "${skel}/runlevel" << 'EOF'
#!/bin/sh
exec s6-rc -v2 -l /run/s6-rc -up change "$1"
EOF
    chmod +x "${skel}/rc.init" "${skel}/runlevel"

    # --- build the basedir + install as PID 1 ------------------------------
    log_info "Building s6-linux-init basedir..."
    rm -rf "${root}/etc/s6-linux-init/current"
    # NOTE: no -d /dev — the Alpine initramfs already mounted devtmpfs on /dev;
    # having s6-linux-init mount a second devtmpfs over it can kill stage 1
    # (PID 1) before rc.init runs (observed: empty /s6-boot.log, unreachable).
    chroot "$root" /bin/sh -c \
        's6-linux-init-maker -c /run/s6-linux-init -p "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" -m 0022 -1 -f /etc/s6-linux-init/skel /etc/s6-linux-init/current' \
        || die "s6-linux-init-maker failed"

    ln -sf /etc/s6-linux-init/current/bin/init "${root}/sbin/init"
    log_info "s6 init configured (PID 1 = s6-linux-init, services via s6-rc)"
}
