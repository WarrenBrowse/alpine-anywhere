#!/bin/sh
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
# KSPP-aligned hardening safe for a headless cloud-KVM VPN exit. Deliberately
# EXCLUDED, because they are unsafe or costly on this exact target and the kernel
# already mitigates the relevant issues by default:
#   - iommu=force / intel_iommu=on / amd_iommu=on: force an IOMMU that cloud KVM
#     may not expose, which can break virtio DMA and stop the guest booting.
#   - mds=full,nosmt / l1tf=full,force: disable SMT, halving an exit node's
#     throughput; the kernel's default per-CPU mitigations cover these without
#     turning hyperthreading off.
# The excluded set needs real-node validation before it is enabled fleet-wide.
generate_hardened_cmdline() {
    cmdline=""

    # Kernel lockdown: block root-to-ring0 integrity bypasses (module loading of
    # unsigned modules, kexec of unsigned images, direct hardware access, ...).
    cmdline="${cmdline}lockdown=integrity "

    # Restrict kernel pointers in logs (KASLR info leaks).
    cmdline="${cmdline}kptr_restrict=2 "

    # Zero heap and freed pages: kills use-of-uninitialised and use-after-free
    # info leaks at a small, well-understood cost.
    cmdline="${cmdline}init_on_alloc=1 "
    cmdline="${cmdline}init_on_free=1 "

    # SLUB freelist/redzone hardening + no slab merging (defeats cross-cache
    # exploitation) + freelist randomization.
    cmdline="${cmdline}slub_debug=FZP "
    cmdline="${cmdline}slab_nomerge "
    cmdline="${cmdline}page_alloc.shuffle=1 "

    # Randomize the kernel stack offset per syscall.
    cmdline="${cmdline}randomize_kstack_offset=on "

    # Remove legacy attack surface.
    cmdline="${cmdline}vsyscall=none "
    cmdline="${cmdline}debugfs=off "

    # Turn an oops into a panic so PID-1/kernel faults reboot (panic=10 on the
    # baked cmdline) and accumulate toward A/B rollback instead of half-running.
    cmdline="${cmdline}oops=panic "

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

# Disable IP forwarding
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
# Firewall Rules (nftables)
# =============================================================================

# The port argument exists for callers and the spec; in-file call sites
# deliberately take the default.
# shellcheck disable=SC2120
generate_nftables_config() {
    ssh_port="${1:-22}"

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

        # Log dropped packets (rate limited)
        limit rate 5/minute log prefix "nftables-dropped: " level warn
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
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
    root="$1"

    log_info "Applying security hardening..."

    # 0. Install hardening runtime dependencies into the image (the configs
    #    below are useless - or dangerous - without them). Install separately:
    #    apk add is atomic, so bundling an unavailable package (hardened-malloc
    #    is not in Alpine aarch64 repos) would also skip the available ones.
    log_info "Installing firewall (nftables)..."
    chroot "$root" /sbin/apk add --no-cache nftables || log_warn "nftables unavailable"
    log_info "Installing hardened-malloc (if available)..."
    chroot "$root" /sbin/apk add --no-cache hardened-malloc 2>/dev/null \
        || log_warn "hardened-malloc not packaged for this arch; skipping"

    # 1. Sysctl hardening
    log_info "Configuring sysctl hardening..."
    mkdir -p "${root}/etc/sysctl.d"
    generate_sysctl_hardening > "${root}/etc/sysctl.d/99-hardening.conf"

    # 2. Dropbear configuration
    log_info "Configuring dropbear..."
    mkdir -p "${root}/etc/conf.d"
    generate_dropbear_confd > "${root}/etc/conf.d/dropbear"

    # 3. hardened_malloc - ONLY preload if the library is actually present,
    #    using its real path. A dangling /etc/ld.so.preload entry can make
    #    every exec fail (effectively bricking the system).
    local malloc_lib
    malloc_lib=$(chroot "$root" sh -c 'ls /usr/lib/libhardened_malloc*.so 2>/dev/null | head -1')
    if [ -n "$malloc_lib" ]; then
        log_info "Enabling hardened_malloc (${malloc_lib})..."
        echo "$malloc_lib" > "${root}/etc/ld.so.preload"
    else
        log_warn "hardened-malloc not installed; skipping ld.so.preload"
        rm -f "${root}/etc/ld.so.preload"
    fi

    # 4. Firewall rules. Alpine's nftables OpenRC service loads /etc/nftables.nft
    #    by default, so write there (keep a copy under nftables.d for clarity).
    log_info "Configuring firewall..."
    mkdir -p "${root}/etc/nftables.d"
    generate_nftables_config > "${root}/etc/nftables.d/hardened.nft"
    generate_nftables_config > "${root}/etc/nftables.nft"

    # 5. Security audit script
    log_info "Installing security audit tool..."
    generate_security_audit > "${root}/usr/local/bin/security-audit"
    chmod +x "${root}/usr/local/bin/security-audit"

    # 6. Disable unnecessary services
    log_info "Disabling unnecessary services..."
    # Remove any default services we don't need
    rm -f "${root}/etc/runlevels/default/sshd" 2>/dev/null || true

    # 7. Enable hardened services
    # Service enablement is OpenRC-specific; s6 enables these via s6-rc (setup_s6_init)
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        chroot "$root" /sbin/rc-update add dropbear default 2>/dev/null || true
        chroot "$root" /sbin/rc-update add nftables boot 2>/dev/null || true
        chroot "$root" /sbin/rc-update add sysctl boot 2>/dev/null || true
    fi

    # 7b. aa-lockdown: freeze kernel module loading once everything needed is up.
    #     This is the realistic substitute for module signature enforcement -
    #     Alpine kernels are not signed by us, so modules.sig_enforce=1 would
    #     refuse to load ALL modules and is infeasible without a self-built
    #     kernel. Setting kernel.modules_disabled=1 LAST (after net/nftables/
    #     dropbear/dm-verity modules are loaded) blocks any later module load,
    #     closing a major post-exploit persistence/escalation vector.
    log_info "Installing aa-lockdown (kernel.modules_disabled) service..."
    cat > "${root}/etc/init.d/aa-lockdown" << 'EOF'
#!/sbin/openrc-run
description="Alpine Anywhere: freeze kernel module loading after boot"
# Must run LAST: after every service that might still load a module.
depend() {
    after sshd dropbear nftables net
    keyword -timeout
}
start() {
    ebegin "Freezing kernel module loading (modules_disabled=1)"
    sysctl -w kernel.modules_disabled=1 >/dev/null 2>&1
    eend $?
}
EOF
    chmod +x "${root}/etc/init.d/aa-lockdown"
    # Only wired under OpenRC. It is intentionally NOT auto-enabled on the s6
    # (prod exit) path: modules_disabled=1 freezes ALL later module loading, and
    # the warren-exit datapath loads tun + nftables modules at RUNTIME when it
    # starts. Freezing before that would break the exit. Enabling it under s6
    # needs a real-node check that every datapath module is loaded first; until
    # then, do not silently brick the fleet's datapath.
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        chroot "$root" /sbin/rc-update add aa-lockdown default 2>/dev/null || true
    fi

    # 8. Secure permissions
    log_info "Setting secure permissions..."
    chmod 700 "${root}/root"
    chmod 600 "${root}/etc/shadow" 2>/dev/null || true

    # 9. Remove unnecessary files
    rm -rf "${root}/usr/share/doc" 2>/dev/null || true
    rm -rf "${root}/usr/share/man" 2>/dev/null || true

    log_info "Hardening applied"
}


