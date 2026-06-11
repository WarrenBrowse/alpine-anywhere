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

    Describe 'get_root_device()'
        setup_cmdline() {
            RDDIR=$(mktemp -d)
            export AA_CMDLINE_FILE="$RDDIR/cmdline" AA_MOUNTS_FILE="$RDDIR/mounts"
            printf '/dev/sda2 /media/root-ro squashfs ro 0 0\n' > "$AA_MOUNTS_FILE"
        }
        cleanup_cmdline() { rm -rf "$RDDIR"; }
        Before 'setup_cmdline'
        After 'cleanup_cmdline'

        It 'returns a plain /dev root verbatim'
            printf 'BOOT_IMAGE=/vmlinuz root=/dev/sda2 rootfstype=squashfs\n' > "$AA_CMDLINE_FILE"
            When call get_root_device
            The output should equal "/dev/sda2"
        End

        It 'resolves root=PARTUUID to the live squashfs slot device'
            printf 'BOOT_IMAGE=/vmlinuz root=PARTUUID=81a9efcc-fcca-46e6-bdb7-ff77e8cfce61 rootfstype=squashfs\n' > "$AA_CMDLINE_FILE"
            When call get_root_device
            The output should equal "/dev/sda2"
        End

        It 'falls back to the squashfs source when cmdline has no root='
            printf 'BOOT_IMAGE=/vmlinuz quiet\n' > "$AA_CMDLINE_FILE"
            When call get_root_device
            The output should equal "/dev/sda2"
        End
    End

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

    Describe 'sed_inplace_checked()'
        setup() {
            F=$(mktemp)
            printf 'kernel=vmlinuz-A\nother=1\n' > "$F"
        }
        cleanup() { rm -f "$F"; }
        Before 'setup'
        After 'cleanup'

        It 'edits a file in place portably and verifies the result'
            When call sed_inplace_checked "$F" "^kernel=vmlinuz-B\$" -e 's|^kernel=vmlinuz-[AB].*|kernel=vmlinuz-B|'
            The contents of file "$F" should include "vmlinuz-B"
        End

        It 'aborts (leaving file intact) on a no-op edit'
            When run sed_inplace_checked "$F" "^kernel=vmlinuz-B\$" -e 's|^nomatch$|x|'
            The status should be failure
            The stderr should include "expected state"
            The contents of file "$F" should include "vmlinuz-A"
        End
    End

    Describe 'switch_slot()'
        setup() {
            get_boot_disk() { echo /dev/sda; }
            get_part_dev() { echo "/dev/sda$2"; }
            BOOT_MNT=$(mktemp -d)
            {
                echo 'arm_64bit=1'
                echo '[pi4]'
                echo 'kernel=vmlinuz-A'
                echo 'initramfs initramfs-A followkernel'
            } > "$BOOT_MNT/config.txt"
            echo 'root=/dev/sda2 rootfstype=squashfs' > "$BOOT_MNT/cmdline.txt"
        }
        cleanup() { rm -rf "$BOOT_MNT"; }
        Before 'setup'
        After 'cleanup'

        It 'flips the RPi config.txt + cmdline + marker to the new slot'
            When call switch_slot B
            The contents of file "$BOOT_MNT/config.txt" should include "kernel=vmlinuz-B"
            The contents of file "$BOOT_MNT/config.txt" should include "initramfs initramfs-B followkernel"
            The contents of file "$BOOT_MNT/cmdline.txt" should include "root=/dev/sda3"
            The contents of file "$BOOT_MNT/current_slot" should include "B"
            The stderr should be defined
        End

        It 'adds aaverity=1 only when the target slot has a ROOT_HASH (verity)'
            printf 'SLOT_B_ROOT_HASH=deadbeef\n' > "$BOOT_MNT/slots.meta"
            When call switch_slot B
            The contents of file "$BOOT_MNT/cmdline.txt" should include "aaverity=1"
            The stderr should be defined
        End

        It 'omits aaverity for a non-verity target slot'
            printf 'SLOT_B_VERSION=3.20\n' > "$BOOT_MNT/slots.meta"
            When call switch_slot B
            The contents of file "$BOOT_MNT/cmdline.txt" should not include "aaverity"
            The stderr should be defined
        End
    End

    Describe 'Upgrade constants'
        It 'defines max boot attempts'
            The variable MAX_BOOT_ATTEMPTS should equal 1
        End
    End
End
