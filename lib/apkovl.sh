#!/bin/sh
# apkovl.sh - Alpine overlay (apkovl) generation for alpine-anywhere

# =============================================================================
# apkovl Directory Structure
# =============================================================================

# Create apkovl directory structure
create_apkovl_structure() {
    apkovl_dir="$1"

    mkdir -p "$apkovl_dir/etc/network" \
             "$apkovl_dir/etc/apk" \
             "$apkovl_dir/etc/runlevels/boot" \
             "$apkovl_dir/etc/runlevels/default" \
             "$apkovl_dir/etc/runlevels/sysinit" \
             "$apkovl_dir/etc/local.d" \
             "$apkovl_dir/root/.ssh"

    # SSH directory based on mode
    if [ "$HARDENED_MODE" = "true" ]; then
        mkdir -p "$apkovl_dir"/etc/dropbear
    else
        mkdir -p "$apkovl_dir"/etc/ssh
    fi

    # Set proper permissions
    chmod 755 "$apkovl_dir"/etc
    chmod 700 "$apkovl_dir"/root
    chmod 700 "$apkovl_dir"/root/.ssh
}

# =============================================================================
# File Generation Functions
# =============================================================================

# Generate /etc/passwd
generate_passwd() {
    cat <<'EOF'
root:x:0:0:root:/root:/bin/ash
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
nobody:x:65534:65534:nobody:/:/sbin/nologin
sshd:x:22:22:sshd:/var/empty:/sbin/nologin
EOF
}

# Generate /etc/shadow (root without password, key auth only)
generate_shadow() {
    cat <<'EOF'
root:*:19000:0:99999:7:::
bin:*:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
sshd:!:19000:0:99999:7:::
EOF
}

# Generate /etc/group
generate_group() {
    cat <<'EOF'
root:x:0:root
bin:x:1:root,bin,daemon
daemon:x:2:root,bin,daemon
sys:x:3:root,bin
wheel:x:10:root
sshd:x:22:
shadow:x:42:
nogroup:x:65534:
EOF
}

# Generate /etc/apk/world
generate_apk_world() {
    packages="alpine-base"

    # SSH package based on mode
    if [ "$HARDENED_MODE" = "true" ]; then
        packages="$packages dropbear"
    else
        packages="$packages openssh-server"
    fi

    # Add kexec-tools for potential reboot back
    packages="$packages kexec-tools"

    # Add extra packages if specified
    if [ -n "$EXTRA_PACKAGES" ]; then
        extra=$(echo "$EXTRA_PACKAGES" | tr ',' ' ')
        packages="$packages $extra"
    fi

    echo "$packages" | tr ' ' '\n'
}

# Generate /etc/apk/repositories
generate_apk_repositories() {
    cat <<EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF
}

# Generate /etc/ssh/sshd_config
generate_sshd_config() {
    cat <<'EOF'
# Alpine-anywhere generated sshd_config
Port 22
Protocol 2
EOF
    # Hardened: ed25519 host key only (drop the weaker RSA/ECDSA). Non-hardened
    # keeps RSA + ed25519 for client compatibility.
    if [ "$HARDENED_MODE" = "true" ]; then
        echo "HostKey /etc/ssh/ssh_host_ed25519_key"
    else
        echo "HostKey /etc/ssh/ssh_host_rsa_key"
        echo "HostKey /etc/ssh/ssh_host_ed25519_key"
    fi
    cat <<'EOF'

PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no

UsePAM no
PrintMotd no

Subsystem sftp /usr/lib/ssh/sftp-server
EOF
}

# Generate /etc/local.d/alpine-anywhere.start
# This script generates SSH host keys on first boot
generate_local_start() {
    if [ "$HARDENED_MODE" = "true" ]; then
        cat <<'EOF'
#!/bin/sh
# Generate dropbear host keys if they don't exist
mkdir -p /etc/dropbear
if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
    echo "Generating dropbear host keys..."
    dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
fi

# Ensure permissions are correct
chmod 600 /etc/dropbear/dropbear_*_host_key 2>/dev/null || true

# Log successful boot
echo "alpine-anywhere: Boot completed at $(date) (hardened mode)" >> /var/log/messages
EOF
    else
        cat <<'EOF'
#!/bin/sh
# Generate SSH host keys if they don't exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
fi

# Ensure permissions are correct
chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true

# Log successful boot
echo "alpine-anywhere: Boot completed at $(date)" >> /var/log/messages
EOF
    fi
}

# =============================================================================
# apkovl Assembly
# =============================================================================

# Generate complete apkovl
generate_apkovl() {
    ssh_keys="$1"
    apkovl_dir="${WORK_DIR}/apkovl"
    apkovl_file="${WORK_DIR}/${DETECTED_HOSTNAME}.apkovl.tar.gz"

    log_step "Generating apkovl overlay..."

    # Create directory structure
    create_apkovl_structure "$apkovl_dir"

    # Generate network configuration
    log_debug "Generating network configuration..."
    generate_interfaces_config > "$apkovl_dir/etc/network/interfaces"
    generate_resolv_conf > "$apkovl_dir/etc/resolv.conf"

    # Generate hostname
    echo "$DETECTED_HOSTNAME" > "$apkovl_dir/etc/hostname"

    # Generate user files
    log_debug "Generating user configuration..."
    generate_passwd > "$apkovl_dir/etc/passwd"
    generate_shadow > "$apkovl_dir/etc/shadow"
    generate_group > "$apkovl_dir/etc/group"

    # Set proper permissions on shadow
    chmod 640 "$apkovl_dir/etc/shadow"

    # Generate APK configuration
    log_debug "Generating APK configuration..."
    generate_apk_world > "$apkovl_dir/etc/apk/world"
    generate_apk_repositories > "$apkovl_dir/etc/apk/repositories"

    # Generate SSH configuration
    log_debug "Generating SSH configuration..."
    if [ "$HARDENED_MODE" = "true" ]; then
        # Dropbear uses command-line options, no config file needed
        log_debug "Using dropbear (no config file)"
    else
        generate_sshd_config > "$apkovl_dir/etc/ssh/sshd_config"
    fi

    # Install SSH authorized keys
    if [ -n "$ssh_keys" ]; then
        echo "$ssh_keys" > "$apkovl_dir/root/.ssh/authorized_keys"
        chmod 600 "$apkovl_dir/root/.ssh/authorized_keys"
    fi

    # Generate local startup script
    generate_local_start > "$apkovl_dir/etc/local.d/alpine-anywhere.start"
    chmod 755 "$apkovl_dir/etc/local.d/alpine-anywhere.start"

    # Create runlevel symlinks
    log_debug "Creating runlevel symlinks..."

    # Boot runlevel
    ln -sf /etc/init.d/networking "$apkovl_dir/etc/runlevels/boot/networking"
    ln -sf /etc/init.d/hostname "$apkovl_dir/etc/runlevels/boot/hostname"

    # Default runlevel - SSH service based on mode
    if [ "$HARDENED_MODE" = "true" ]; then
        ln -sf /etc/init.d/dropbear "$apkovl_dir/etc/runlevels/default/dropbear"
    else
        ln -sf /etc/init.d/sshd "$apkovl_dir/etc/runlevels/default/sshd"
    fi
    ln -sf /etc/init.d/local "$apkovl_dir/etc/runlevels/default/local"

    # Sysinit runlevel
    ln -sf /etc/init.d/modloop "$apkovl_dir/etc/runlevels/sysinit/modloop"

    # Create tarball
    log_debug "Creating apkovl tarball..."
    (cd "$apkovl_dir" && tar -czf "$apkovl_file" .)

    if [ ! -f "$apkovl_file" ]; then
        die "Failed to create apkovl tarball"
    fi

    log_info "Generated apkovl: $(basename "$apkovl_file") ($(du -h "$apkovl_file" | cut -f1))"
    echo "$apkovl_file"
}

# =============================================================================
# apkovl Inspection (for debugging)
# =============================================================================

# List contents of apkovl
inspect_apkovl() {
    apkovl_file="$1"

    if [ ! -f "$apkovl_file" ]; then
        die "apkovl file not found: $apkovl_file"
    fi

    echo "Contents of $(basename "$apkovl_file"):"
    tar -tzvf "$apkovl_file"
}

# Show apkovl summary
show_apkovl_summary() {
    apkovl_dir="${WORK_DIR}/apkovl"

    echo ""
    echo "apkovl Configuration Summary:"
    echo "=============================="
    echo ""
    echo "Network interfaces:"
    echo "-------------------"
    cat "$apkovl_dir/etc/network/interfaces"
    echo ""
    echo "DNS resolvers:"
    echo "--------------"
    cat "$apkovl_dir/etc/resolv.conf"
    echo ""
    echo "APK packages:"
    echo "-------------"
    cat "$apkovl_dir/etc/apk/world"
    echo ""
}
