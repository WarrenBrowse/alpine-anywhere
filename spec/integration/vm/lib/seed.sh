#!/bin/sh
# seed.sh - Build the disposable seed VM (a stock provider-style Linux) that
# alpine-anywhere converts onto a separate target disk.
#
# Default seed: a Debian "genericcloud" qcow2. This matters: alpine-anywhere's
# reboot-into-RAM-installer stages installer.img onto *partition 1 of the running
# root disk* (lib/pivot.sh), so the seed must have a normal PARTITIONED disk like
# a real provider image. (An Alpine "nocloud" image puts root on the whole
# unpartitioned device, which has no partition 1 and breaks the staging.) Debian
# genericcloud is GPT with vda1 = root - exactly a real provider's shape. Override
# AA_VM_SEED_URL to point at another partitioned cloud qcow2.
#
# Relies on globals: VM_WORKDIR, VM_SSH_KEY (+ .pub), VM_DISK_GB, AA_VM_*

# Print the seed image URL (explicit override, else the Debian genericcloud).
seed_resolve_url() {
    if [ -n "${AA_VM_SEED_URL:-}" ]; then
        printf '%s\n' "$AA_VM_SEED_URL"; return 0
    fi
    printf '%s\n' "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
}

# seed_fetch -> echoes the path of the cached base qcow2.
seed_fetch() {
    local url base dest
    url="$(seed_resolve_url)" || return 1
    base="$(basename "$url")"
    dest="${AA_VM_CACHE:-$VM_WORKDIR}/$base"
    if [ ! -s "$dest" ]; then
        log "fetching seed image: $url"
        curl -fSL --retry 3 -o "${dest}.part" "$url" || { err "seed download failed"; return 1; }
        mv -f "${dest}.part" "$dest"
    else
        log "seed image cached: $dest"
    fi
    printf '%s\n' "$dest"
}

# seed_make_overlay BASE -> echoes the path of a fresh qcow2 overlay (resized),
# so the immutable base is never mutated and reruns start clean.
seed_make_overlay() {
    local base="$1" overlay="${VM_WORKDIR}/disk.qcow2"
    qemu-img create -f qcow2 -F qcow2 -b "$base" "$overlay" >/dev/null \
        || { err "qemu-img overlay create failed"; return 1; }
    qemu-img resize "$overlay" "${VM_DISK_GB}G" >/dev/null \
        || { err "qemu-img resize failed"; return 1; }
    printf '%s\n' "$overlay"
}

# seed_make_blank -> echoes the path of a fresh blank qcow2: the install target
# (vdb). It is unpartitioned and unmounted, so alpine-anywhere repartitions it
# cleanly with no busy-disk loop fallback.
seed_make_blank() {
    local out="${VM_WORKDIR}/target.qcow2"
    qemu-img create -f qcow2 "$out" "${VM_DISK_GB}G" >/dev/null \
        || { err "qemu-img blank target create failed"; return 1; }
    printf '%s\n' "$out"
}

# seed_make_cidata -> echoes the path of a NoCloud seed ISO that injects our
# test key into root and permits root key-auth. Build tools are installed by the
# harness over SSH afterwards (deterministic, easy to debug) rather than here.
seed_make_cidata() {
    local out="${VM_WORKDIR}/cidata.iso" pub
    pub="$(cat "${VM_SSH_KEY}.pub")"

    cat > "${VM_WORKDIR}/meta-data" <<EOF
instance-id: aa-vm
local-hostname: aa-seed
EOF
    # Native ssh_authorized_keys injects the key reliably, but Alpine's cloud
    # image ships root LOCKED ('root:!*' in /etc/shadow). With UsePAM off, OpenSSH
    # treats a locked account as an invalid user and refuses key auth outright
    # (sshd logs "userauth_pubkey: invalid user root ... disabled"), no matter what
    # PermitRootLogin says. So the baked script unlocks root (PasswordAuthentication
    # stays off, so no password login is opened) and ensures PermitRootLogin allows
    # keys, then restarts sshd.
    #
    # The header is an interpolating heredoc (needs ${pub}); the guest script is a
    # QUOTED heredoc so the harness's `set -u` never tries to expand the guest-side
    # `$f` (an unset var there silently truncated the whole user-data to 0 bytes).
    {
        cat <<EOF
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - ${pub}
ssh_authorized_keys:
  - ${pub}
write_files:
  - path: /root/aa-prep-ssh.sh
    permissions: '0755'
    content: |
EOF
        cat <<'SCRIPT'
      #!/bin/sh
      # Unlock root so OpenSSH stops treating it as an invalid (locked) user.
      echo 'root:alpine-anywhere-test' | chpasswd 2>/dev/null \
        || sed -i '/^root:/ s/^root:[^:]*:/root::/' /etc/shadow
      # Ensure root key auth is permitted in the main config and any drop-in.
      for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [ -e "$f" ] || continue
        sed -i 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$f"
      done
      grep -rq '^PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
        || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
      # Restart sshd across init systems (Debian: ssh, Alpine: sshd, systemd/OpenRC).
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null \
        || rc-service sshd restart 2>/dev/null || service ssh restart 2>/dev/null \
        || service sshd restart 2>/dev/null || true
SCRIPT
        cat <<'EOF'
runcmd:
  - [ sh, /root/aa-prep-ssh.sh ]
EOF
    } > "${VM_WORKDIR}/user-data"

    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$out" "${VM_WORKDIR}/user-data" "${VM_WORKDIR}/meta-data" \
            || { err "cloud-localds failed"; return 1; }
    else
        # Label MUST be cidata/CIDATA for the NoCloud datasource to pick it up.
        local iso_tool=""
        for t in genisoimage mkisofs xorrisofs; do
            command -v "$t" >/dev/null 2>&1 && { iso_tool="$t"; break; }
        done
        [ -n "$iso_tool" ] || { err "need cloud-localds OR genisoimage/mkisofs/xorrisofs to build the NoCloud seed"; return 1; }
        "$iso_tool" -output "$out" -volid cidata -joliet -rock \
            "${VM_WORKDIR}/user-data" "${VM_WORKDIR}/meta-data" >/dev/null 2>&1 \
            || { err "$iso_tool failed building cidata.iso"; return 1; }
    fi
    printf '%s\n' "$out"
}

# seed_prepare_source_host - install the documented build prerequisites on the
# running seed OS (parted/mksquashfs/tar/mkfs.ext4 + curl). Best-effort apk; the
# preflight assertion below is what actually gates.
seed_prepare_source_host() {
    log "preparing source host (apk add build prerequisites)"
    # Retry: when sshd first answers, cloud-init may still be running its final
    # stage and holding the apk lock (or the network is not fully up), so the
    # first apk can fail transiently.
    # Distro-aware: Debian/Ubuntu use apt, Alpine uses apk. Retry because a fresh
    # cloud boot may still be holding the package lock / settling the network.
    local attempt=1 max=6
    while [ "$attempt" -le "$max" ]; do
        if vm_ssh 'if command -v apt-get >/dev/null 2>&1; then \
                       export DEBIAN_FRONTEND=noninteractive; \
                       apt-get update >/dev/null 2>&1 && \
                       apt-get install -y parted squashfs-tools dosfstools e2fsprogs curl >/dev/null 2>&1; \
                   else \
                       apk update >/dev/null 2>&1 && \
                       apk add --no-cache parted squashfs-tools dosfstools e2fsprogs tar curl wget >/dev/null 2>&1; \
                   fi'; then
            break
        fi
        warn "build-prereq install attempt ${attempt}/${max} failed; retrying in 10s (seed still settling)"
        sleep 10
        attempt=$((attempt + 1))
    done
    local missing=""
    for c in parted mksquashfs tar mkfs.ext4; do
        vm_ssh "command -v $c >/dev/null 2>&1" 2>/dev/null || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        err "source host missing build tools:$missing"
        return 1
    fi
    return 0
}

# seed_make_custom_script -> path of a --custom-script for the install. This is
# the same build-time hook aadeploy uses in prod to configure the exit, and here
# it sets a name-agnostic eth0 DHCP network on the installed image. alpine-anywhere
# bakes the SOURCE interface name verbatim; the Debian seed's NIC is the systemd
# "predictable" name enp0s5, which does not exist on the installed Alpine (eth0),
# so without this the converted box would have no network. (Real provider sources
# typically already use eth0; normalising the captured interface name is a possible
# alpine-anywhere improvement, tracked separately - not masked here, just set the
# way aadeploy sets it.)
seed_make_custom_script() {
    local out="${VM_WORKDIR}/aa-custom-script.sh"
    cat > "$out" <<'SCRIPT'
#!/bin/sh
# Runs inside the image chroot at build time. Set a name-agnostic eth0 network.
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF
SCRIPT
    chmod +x "$out"
    printf '%s\n' "$out"
}
