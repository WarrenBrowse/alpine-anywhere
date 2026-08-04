#!/bin/sh
# Tests for hardening.sh - Security hardening module

Describe 'hardening.sh'
    Include lib/common.sh
    Include lib/hardening.sh

    Describe 'generate_hardened_cmdline()'
        It 'includes lockdown=integrity'
            When call generate_hardened_cmdline
            The output should include 'lockdown=integrity'
        End

        It 'includes slub_debug'
            When call generate_hardened_cmdline
            The output should include 'slub_debug='
        End

        It 'includes init_on_alloc=1 and init_on_free=1'
            When call generate_hardened_cmdline
            The output should include 'init_on_alloc=1'
            The output should include 'init_on_free=1'
        End

        It 'includes kptr_restrict and stack-offset randomization'
            When call generate_hardened_cmdline
            The output should include 'kptr_restrict=2'
            The output should include 'randomize_kstack_offset=on'
        End

        # Deliberately excluded for cloud-KVM boot safety and exit throughput
        # (see generate_hardened_cmdline). Pin the exclusion so it is not
        # reintroduced without a real-node validation.
        It 'does not force an IOMMU (would break virtio DMA on cloud KVM)'
            When call generate_hardened_cmdline
            The output should not include 'iommu=force'
        End

        It 'does not disable SMT (would halve exit throughput)'
            When call generate_hardened_cmdline
            The output should not include 'nosmt'
        End
    End

    Describe 'generate_sysctl_hardening()'
        It 'disables IP forwarding'
            When call generate_sysctl_hardening
            The output should include 'net.ipv4.ip_forward = 0'
        End

        It 'enables SYN cookies'
            When call generate_sysctl_hardening
            The output should include 'net.ipv4.tcp_syncookies = 1'
        End

        It 'enables reverse path filtering'
            When call generate_sysctl_hardening
            The output should include 'net.ipv4.conf.all.rp_filter = 1'
        End

        It 'restricts dmesg'
            When call generate_sysctl_hardening
            The output should include 'kernel.dmesg_restrict = 1'
        End

        It 'restricts ptrace'
            When call generate_sysctl_hardening
            The output should include 'kernel.yama.ptrace_scope = 2'
        End

        It 'disables kexec after boot'
            When call generate_sysctl_hardening
            The output should include 'kernel.kexec_load_disabled = 1'
        End

        It 'enables ASLR'
            When call generate_sysctl_hardening
            The output should include 'kernel.randomize_va_space = 2'
        End

        It 'protects symlinks'
            When call generate_sysctl_hardening
            The output should include 'fs.protected_symlinks = 1'
        End
    End

    Describe 'generate_dropbear_confd()'
        It 'disables password authentication'
            When call generate_dropbear_confd
            The output should include 'DROPBEAR_OPTS="-s -g'
        End

        It 'widens the receive window past the 24 KB default'
            When call generate_dropbear_confd
            The output should include '-W 1048576'
        End

        It 'sets default port to 22'
            When call generate_dropbear_confd
            The output should include 'DROPBEAR_PORT="22"'
        End

        It 'sets idle timeout'
            When call generate_dropbear_confd
            The output should include 'DROPBEAR_IDLE_TIMEOUT="300"'
        End
    End

    Describe 'generate_nftables_config()'
        It 'sets default input policy to drop'
            When call generate_nftables_config
            The output should include 'policy drop'
        End

        It 'allows established connections'
            When call generate_nftables_config
            The output should include 'ct state established,related accept'
        End

        It 'allows loopback'
            When call generate_nftables_config
            The output should include 'iif "lo" accept'
        End

        It 'rate limits SSH'
            When call generate_nftables_config
            The output should include 'limit rate'
        End

        It 'allows SSH on default port'
            When call generate_nftables_config
            The output should include 'tcp dport 22'
        End

        It 'accepts custom SSH port'
            When call generate_nftables_config 2222
            The output should include 'tcp dport 2222'
        End
    End

    Describe 'generate_security_audit()'
        It 'checks kernel version'
            When call generate_security_audit
            The output should include 'uname -r'
        End

        It 'checks lockdown status'
            When call generate_security_audit
            The output should include '/sys/kernel/security/lockdown'
        End

        It 'checks ASLR'
            When call generate_security_audit
            The output should include 'randomize_va_space'
        End

        It 'checks open ports'
            When call generate_security_audit
            The output should include 'ss -tlnp'
        End
    End
End
