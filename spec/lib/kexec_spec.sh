#!/bin/sh
# kexec_spec.sh - Tests for lib/kexec.sh

Describe 'kexec.sh'
    Include lib/common.sh
    Include lib/network.sh
    Include lib/kexec.sh

    Describe 'build_kernel_cmdline()'
        setup() {
            ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
            ALPINE_VERSION="3.20"
            REMOTE_WORK_DIR="/tmp/alpine-anywhere"
            DETECTED_HOSTNAME="testserver"
            DETECTED_INTERFACE="eth0"
            DETECTED_IP_ADDRESS="192.168.1.100"
            DETECTED_NETMASK="255.255.255.0"
            DETECTED_GATEWAY="192.168.1.1"
            NETWORK_IS_DHCP=false
            VERBOSE=false
        }
        Before 'setup'

        It 'includes console parameters'
            When call build_kernel_cmdline
            The output should include 'console=tty0'
            The output should include 'console=ttyS0,115200n8'
        End

        It 'includes alpine_repo'
            When call build_kernel_cmdline
            The output should include 'alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.20/main'
        End

        It 'includes modloop path'
            When call build_kernel_cmdline
            The output should include 'modloop=/tmp/alpine-anywhere/modloop'
        End

        It 'includes required modules'
            When call build_kernel_cmdline
            The output should include 'modules=loop,squashfs,sd-mod,usb-storage'
        End

        It 'includes apkovl path'
            When call build_kernel_cmdline
            The output should include 'apkovl=/tmp/alpine-anywhere/testserver.apkovl.tar.gz'
        End

        It 'includes static IP configuration'
            When call build_kernel_cmdline
            The output should include 'ip=192.168.1.100::192.168.1.1:255.255.255.0:testserver:eth0:off'
        End

        It 'includes quiet when not verbose'
            When call build_kernel_cmdline
            The output should include 'quiet'
        End

        Context 'with DHCP network'
            setup() {
                ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
                ALPINE_VERSION="3.20"
                REMOTE_WORK_DIR="/tmp/alpine-anywhere"
                DETECTED_HOSTNAME="dhcphost"
                NETWORK_IS_DHCP=true
                VERBOSE=false
            }
            Before 'setup'

            It 'uses ip=dhcp'
                When call build_kernel_cmdline
                The output should include 'ip=dhcp'
            End
        End

        Context 'with verbose mode'
            setup() {
                ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
                ALPINE_VERSION="3.20"
                REMOTE_WORK_DIR="/tmp/alpine-anywhere"
                DETECTED_HOSTNAME="testserver"
                DETECTED_INTERFACE="eth0"
                DETECTED_IP_ADDRESS="192.168.1.100"
                DETECTED_NETMASK="255.255.255.0"
                DETECTED_GATEWAY="192.168.1.1"
                NETWORK_IS_DHCP=false
                VERBOSE=true
            }
            Before 'setup'

            It 'does not include quiet'
                When call build_kernel_cmdline
                The output should not include 'quiet'
            End
        End
    End

    Describe 'show_kexec_diagnostics()'
        setup() {
            WORK_DIR="/tmp/test-work"
            REMOTE_WORK_DIR="/tmp/alpine-anywhere"
            ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
            ALPINE_VERSION="3.20"
            DETECTED_HOSTNAME="diaghost"
            DETECTED_INTERFACE="eth0"
            DETECTED_IP_ADDRESS="10.0.0.10"
            DETECTED_NETMASK="255.255.255.0"
            DETECTED_GATEWAY="10.0.0.1"
            NETWORK_IS_DHCP=false
            VERBOSE=false
        }
        Before 'setup'

        It 'shows kernel command line section'
            When call show_kexec_diagnostics
            The output should include 'Kernel command line:'
        End

        It 'shows files to transfer section'
            When call show_kexec_diagnostics
            The output should include 'Files to transfer:'
        End

        It 'shows vmlinuz file'
            When call show_kexec_diagnostics
            The output should include 'vmlinuz'
        End

        It 'shows initramfs file'
            When call show_kexec_diagnostics
            The output should include 'initramfs'
        End

        It 'shows modloop file'
            When call show_kexec_diagnostics
            The output should include 'modloop'
        End

        It 'shows remote destination'
            When call show_kexec_diagnostics
            The output should include 'Remote destination: /tmp/alpine-anywhere'
        End
    End
End
