#!/bin/sh
# artifacts_spec.sh - Integration checks on generated artifacts (no root, no
# loop devices). Validates that the boot config and the patched initramfs come
# out well-formed and internally consistent.

Describe 'generated artifacts'
    Include lib/common.sh
    Include lib/network.sh
    Include lib/download.sh
    Include lib/install.sh
    Include lib/upgrade.sh

    Describe 'extlinux boot config' install_boot_config
        setup() {
            DETECTED_PLATFORM="generic"
            VERITY_MODE=off
            BOOTMNT=$(mktemp -d)
            get_part_dev() { echo "/dev/sda$2"; }
        }
        cleanup_dir() { rm -rf "$BOOTMNT"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'writes a DEFAULT that matches a LABEL'
            install_boot_config "$BOOTMNT" /dev/sda A >/dev/null 2>&1
            default_label=$(sed -n 's/^DEFAULT //p' "$BOOTMNT/extlinux/extlinux.conf")
            assert() { grep -q "^LABEL ${default_label}\$" "$BOOTMNT/extlinux/extlinux.conf" && echo OK; }
            When call assert
            The output should equal "OK"
        End

        It 'adds aaverity=1 to APPEND when verity is on'
            VERITY_MODE=on
            install_boot_config "$BOOTMNT" /dev/sda A >/dev/null 2>&1
            When call cat "$BOOTMNT/extlinux/extlinux.conf"
            The output should include "aaverity=1"
            The stderr should be defined
        End
    End

    Describe 'patched initramfs init'
        setup() {
            SCRIPT_DIR="$PWD"
            WD=$(mktemp -d); SRC="$WD/src"; mkdir -p "$SRC"
            printf '#!/bin/sh\nmount -o ro "$KOPT_root" "$sysroot"\nexec switch_root "$sysroot" /sbin/init\n' > "$SRC/init"
            chmod +x "$SRC/init"
            ( cd "$SRC" && find . | cpio -o -H newc 2>/dev/null | gzip ) > "$WD/initramfs"
        }
        cleanup_dir() { rm -rf "$WD"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'init.aa is syntactically valid POSIX sh after wrapping'
            command -v cpio >/dev/null 2>&1 || Skip "cpio not available"
            VERITY_MODE=off
            check() {
                wrap_boot_initramfs "$WD/initramfs" >/dev/null 2>&1
                mkdir -p "$WD/out"; ( cd "$WD/out" && gzip -dc "$WD/initramfs" | cpio -idm 2>/dev/null )
                sh -n "$WD/out/sbin/init.aa" && echo INIT_AA_OK
                sh -n "$WD/out/init" && echo INIT_OK
            }
            When call check
            The output should include "INIT_AA_OK"
            The output should include "INIT_OK"
            The stderr should be defined
        End
    End

    Describe 'slot metadata round-trip' set_slot_meta get_slot_meta
        setup() {
            BOOT_MNT=$(mktemp -d)
            get_boot_disk() { echo /dev/sda; }
            get_root_device() { echo /dev/sda2; }
            get_part_dev() { echo "/dev/sda$2"; }
        }
        cleanup_dir() { rm -rf "$BOOT_MNT"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'persists and reads back a value atomically (no temp left behind)'
            roundtrip() {
                set_slot_meta A ROOT_HASH abc123
                set_slot_meta A BOOT_COUNT 0
                get_slot_meta A ROOT_HASH
            }
            When call roundtrip
            The output should equal "abc123"
            The path "$BOOT_MNT/slots.meta.aatmp.$$" should not be exist
        End
    End
End
