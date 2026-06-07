#!/bin/sh
# Tests for upgrade.sh - A/B upgrade management (raw-partition design)

Describe 'upgrade.sh'
    Include lib/common.sh
    Include lib/install.sh
    Include lib/upgrade.sh

    # Force the file-based fallback in get_current_slot by neutralising the
    # cmdline/disk derivation (no /proc/cmdline in the test environment).
    no_runtime_disk() {
        get_root_device() { echo ""; }
        get_boot_disk() { return 1; }
    }

    Describe 'strip_partition()'
        It 'strips a plain sdX partition'
            When call strip_partition "/dev/sda3"
            The output should equal "/dev/sda"
        End
        It 'strips an nvme pN partition'
            When call strip_partition "/dev/nvme0n1p3"
            The output should equal "/dev/nvme0n1"
        End
        It 'strips an mmcblk pN partition'
            When call strip_partition "/dev/mmcblk0p2"
            The output should equal "/dev/mmcblk0"
        End
    End

    Describe 'slot_to_partnum()'
        It 'maps slot A to partition 2'
            When call slot_to_partnum "A"
            The output should equal "2"
        End
        It 'maps slot B to partition 3'
            When call slot_to_partnum "B"
            The output should equal "3"
        End
    End

    Describe 'get_inactive_slot()'
        Context 'when current slot is A'
            setup() {
                no_runtime_disk
                BOOT_MNT=$(mktemp -d)
                echo "A" > "${BOOT_MNT}/current_slot"
            }
            cleanup() { rm -rf "$BOOT_MNT"; }
            Before 'setup'
            After 'cleanup'

            It 'returns B'
                When call get_inactive_slot
                The output should equal "B"
            End
        End

        Context 'when current slot is B'
            setup() {
                no_runtime_disk
                BOOT_MNT=$(mktemp -d)
                echo "B" > "${BOOT_MNT}/current_slot"
            }
            cleanup() { rm -rf "$BOOT_MNT"; }
            Before 'setup'
            After 'cleanup'

            It 'returns A'
                When call get_inactive_slot
                The output should equal "A"
            End
        End
    End

    Describe 'get_current_slot()'
        Context 'when current_slot file exists'
            setup() {
                no_runtime_disk
                BOOT_MNT=$(mktemp -d)
                echo "B" > "${BOOT_MNT}/current_slot"
            }
            cleanup() { rm -rf "$BOOT_MNT"; }
            Before 'setup'
            After 'cleanup'

            It 'returns the slot from the marker file'
                When call get_current_slot
                The output should equal "B"
            End
        End

        Context 'when current_slot file does not exist'
            setup() {
                no_runtime_disk
                BOOT_MNT=$(mktemp -d)
            }
            cleanup() { rm -rf "$BOOT_MNT"; }
            Before 'setup'
            After 'cleanup'

            It 'defaults to A'
                When call get_current_slot
                The output should equal "A"
            End
        End
    End

    Describe 'slot metadata'
        setup() { BOOT_MNT=$(mktemp -d); }
        cleanup() { rm -rf "$BOOT_MNT"; }
        Before 'setup'
        After 'cleanup'

        It 'sets and reads back a slot key'
            When call set_slot_meta "B" "VERSION" "3.20"
            The path "${BOOT_MNT}/slots.meta" should be exist
        End

        It 'round-trips a value'
            set_slot_meta "A" "VERSION" "3.20"
            When call get_slot_meta "A" "VERSION"
            The output should equal "3.20"
        End

        It 'updates an existing key in place'
            set_slot_meta "A" "BOOT_COUNT" "1"
            set_slot_meta "A" "BOOT_COUNT" "2"
            When call get_slot_meta "A" "BOOT_COUNT"
            The output should equal "2"
        End
    End

    Describe 'Upgrade constants'
        It 'defines max boot attempts'
            The variable MAX_BOOT_ATTEMPTS should equal 3
        End
    End
End
