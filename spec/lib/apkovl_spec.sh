#!/bin/bash
# apkovl_spec.sh - Tests for lib/apkovl.sh

Describe 'apkovl.sh'
    Include lib/common.sh
    Include lib/network.sh
    Include lib/apkovl.sh

    Describe 'generate_passwd()'
        It 'includes root user'
            When call generate_passwd
            The output should include 'root:x:0:0:root:/root:/bin/ash'
        End

        It 'includes sshd user'
            When call generate_passwd
            The output should include 'sshd:x:22:22:sshd:/var/empty:/sbin/nologin'
        End

        It 'includes nobody user'
            When call generate_passwd
            The output should include 'nobody:x:65534:65534'
        End
    End

    Describe 'generate_shadow()'
        It 'includes root with locked password'
            When call generate_shadow
            The output should include 'root:*:'
        End

        It 'includes sshd with disabled password'
            When call generate_shadow
            The output should include 'sshd:!:'
        End
    End

    Describe 'generate_group()'
        It 'includes root group'
            When call generate_group
            The output should include 'root:x:0:root'
        End

        It 'includes wheel group'
            When call generate_group
            The output should include 'wheel:x:10:root'
        End

        It 'includes sshd group'
            When call generate_group
            The output should include 'sshd:x:22:'
        End
    End

    Describe 'generate_apk_world()'
        Context 'without extra packages'
            setup() {
                EXTRA_PACKAGES=""
            }
            Before 'setup'

            It 'includes alpine-base'
                When call generate_apk_world
                The output should include 'alpine-base'
            End

            It 'includes openssh-server'
                When call generate_apk_world
                The output should include 'openssh-server'
            End

            It 'includes kexec-tools'
                When call generate_apk_world
                The output should include 'kexec-tools'
            End
        End

        Context 'with extra packages'
            setup() {
                EXTRA_PACKAGES="vim,htop,curl"
            }
            Before 'setup'

            It 'includes extra packages'
                When call generate_apk_world
                The output should include 'vim'
                The output should include 'htop'
                The output should include 'curl'
            End
        End
    End

    Describe 'generate_apk_repositories()'
        setup() {
            ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
            ALPINE_VERSION="3.20"
        }
        Before 'setup'

        It 'includes main repository'
            When call generate_apk_repositories
            The output should include 'https://dl-cdn.alpinelinux.org/alpine/v3.20/main'
        End

        It 'includes community repository'
            When call generate_apk_repositories
            The output should include 'https://dl-cdn.alpinelinux.org/alpine/v3.20/community'
        End
    End

    Describe 'generate_sshd_config()'
        It 'sets PermitRootLogin to prohibit-password'
            When call generate_sshd_config
            The output should include 'PermitRootLogin prohibit-password'
        End

        It 'enables PubkeyAuthentication'
            When call generate_sshd_config
            The output should include 'PubkeyAuthentication yes'
        End

        It 'disables PasswordAuthentication'
            When call generate_sshd_config
            The output should include 'PasswordAuthentication no'
        End

        It 'includes ed25519 host key'
            When call generate_sshd_config
            The output should include 'HostKey /etc/ssh/ssh_host_ed25519_key'
        End
    End

    Describe 'generate_local_start()'
        It 'generates host keys if not present'
            When call generate_local_start
            The output should include 'ssh-keygen -A'
        End

        It 'sets correct permissions on keys'
            When call generate_local_start
            The output should include 'chmod 600'
        End

        It 'is a shell script'
            When call generate_local_start
            The line 1 should equal '#!/bin/sh'
        End
    End

    Describe 'create_apkovl_structure()'
        setup() {
            TEST_DIR=$(mktemp -d)
        }
        cleanup() {
            rm -rf "$TEST_DIR"
        }
        Before 'setup'
        After 'cleanup'

        It 'creates etc directory'
            When call create_apkovl_structure "$TEST_DIR"
            The path "$TEST_DIR/etc" should be directory
        End

        It 'creates etc/network directory'
            When call create_apkovl_structure "$TEST_DIR"
            The path "$TEST_DIR/etc/network" should be directory
        End

        It 'creates etc/apk directory'
            When call create_apkovl_structure "$TEST_DIR"
            The path "$TEST_DIR/etc/apk" should be directory
        End

        It 'creates etc/ssh directory'
            When call create_apkovl_structure "$TEST_DIR"
            The path "$TEST_DIR/etc/ssh" should be directory
        End

        It 'creates root/.ssh directory with correct permissions'
            When call create_apkovl_structure "$TEST_DIR"
            The path "$TEST_DIR/root/.ssh" should be directory
        End

        It 'creates runlevels directories'
            When call create_apkovl_structure "$TEST_DIR"
            The path "$TEST_DIR/etc/runlevels/boot" should be directory
            The path "$TEST_DIR/etc/runlevels/default" should be directory
            The path "$TEST_DIR/etc/runlevels/sysinit" should be directory
        End
    End
End
