#!/bin/bash
# Tests for hardening.sh - Security hardening module

Describe 'hardening.sh'
    Include lib/common.sh
    Include lib/hardening.sh

    Describe 'HARDENED_PACKAGES array'
        It 'contains linux-hardened'
            The value "${HARDENED_PACKAGES[*]}" should include 'linux-hardened'
        End

        It 'contains dropbear'
            The value "${HARDENED_PACKAGES[*]}" should include 'dropbear'
        End

        It 'contains hardened-malloc'
            The value "${HARDENED_PACKAGES[*]}" should include 'hardened-malloc'
        End

        It 'contains nftables'
            The value "${HARDENED_PACKAGES[*]}" should include 'nftables'
        End
    End

    Describe 'HARDENED_EXCLUDE_PACKAGES array'
        It 'excludes openssh-server'
            The value "${HARDENED_EXCLUDE_PACKAGES[*]}" should include 'openssh-server'
        End

        It 'excludes linux-lts'
            The value "${HARDENED_EXCLUDE_PACKAGES[*]}" should include 'linux-lts'
        End
    End

    Describe 'generate_hardened_cmdline()'
        It 'includes lockdown=integrity'
            When call generate_hardened_cmdline
            The output should include 'lockdown=integrity'
        End

        It 'includes iommu=force'
            When call generate_hardened_cmdline
            The output should include 'iommu=force'
        End

        It 'includes slub_debug'
            When call generate_hardened_cmdline
            The output should include 'slub_debug='
        End

        It 'includes init_on_alloc=1'
            When call generate_hardened_cmdline
            The output should include 'init_on_alloc=1'
        End

        It 'includes spectre mitigations'
            When call generate_hardened_cmdline
            The output should include 'spectre_v2=on'
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
            The output should include 'DROPBEAR_OPTS="-s -g"'
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

    Describe 'generate_hardened_malloc_config()'
        It 'configures libhardened_malloc preload'
            When call generate_hardened_malloc_config
            The output should include '/usr/lib/libhardened_malloc.so'
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

    Describe 'get_hardened_packages()'
        It 'returns space-separated package list'
            When call get_hardened_packages
            The output should include 'linux-hardened'
            The output should include 'dropbear'
        End
    End

    Describe 'get_hardened_kernel()'
        It 'returns linux-hardened'
            When call get_hardened_kernel
            The output should equal 'linux-hardened'
        End
    End
End
