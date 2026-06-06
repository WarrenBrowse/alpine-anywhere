#!/bin/bash
# hardening.sh - Security hardening for alpine-anywhere
#
# Implements security best practices for a hardened Alpine system:
# - dropbear instead of openssh (smaller attack surface)
# - linux-hardened kernel (KSPP, additional mitigations)
# - Network stack hardening (sysctl)
# - Kernel lockdown mode
# - hardened_malloc (hardened memory allocator)
# - Minimal packages (reduced attack surface)

# =============================================================================
# Hardening Configuration
# =============================================================================

HARDENED_MODE="${HARDENED_MODE:-false}"

# Packages for hardened mode
HARDENED_PACKAGES=(
    "linux-hardened"           # Hardened kernel with KSPP
    "dropbear"                 # Minimal SSH server
    "dropbear-openrc"          # OpenRC integration
    "hardened-malloc"          # Hardened memory allocator
    "iptables"                 # Firewall
    "ip6tables"                # IPv6 firewall
    "nftables"                 # Modern firewall (alternative)
    "chrony"                   # Secure NTP (instead of openntpd)
    "ca-certificates"          # TLS certificates
    "wireguard-tools"          # VPN (if needed)
)

# Packages to explicitly NOT install in hardened mode
HARDENED_EXCLUDE_PACKAGES=(
    "openssh-server"           # Use dropbear instead
    "openssh-client"           # Minimal client if needed
    "sudo"                     # Use doas instead
    "linux-lts"                # Use linux-hardened instead
    "linux-virt"               # Use linux-hardened instead
)

# =============================================================================
# Kernel Hardening (linux-hardened features)
# =============================================================================

# linux-hardened includes:
# - KSPP (Kernel Self Protection Project) options
# - ASLR improvements
# - Restricted /dev/mem and /dev/kmem
# - Disabled kexec_load (we handle this specially)
# - YAMA LSM enabled
# - Restricted dmesg
# - Restricted kernel pointers
# - Stack protector strong
# - Hardened usercopy
# - Randomized kernel stack offset

# Additional kernel command line parameters for hardening
generate_hardened_cmdline() {
    local cmdline=""

    # Kernel lockdown mode (integrity or confidentiality)
    cmdline+="lockdown=integrity "

    # Disable kernel module loading after boot (optional, strict)
    # cmdline+="modules.sig_enforce=1 "

    # IOMMU for DMA protection
    cmdline+="iommu=force "
    cmdline+="intel_iommu=on "
    cmdline+="amd_iommu=on "

    # Disable USB (if not needed)
    # cmdline+="nousb "

    # Restrict kernel pointers in logs
    cmdline+="kptr_restrict=2 "

    # Disable legacy vsyscall
    cmdline+="vsyscall=none "

    # Panic on oops
    cmdline+="oops=panic "

    # SLUB hardening
    cmdline+="slub_debug=FZP "
    cmdline+="init_on_alloc=1 "
    cmdline+="init_on_free=1 "

    # Page allocation randomization
    cmdline+="page_alloc.shuffle=1 "

    # Disable slab merging
    cmdline+="slab_nomerge "

    # Randomize kernel page tables
    cmdline+="randomize_kstack_offset=on "

    # Mitigate speculative execution attacks
    cmdline+="spectre_v2=on "
    cmdline+="spec_store_bypass_disable=on "
    cmdline+="l1tf=full,force "
    cmdline+="mds=full,nosmt "

    # Disable dangerous kernel features
    cmdline+="debugfs=off "

    echo "$cmdline"
}

# =============================================================================
# Network Stack Hardening (sysctl)
# =============================================================================

generate_sysctl_hardening() {
    cat << 'EOF'
# =============================================================================
# Alpine Anywhere - Network Stack Hardening
# =============================================================================

# --- IP Stack ---

# Disable IP forwarding (enable only if router/VPN)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Enable reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Log Martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# --- TCP Hardening ---

# Enable SYN cookies (SYN flood protection)
net.ipv4.tcp_syncookies = 1

# Increase SYN backlog
net.ipv4.tcp_max_syn_backlog = 4096

# Decrease SYN-ACK retries
net.ipv4.tcp_synack_retries = 2

# Enable RFC 1337 (TIME-WAIT assassination protection)
net.ipv4.tcp_rfc1337 = 1

# Disable TCP timestamps (information leak)
net.ipv4.tcp_timestamps = 0

# Disable TCP SACK (if not needed, reduces attack surface)
# net.ipv4.tcp_sack = 0

# --- Memory Protection ---

# Restrict dmesg to root
kernel.dmesg_restrict = 1

# Restrict kernel pointers
kernel.kptr_restrict = 2

# Restrict perf events
kernel.perf_event_paranoid = 3

# Disable kexec (we handle this at boot)
kernel.kexec_load_disabled = 1

# Enable ASLR
kernel.randomize_va_space = 2

# Restrict ptrace
kernel.yama.ptrace_scope = 2

# Disable magic SysRq key
kernel.sysrq = 0

# Restrict unprivileged BPF
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Restrict unprivileged user namespaces
kernel.unprivileged_userns_clone = 0

# --- File System ---

# Protect hardlinks and symlinks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# Disable core dumps
fs.suid_dumpable = 0

EOF
}

# =============================================================================
# Dropbear Configuration
# =============================================================================

generate_dropbear_config() {
    # Dropbear uses command-line options, not config file
    # We create a wrapper script
    cat << 'EOF'
#!/bin/sh
# Dropbear startup configuration

DROPBEAR_OPTS=""

# Disable password authentication (key only)
DROPBEAR_OPTS="$DROPBEAR_OPTS -s"

# Disable root password login (key only)
DROPBEAR_OPTS="$DROPBEAR_OPTS -g"

# Use specific port
DROPBEAR_OPTS="$DROPBEAR_OPTS -p 22"

# Disable local port forwarding
# DROPBEAR_OPTS="$DROPBEAR_OPTS -j"

# Disable remote port forwarding
# DROPBEAR_OPTS="$DROPBEAR_OPTS -k"

# Idle timeout (5 minutes)
DROPBEAR_OPTS="$DROPBEAR_OPTS -I 300"

# Max auth attempts
DROPBEAR_OPTS="$DROPBEAR_OPTS -T 3"

exec /usr/sbin/dropbear $DROPBEAR_OPTS -F
EOF
}

# Generate dropbear OpenRC config
generate_dropbear_confd() {
    cat << 'EOF'
# Dropbear SSH configuration

# Disable password authentication (key-only)
DROPBEAR_OPTS="-s -g"

# Port
DROPBEAR_PORT="22"

# Idle timeout (seconds)
DROPBEAR_IDLE_TIMEOUT="300"

# Max auth attempts
DROPBEAR_MAX_AUTH_ATTEMPTS="3"
EOF
}

# =============================================================================
# hardened_malloc Configuration
# =============================================================================

generate_hardened_malloc_config() {
    cat << 'EOF'
# hardened_malloc configuration
# Preload hardened_malloc for all processes

# Enable globally via /etc/ld.so.preload
/usr/lib/libhardened_malloc.so
EOF
}

# Alternative: per-service configuration
generate_malloc_wrapper() {
    cat << 'EOF'
#!/bin/sh
# Wrapper to run command with hardened_malloc
export LD_PRELOAD=/usr/lib/libhardened_malloc.so
exec "$@"
EOF
}

# =============================================================================
# Firewall Rules (nftables)
# =============================================================================

generate_nftables_config() {
    local ssh_port="${1:-22}"
    local vpn_port="${2:-51820}"  # WireGuard default

    cat << EOF
#!/usr/sbin/nft -f
# Alpine Anywhere - Hardened Firewall

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Allow established/related
        ct state established,related accept

        # Drop invalid
        ct state invalid drop

        # Allow loopback
        iif "lo" accept

        # Allow ICMP (rate limited)
        ip protocol icmp icmp type echo-request limit rate 5/second accept
        ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate 5/second accept

        # Allow SSH (rate limited)
        tcp dport ${ssh_port} ct state new limit rate 10/minute accept

        # Allow VPN (WireGuard)
        udp dport ${vpn_port} accept

        # Log dropped packets (rate limited)
        limit rate 5/minute log prefix "nftables-dropped: " level warn
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # Allow VPN forwarding (if configured as VPN server)
        # iifname "wg0" accept
        # oifname "wg0" accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
}

# =============================================================================
# Security Audit Script
# =============================================================================

generate_security_audit() {
    cat << 'EOF'
#!/bin/sh
# Alpine Anywhere - Security Audit Script

echo "=== Security Audit ==="
echo ""

echo "--- Kernel ---"
echo "Kernel: $(uname -r)"
echo "Lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'N/A')"
echo ""

echo "--- Memory ---"
echo "ASLR: $(cat /proc/sys/kernel/randomize_va_space)"
echo "hardened_malloc: $(grep -q hardened_malloc /etc/ld.so.preload 2>/dev/null && echo 'enabled' || echo 'disabled')"
echo ""

echo "--- Network ---"
echo "IP Forward: $(cat /proc/sys/net/ipv4/ip_forward)"
echo "SYN Cookies: $(cat /proc/sys/net/ipv4/tcp_syncookies)"
echo "RP Filter: $(cat /proc/sys/net/ipv4/conf/all/rp_filter)"
echo ""

echo "--- Services ---"
echo "SSH: $(rc-service dropbear status 2>/dev/null || rc-service sshd status 2>/dev/null)"
echo "Firewall: $(rc-service nftables status 2>/dev/null || echo 'N/A')"
echo ""

echo "--- Open Ports ---"
ss -tlnp 2>/dev/null || netstat -tlnp
echo ""

echo "--- Users ---"
echo "Root login: $(grep -q 'PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null && grep 'PermitRootLogin' /etc/ssh/sshd_config || echo 'dropbear -s -g')"
echo ""

echo "=== End Audit ==="
EOF
}

# =============================================================================
# Apply Hardening to System Image
# =============================================================================

apply_hardening_to_image() {
    local root="$1"

    log_info "Applying security hardening..."

    # 1. Sysctl hardening
    log_info "Configuring sysctl hardening..."
    mkdir -p "${root}/etc/sysctl.d"
    generate_sysctl_hardening > "${root}/etc/sysctl.d/99-hardening.conf"

    # 2. Dropbear configuration
    log_info "Configuring dropbear..."
    mkdir -p "${root}/etc/conf.d"
    generate_dropbear_confd > "${root}/etc/conf.d/dropbear"

    # 3. hardened_malloc
    log_info "Enabling hardened_malloc..."
    generate_hardened_malloc_config > "${root}/etc/ld.so.preload"

    # 4. Firewall rules
    log_info "Configuring firewall..."
    mkdir -p "${root}/etc/nftables.d"
    generate_nftables_config > "${root}/etc/nftables.d/hardened.nft"
    ln -sf /etc/nftables.d/hardened.nft "${root}/etc/nftables.conf"

    # 5. Security audit script
    log_info "Installing security audit tool..."
    generate_security_audit > "${root}/usr/local/bin/security-audit"
    chmod +x "${root}/usr/local/bin/security-audit"

    # 6. Disable unnecessary services
    log_info "Disabling unnecessary services..."
    # Remove any default services we don't need
    rm -f "${root}/etc/runlevels/default/sshd" 2>/dev/null || true

    # 7. Enable hardened services
    chroot "$root" /sbin/rc-update add dropbear default 2>/dev/null || true
    chroot "$root" /sbin/rc-update add nftables boot 2>/dev/null || true
    chroot "$root" /sbin/rc-update add sysctl boot 2>/dev/null || true

    # 8. Secure permissions
    log_info "Setting secure permissions..."
    chmod 700 "${root}/root"
    chmod 600 "${root}/etc/shadow" 2>/dev/null || true

    # 9. Remove unnecessary files
    rm -rf "${root}/usr/share/doc" 2>/dev/null || true
    rm -rf "${root}/usr/share/man" 2>/dev/null || true

    log_info "Hardening applied"
}

# =============================================================================
# Get Hardened Packages List
# =============================================================================

get_hardened_packages() {
    local packages=""

    for pkg in "${HARDENED_PACKAGES[@]}"; do
        packages+="$pkg "
    done

    echo "$packages"
}

get_hardened_kernel() {
    echo "linux-hardened"
}

# =============================================================================
# VPN Server Specific Hardening
# =============================================================================

configure_vpn_server() {
    local root="$1"
    local interface="${2:-wg0}"

    log_info "Configuring VPN server hardening..."

    # Enable IP forwarding for VPN
    cat >> "${root}/etc/sysctl.d/99-hardening.conf" << EOF

# VPN Server - Enable forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

    # WireGuard-specific settings
    mkdir -p "${root}/etc/wireguard"
    chmod 700 "${root}/etc/wireguard"

    # No-log configuration
    cat > "${root}/etc/wireguard/README" << 'EOF'
# WireGuard VPN - No-Log Configuration
#
# This server is configured for privacy:
# - No connection logging
# - No IP address logging
# - Minimal system logs
#
# Generate keys with: wg genkey | tee privatekey | wg pubkey > publickey
EOF

    # Disable most logging for no-log VPN
    cat > "${root}/etc/conf.d/syslog" << 'EOF'
# Minimal logging for no-log VPN server
SYSLOGD_OPTS="-l 3"
EOF

    log_info "VPN server hardening applied"
}
