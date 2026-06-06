#!/bin/bash
# full_flow_spec.sh - Integration tests for alpine-anywhere

Describe 'alpine-anywhere integration'
    Include lib/common.sh
    Include lib/ssh.sh
    Include lib/network.sh
    Include lib/download.sh
    Include lib/apkovl.sh
    Include lib/kexec.sh
    Include lib/validate.sh

    Describe 'parse_arguments()'
        Context 'with basic target'
            It 'parses simple host target'
                When call parse_arguments 'root@192.168.1.100'
                The variable TARGET_USER should equal 'root'
                The variable TARGET_HOST should equal '192.168.1.100'
            End
        End

        Context 'with all options'
            setup() {
                # Create a temporary identity file
                TEST_IDENTITY=$(mktemp)
            }
            cleanup() {
                rm -f "$TEST_IDENTITY"
            }
            Before 'setup'
            After 'cleanup'

            It 'parses all command line options'
                When call parse_arguments -V 3.21 -m https://uk.alpinelinux.org/alpine -k virt -p 2222 -i "$TEST_IDENTITY" -n -v -f --extra-packages vim,htop --reboot-delay 10 testuser@myserver.local
                The variable ALPINE_VERSION should equal '3.21'
                The variable ALPINE_MIRROR should equal 'https://uk.alpinelinux.org/alpine'
                The variable KERNEL_FLAVOR should equal 'virt'
                The variable SSH_PORT should equal '2222'
                The variable SSH_IDENTITY should equal "$TEST_IDENTITY"
                The variable DRY_RUN should equal 'true'
                The variable VERBOSE should equal 'true'
                The variable FORCE should equal 'true'
                The variable EXTRA_PACKAGES should equal 'vim,htop'
                The variable REBOOT_DELAY should equal '10'
                The variable TARGET_USER should equal 'testuser'
                The variable TARGET_HOST should equal 'myserver.local'
                The stderr should include 'DEBUG'
            End
        End

        Context 'with --dry-run flag'
            It 'sets DRY_RUN to true'
                When call parse_arguments --dry-run user@host
                The variable DRY_RUN should equal 'true'
            End
        End

        Context 'with --verbose flag'
            It 'sets VERBOSE to true'
                When call parse_arguments --verbose user@host
                The variable VERBOSE should equal 'true'
                The stderr should include 'DEBUG'
            End
        End

        Context 'with --force flag'
            It 'sets FORCE to true'
                When call parse_arguments --force user@host
                The variable FORCE should equal 'true'
            End
        End

        Context 'with invalid kernel flavor'
            It 'fails with invalid kernel flavor'
                When run parse_arguments --kernel invalid user@host
                The status should be failure
                The stderr should include 'Invalid kernel flavor'
            End
        End
    End

    Describe 'end-to-end apkovl generation'
        setup() {
            WORK_DIR=$(mktemp -d)
            DETECTED_INTERFACE="eth0"
            DETECTED_IP_ADDRESS="10.20.30.40"
            DETECTED_NETMASK="255.255.255.0"
            DETECTED_CIDR="24"
            DETECTED_GATEWAY="10.20.30.1"
            DETECTED_DNS="1.1.1.1 8.8.8.8"
            DETECTED_HOSTNAME="integration-test"
            NETWORK_IS_DHCP=false
            ALPINE_VERSION="3.20"
            ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
            EXTRA_PACKAGES=""
            DRY_RUN=false
            VERBOSE=false
        }
        cleanup() {
            rm -rf "$WORK_DIR"
        }
        Before 'setup'
        After 'cleanup'

        It 'generates a valid apkovl tarball'
            ssh_keys="ssh-ed25519 AAAA... test@example.com"
            When call generate_apkovl "$ssh_keys"
            The status should be success
            The output should include 'integration-test.apkovl.tar.gz'
            The stderr should include 'Generating apkovl'
        End

        It 'creates apkovl with correct structure'
            ssh_keys="ssh-ed25519 AAAA... test@example.com"
            apkovl_file=$(generate_apkovl "$ssh_keys" 2>/dev/null)
            When call tar -tzf "$apkovl_file"
            The output should include 'etc/network/interfaces'
            The output should include 'etc/resolv.conf'
            The output should include 'etc/hostname'
            The output should include 'etc/passwd'
            The output should include 'etc/shadow'
            The output should include 'etc/apk/world'
            The output should include 'etc/ssh/sshd_config'
            The output should include 'root/.ssh/authorized_keys'
        End
    End

    Describe 'full configuration workflow'
        setup() {
            # Initialize all required variables
            ALPINE_VERSION="3.20"
            ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
            KERNEL_FLAVOR="lts"
            SSH_PORT="22"
            DRY_RUN=true
            VERBOSE=false
            FORCE=true
            EXTRA_PACKAGES=""
            REBOOT_DELAY="5"
            TARGET_HOST="test.example.com"
            TARGET_USER="root"
            REMOTE_WORK_DIR="/tmp/alpine-anywhere"

            # Network configuration
            DETECTED_INTERFACE="ens192"
            DETECTED_IP_ADDRESS="172.16.0.100"
            DETECTED_NETMASK="255.255.255.0"
            DETECTED_CIDR="24"
            DETECTED_GATEWAY="172.16.0.1"
            DETECTED_DNS="172.16.0.1"
            DETECTED_HOSTNAME="flowtest"
            DETECTED_ARCH="x86_64"
            NETWORK_IS_DHCP=false
        }
        Before 'setup'

        It 'generates valid kernel command line'
            When call build_kernel_cmdline
            The output should include 'console=tty0'
            The output should include 'alpine_repo='
            The output should include 'modloop='
            The output should include 'ip=172.16.0.100::'
        End

        It 'generates valid network interfaces'
            When call generate_interfaces_config
            The output should include 'auto ens192'
            The output should include 'inet static'
            The output should include 'address 172.16.0.100'
        End

        It 'generates valid resolv.conf'
            When call generate_resolv_conf
            The output should include 'nameserver 172.16.0.1'
        End

        It 'builds correct download URLs'
            When call build_alpine_file_url vmlinuz
            The output should include 'v3.20/releases/x86_64/netboot/vmlinuz-lts'
        End
    End
End
