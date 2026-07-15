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

    Describe 'mount_boot() stale-state recovery'
        # A prior upgrade killed mid-flight (SSH severed on a control-host load
        # spike) leaves its EXIT-trap umount unrun, so the mountpoint keeps
        # residual files that shadow the real boot partition and make
        # switch_slot die "No known bootloader config". mount_boot must recover.
        setup_mb() {
            get_boot_disk() { echo /dev/sda; }
            get_part_dev() { echo "/dev/sda$2"; }
            MB_DIR=$(mktemp -d)
            BOOT_MNT="$MB_DIR/mnt"
            mkdir -p "$BOOT_MNT"
            printf 'SLOT_A_VERSION=stale\n' > "$BOOT_MNT/slots.meta"
            # Readable mounts table that does not list $BOOT_MNT: the real
            # boot_is_mounted sees a trustworthy "not mounted".
            export AA_MOUNTS_FILE="$MB_DIR/mounts"
            printf '/dev/sda2 /media/root-ro squashfs ro 0 0\n' > "$AA_MOUNTS_FILE"
            MOUNTED=""
            mount() { MOUNTED="$*"; }
            umount() { :; }
        }
        cleanup_mb() { rm -rf "$MB_DIR"; unset AA_MOUNTS_FILE; }
        Before 'setup_mb'
        After 'cleanup_mb'

        It 'clears residual files then mounts the real boot partition'
            When call mount_boot
            The variable MOUNTED should include "/dev/sda1"
            The path "$BOOT_MNT/slots.meta" should not be exist
        End

        It 'skips the residual-file rm when the mounts table is unreadable'
            # An absent/unreadable /proc/mounts is NOT proof the boot partition
            # is unmounted: rm-ing here could delete bootloader files through a
            # live mount. Fail closed and keep the files.
            export AA_MOUNTS_FILE="$MB_DIR/absent/mounts"
            When call mount_boot
            The variable MOUNTED should include "/dev/sda1"
            The path "$BOOT_MNT/slots.meta" should be exist
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

        Context 'when the active slot is unknown'
            setup() {
                no_runtime_disk
                BOOT_MNT=$(mktemp -d)
            }
            cleanup() { rm -rf "$BOOT_MNT"; }
            Before 'setup'
            After 'cleanup'

            It 'propagates the failure instead of inventing a target'
                When run get_inactive_slot
                The status should be failure
                The stderr should include "Cannot determine the active slot"
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

            It 'fails closed instead of guessing a slot'
                When run get_current_slot
                The status should be failure
                The stderr should include "Cannot determine the active slot"
                The stderr should include "current_slot"
                The stderr should include "aa status"
            End
        End

        Context 'when current_slot file holds garbage'
            setup() {
                no_runtime_disk
                BOOT_MNT=$(mktemp -d)
                echo "X" > "${BOOT_MNT}/current_slot"
            }
            cleanup() { rm -rf "$BOOT_MNT"; }
            Before 'setup'
            After 'cleanup'

            It 'fails closed instead of guessing a slot'
                When run get_current_slot
                The status should be failure
                The stderr should include "Cannot determine the active slot"
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

    Describe 'live_root_backing_dev()'
        setup_live() {
            LRDIR=$(mktemp -d)
            export AA_MOUNTS_FILE="$LRDIR/mounts" AA_SYS_BLOCK_DIR="$LRDIR/sys"
        }
        cleanup_live() { rm -rf "$LRDIR"; unset AA_MOUNTS_FILE AA_SYS_BLOCK_DIR; }
        Before 'setup_live'
        After 'cleanup_live'

        It 'returns the live squashfs source verbatim'
            printf '/dev/sda2 /media/root-ro squashfs ro 0 0\n' > "$AA_MOUNTS_FILE"
            When call live_root_backing_dev
            The output should equal "/dev/sda2"
        End

        It 'resolves a dm-mapped root to its backing partition'
            printf '/dev/dm-0 /media/root-ro squashfs ro 0 0\n' > "$AA_MOUNTS_FILE"
            mkdir -p "$LRDIR/sys/dm-0/slaves/sda2"
            When call live_root_backing_dev
            The output should equal "/dev/sda2"
        End

        It 'returns nothing when no squashfs root is mounted'
            printf '/dev/sda1 / ext4 rw 0 0\n' > "$AA_MOUNTS_FILE"
            When call live_root_backing_dev
            The output should equal ""
        End
    End

    Describe 'install_to_slot()'
        setup_install() {
            IDIR=$(mktemp -d)
            export AA_MOUNTS_FILE="$IDIR/mounts"
            printf '/dev/sda3 /media/root-ro squashfs ro 0 0\n' > "$AA_MOUNTS_FILE"
            get_boot_disk() { echo /dev/sda; }
            get_part_dev() { echo "/dev/sda$2"; }
            generate_system_squashfs() { echo built > "$IDIR/built"; }
        }
        cleanup_install() { rm -rf "$IDIR"; unset AA_MOUNTS_FILE; }
        Before 'setup_install'
        After 'cleanup_install'

        It 'refuses to write the target slot over the live root device'
            When run install_to_slot B 3.20
            The status should be failure
            The stderr should include "live root"
            The path "$IDIR/built" should not be exist
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
            # switch_slot refuses an empty target slot: give slot B an installed image.
            printf 'SLOT_B_VERSION=3.20\n' > "$BOOT_MNT/slots.meta"
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
            printf 'SLOT_B_VERSION=3.20\nSLOT_B_ROOT_HASH=deadbeef\n' > "$BOOT_MNT/slots.meta"
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

        It 'refuses to switch to a slot with no installed image'
            printf '' > "$BOOT_MNT/slots.meta"
            When run switch_slot B
            The status should be failure
            The stderr should include "no image installed"
        End

        It 'flips both bootloaders on x86: extlinux DEFAULT and the GRUB default'
            rm -f "$BOOT_MNT/config.txt" "$BOOT_MNT/cmdline.txt"
            mkdir -p "$BOOT_MNT/extlinux" "$BOOT_MNT/grub"
            echo 'DEFAULT alpine-A' > "$BOOT_MNT/extlinux/extlinux.conf"
            When call switch_slot B
            The contents of file "$BOOT_MNT/extlinux/extlinux.conf" should include "DEFAULT alpine-B"
            The contents of file "$BOOT_MNT/grub/grub_aa_default.cfg" should include "set default=alpine-B"
            The contents of file "$BOOT_MNT/current_slot" should include "B"
            The stderr should be defined
        End

        It 'skips the GRUB write on a BIOS-only x86 boot partition (no grub dir)'
            rm -f "$BOOT_MNT/config.txt" "$BOOT_MNT/cmdline.txt"
            mkdir -p "$BOOT_MNT/extlinux"
            echo 'DEFAULT alpine-A' > "$BOOT_MNT/extlinux/extlinux.conf"
            When call switch_slot B
            The contents of file "$BOOT_MNT/extlinux/extlinux.conf" should include "DEFAULT alpine-B"
            The path "$BOOT_MNT/grub/grub_aa_default.cfg" should not be exist
            The stderr should be defined
        End

        It 'flips the GRUB default on a GRUB-only boot partition (UEFI, no extlinux)'
            rm -f "$BOOT_MNT/config.txt" "$BOOT_MNT/cmdline.txt"
            mkdir -p "$BOOT_MNT/grub"
            printf 'set default=alpine-A\n' > "$BOOT_MNT/grub/grub_aa_default.cfg"
            printf 'menuentry "Alpine Linux (Slot A)" --id alpine-A {\n}\n' > "$BOOT_MNT/grub/grub.cfg"
            When call switch_slot B
            The contents of file "$BOOT_MNT/grub/grub_aa_default.cfg" should include "set default=alpine-B"
            The contents of file "$BOOT_MNT/current_slot" should include "B"
            The stderr should be defined
        End

        It 'dies when no bootloader config exists at all'
            rm -f "$BOOT_MNT/config.txt" "$BOOT_MNT/cmdline.txt"
            When run switch_slot B
            The status should be failure
            The stderr should include "No known bootloader config"
            The path "$BOOT_MNT/current_slot" should not be exist
        End
    End

    Describe 'show_status()'
        setup_status() {
            get_boot_disk() { echo /dev/sda; }
            get_root_device() { echo /dev/sda2; }
            get_part_dev() { echo "/dev/sda$2"; }
            mount_boot() { :; }
            umount_boot() { :; }
            BOOT_MNT=$(mktemp -d)
            echo B > "$BOOT_MNT/current_slot"
            mkdir -p "$BOOT_MNT/grub"
            printf 'set default=alpine-B\n' > "$BOOT_MNT/grub/grub_aa_default.cfg"
            {
                echo 'menuentry "Alpine Linux (Slot A)" --id alpine-A {'
                echo '    linux ($aaroot)/vmlinuz-A root=PARTUUID=aaaa quiet'
                echo '}'
                echo 'menuentry "Alpine Linux (Slot B)" --id alpine-B {'
                echo '    linux ($aaroot)/vmlinuz-B root=PARTUUID=bbbb quiet'
                echo '}'
            } > "$BOOT_MNT/grub/grub.cfg"
        }
        cleanup_status() { rm -rf "$BOOT_MNT"; }
        Before 'setup_status'
        After 'cleanup_status'

        It 'reports the next-boot root from grub.cfg on a GRUB-only layout'
            When call show_status
            The output should include "Boot slot:     B"
            The output should include "root=PARTUUID=bbbb"
            The stderr should be defined
        End
    End

    Describe 'Upgrade constants'
        It 'defines max boot attempts'
            The variable MAX_BOOT_ATTEMPTS should equal 1
        End
    End
End
