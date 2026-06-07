#!/bin/sh
# Tests for install.sh - A/B installation

Describe 'install.sh'
    Include lib/common.sh
    Include lib/install.sh

    Describe 'get_partition_device()'
        It 'handles standard disks (sda)'
            When call get_partition_device "/dev/sda" 1
            The output should equal "/dev/sda1"
        End

        It 'handles standard disks (sdb)'
            When call get_partition_device "/dev/sdb" 3
            The output should equal "/dev/sdb3"
        End

        It 'handles NVMe disks'
            When call get_partition_device "/dev/nvme0n1" 1
            The output should equal "/dev/nvme0n1p1"
        End

        It 'handles MMC disks (SD cards)'
            When call get_partition_device "/dev/mmcblk0" 2
            The output should equal "/dev/mmcblk0p2"
        End

        It 'handles loop devices'
            When call get_partition_device "/dev/loop0" 1
            The output should equal "/dev/loop0p1"
        End
    End

    Describe 'Partition constants'
        It 'defines boot partition size'
            The variable PART_BOOT_SIZE_MB should equal 512
        End

        It 'defines slot size'
            The variable PART_SLOT_SIZE_MB should equal 2048
        End

        It 'defines minimum disk size'
            The variable MIN_DISK_SIZE_MB should equal 5120
        End
    End

    Describe 'is_usable_data_partition()'
        It 'is defined as a function'
            The value "$(type -t is_usable_data_partition)" should equal "function"
        End

        It 'returns unformatted when fstype is empty'
            # Non-existent device returns empty fstype -> unformatted
            When call is_usable_data_partition "/dev/nonexistent999"
            The output should equal "unformatted"
            The status should be success
        End
    End

    Describe 'auto_detect_overlay_device()'
        It 'is defined as a function'
            The value "$(type -t auto_detect_overlay_device)" should equal "function"
        End
    End

    Describe 'list_available_disks()'
        It 'is defined as a function'
            The value "$(type -t list_available_disks)" should equal "function"
        End
    End

    Describe 'detect_disk_layout()'
        It 'is defined as a function'
            The value "$(type -t detect_disk_layout)" should equal "function"
        End
    End

    Describe 'slot helpers'
        It 'slot_to_partnum maps A->2'
            When call slot_to_partnum A
            The output should equal 2
        End
        It 'slot_to_partnum maps B->3'
            When call slot_to_partnum B
            The output should equal 3
        End
        Context 'place_slot_kernel'
            setup() {
                BD=$(mktemp -d)
                printf 'KERNEL'  > "$BD/vmlinuz"
                printf 'INITRD'  > "$BD/initramfs"
            }
            cleanup() { rm -rf "$BD"; }
            Before 'setup'
            After 'cleanup'

            It 'writes per-slot kernel + initramfs'
                When call place_slot_kernel "$BD" A "$BD/vmlinuz" "$BD/initramfs"
                The path "$BD/vmlinuz-A" should be exist
                The path "$BD/initramfs-A" should be exist
            End
        End
    End

    Describe 'run_custom_script()'
        It 'is a no-op when CUSTOM_SCRIPT is unset'
            CUSTOM_SCRIPT=""
            When call run_custom_script /tmp
            The status should be success
        End
        It 'fails when CUSTOM_SCRIPT points to a missing file'
            CUSTOM_SCRIPT="/nonexistent/aa-custom.sh"
            When run run_custom_script /tmp
            The status should be failure
            The stderr should include "not found"
        End
    End

    Describe 'detect_root_disk() multi-disk safety'
        Context 'tmpfs root with two disks (SD + USB)'
            setup() {
                stat() { echo tmpfs; }
                lsblk() { printf '/dev/mmcblk0 disk\n/dev/sda disk\n'; }
                list_available_disks() { printf '/dev/mmcblk0 16G\n/dev/sda 931G\n'; }
            }
            Before 'setup'

            It 'refuses to guess and asks for --disk'
                When run detect_root_disk
                The status should be failure
                The stderr should include "Refusing to guess"
            End
        End

        Context 'tmpfs root with a single disk'
            setup() {
                stat() { echo tmpfs; }
                lsblk() { printf '/dev/sda disk\n'; }
            }
            Before 'setup'

            It 'uses the only disk'
                When call detect_root_disk
                The output should equal "/dev/sda"
            End
        End
    End

    Describe 'install_ab_services()'
        setup() { ROOT=$(mktemp -d); }
        cleanup() { rm -rf "$ROOT"; }
        Before 'setup'
        After 'cleanup'

        It 'writes the aa-bootcount boot service'
            When call install_ab_services "$ROOT"
            The path "$ROOT/etc/init.d/aa-bootcount" should be exist
            The contents of file "$ROOT/etc/init.d/aa-bootcount" should include "bootcount"
            The stderr should be defined
        End

        It 'writes the aa-verify service'
            When call install_ab_services "$ROOT"
            The path "$ROOT/etc/init.d/aa-verify" should be exist
            The contents of file "$ROOT/etc/init.d/aa-verify" should include "verify"
            The stderr should be defined
        End
    End

    Describe 'bake_management_tools()'
        setup() {
            ROOT=$(mktemp -d)
            INSTALL_BASE_DIR="$PWD"
        }
        cleanup() { rm -rf "$ROOT"; }
        Before 'setup'
        After 'cleanup'

        It 'installs a PATH wrapper that execs the libdir CLI'
            When call bake_management_tools "$ROOT"
            The path "$ROOT/usr/local/sbin/alpine-anywhere" should be exist
            The contents of file "$ROOT/usr/local/sbin/alpine-anywhere" should include "/usr/local/lib/alpine-anywhere/alpine-anywhere"
            The path "$ROOT/usr/local/lib/alpine-anywhere/lib/upgrade.sh" should be exist
            The stderr should be defined
        End
    End

    Describe 'persist_host_keys()'
        setup() {
            HARDENED_MODE=false
            KEYSRC=$(mktemp -d)
            ROOT=$(mktemp -d)
            printf 'PRIV' > "$KEYSRC/ssh_host_ed25519_key"
            printf 'PUB'  > "$KEYSRC/ssh_host_ed25519_key.pub"
        }
        cleanup() { rm -rf "$KEYSRC" "$ROOT"; }
        Before 'setup'
            After 'cleanup'

        It 'bakes control-host keys into the image when --ssh-host-keys is given'
            SSH_HOST_KEY_DIR="$KEYSRC"
            When call persist_host_keys "$ROOT"
            The path "$ROOT/etc/ssh/ssh_host_ed25519_key" should be exist
            The path "$ROOT/etc/ssh/ssh_host_ed25519_key.pub" should be exist
            The stderr should include "control-host"
        End
    End
End
