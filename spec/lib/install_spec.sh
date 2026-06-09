#!/bin/sh
# Tests for install.sh - A/B installation

Describe 'install.sh'
    Include lib/common.sh
    Include lib/install.sh

    Describe 'auto_detect_overlay_device()'
        # Regression: the detection loop used to run in a pipe subshell, so the
        # preferred/usable/unformatted assignments were lost and the function
        # always returned empty. It must now return the chosen partition.
        setup() {
            detect_root_disk() { echo /dev/sda; }
            get_partition_info() {
                printf '%s\n' \
                    "/dev/sda1 512M vfat ALPINE_BOOT /boot" \
                    "/dev/sda2 2G squashfs - /" \
                    "/dev/sda4 50G ext4 ALPINE_DATA -"
            }
            is_usable_data_partition() {
                case "$1" in
                    /dev/sda4) echo preferred ;;
                    *) echo unusable ;;
                esac
            }
        }
        Before 'setup'

        It 'returns the preferred data partition (not empty)'
            When call auto_detect_overlay_device
            The output should equal "/dev/sda4"
        End

        It 'falls back to an unformatted partition when no preferred exists'
            is_usable_data_partition() {
                case "$1" in
                    /dev/sda4) echo unformatted ;;
                    *) echo unusable ;;
                esac
            }
            When call auto_detect_overlay_device
            The output should equal "/dev/sda4"
        End
    End

    Describe 'dm-verity wiring'
        Describe 'verity_enabled()'
            It 'is on when --verity'
                BeforeRun 'VERITY_MODE=on; HARDENED_MODE=false'
                When run verity_enabled
                The status should be success
            End
            It 'is off when --no-verity even if hardened'
                BeforeRun 'VERITY_MODE=off; HARDENED_MODE=true'
                When run verity_enabled
                The status should be failure
            End
            It 'auto-enables in hardened mode'
                BeforeRun 'VERITY_MODE=auto; HARDENED_MODE=true'
                When run verity_enabled
                The status should be success
            End
            It 'auto-disables when not hardened'
                BeforeRun 'VERITY_MODE=auto; HARDENED_MODE=false'
                When run verity_enabled
                The status should be failure
            End
        End

        Describe 'slot_kernel_opts()'
            It 'appends aaverity=1 when verity is on'
                BeforeCall 'VERITY_MODE=on'
                When call slot_kernel_opts
                The output should include "aaverity=1"
            End
            It 'omits aaverity when verity is off'
                BeforeCall 'VERITY_MODE=off'
                When call slot_kernel_opts
                The output should not include "aaverity"
            End
        End

        Describe 'kernel_supports_verity()'
            setup() { KROOT=$(mktemp -d); mkdir -p "$KROOT/boot"; }
            cleanup_dir() { rm -rf "$KROOT"; }
            BeforeEach 'setup'
            AfterEach 'cleanup_dir'

            It 'is true when CONFIG_DM_VERITY=m'
                printf 'CONFIG_BLK_DEV_DM=m\nCONFIG_DM_VERITY=m\n' > "$KROOT/boot/config-6.6"
                When call kernel_supports_verity "$KROOT"
                The status should be success
            End

            It 'is false when CONFIG_DM_VERITY is not set (Alpine linux-rpi)'
                printf 'CONFIG_BLK_DEV_DM=m\n# CONFIG_DM_VERITY is not set\n' > "$KROOT/boot/config-6.6"
                When call kernel_supports_verity "$KROOT"
                The status should be failure
            End
        End

        Describe 'format_verity_slot()'
            setup() {
                TESTDIR=$(mktemp -d)
                MOCK_BIN_DIR="$TESTDIR/bin"; mkdir -p "$MOCK_BIN_DIR"
                # Fake squashfs image (small) + fake block device (regular file
                # the mocks accept; we stub dd/[-b checks via mock veritysetup).
                printf 'IMG' > "$TESTDIR/img.sq"
                # Mock veritysetup: emit a canned Root hash / Salt block.
                make_mock_bin veritysetup 'case "$1" in
  format) printf "VERITY header information\nRoot hash:\tabc123\nSalt:\tdeadbeef\n"; : > "$3" ;;
esac
exit 0'
                # dd / sync no-ops
                make_mock_bin dd 'exit 0'
                make_mock_bin sync 'exit 0'
                PATH="$MOCK_BIN_DIR:$PATH"
                # Accept our regular-file stand-in as a block device.
                is_block_device() { return 0; }
            }
            cleanup_dir() { rm -rf "$TESTDIR"; }
            BeforeEach 'setup'
            AfterEach 'cleanup_dir'

            It 'parses root hash + salt and echoes the meta line'
                When call format_verity_slot "$TESTDIR/img.sq" "$TESTDIR/slot.dev"
                The status should be success
                The output should include "abc123"
                The output should include "deadbeef"
                The stderr should be defined
            End
        End
    End

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

    Describe 'resolve_init_system()'
        It 'defaults to openrc when not hardened'
            HARDENED_MODE=false; INIT_SYSTEM=""
            When call resolve_init_system
            The variable INIT_SYSTEM should equal openrc
        End
        It 'defaults to s6 when hardened'
            HARDENED_MODE=true; INIT_SYSTEM=""
            When call resolve_init_system
            The variable INIT_SYSTEM should equal s6
        End
        It 'respects an explicit choice'
            HARDENED_MODE=true; INIT_SYSTEM=openrc
            When call resolve_init_system
            The variable INIT_SYSTEM should equal openrc
        End
        It 'rejects an invalid value'
            INIT_SYSTEM=runit
            When run resolve_init_system
            The status should be failure
            The stderr should include "Invalid --init"
        End
    End

    Describe 'install_ab_services()'
        setup() { ROOT=$(mktemp -d); INIT_SYSTEM=openrc; }
        cleanup() { rm -rf "$ROOT"; }
        Before 'setup'
        After 'cleanup'

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

        It 'installs aa in /usr/local/bin and the full tool in /usr/local/share'
            When call bake_management_tools "$ROOT"
            The path "$ROOT/usr/local/bin/aa" should be exist
            The contents of file "$ROOT/usr/local/bin/aa" should include "/usr/local/share/alpine-anywhere/alpine-anywhere"
            The path "$ROOT/usr/local/share/alpine-anywhere/alpine-anywhere" should be exist
            The path "$ROOT/usr/local/share/alpine-anywhere/lib/upgrade.sh" should be exist
            The stderr should be defined
        End

    End

    Describe 'wrap_boot_initramfs()'
        setup() {
            WD=$(mktemp -d)
            # init.aa is now resolved from ${SCRIPT_DIR}/lib/initramfs/init.aa;
            # point SCRIPT_DIR at the repo root so the real file is used.
            SCRIPT_DIR="$PWD"
            SRC="$WD/src"
            mkdir -p "$SRC/bin" "$SRC/sbin"
            # Minimal Alpine-like initramfs init ending in an exec switch_root.
            printf '#!/bin/sh\nmount -t proc proc /proc\nexec switch_root "$sysroot" /sbin/init "$@"\n' > "$SRC/init"
            chmod +x "$SRC/init"
            ( cd "$SRC" && find . | cpio -o -H newc 2>/dev/null | gzip ) > "$WD/initramfs"
        }
        cleanup() { rm -rf "$WD"; }
        Before 'setup'
        After 'cleanup'

        # wrap, repack, then unpack and report what we find
        wrap_and_inspect() {
            wrap_boot_initramfs "$WD/initramfs" >/dev/null 2>&1
            mkdir -p "$WD/out"
            ( cd "$WD/out" && gzip -dc "$WD/initramfs" | cpio -idm 2>/dev/null )
            [ -x "$WD/out/sbin/init.aa" ] && echo "HAS_GUARD_FILE"
            # guard call must appear BEFORE the switch_root line
            awk '/\/sbin\/init\.aa/{g=NR} /exec .*switch_root/{s=NR} END{ if (g>0 && s>0 && g<s) print "ORDER_OK" }' "$WD/out/init"
            # the guard must receive the init's own root + sysroot (they are passed
            # because /proc and /dev are moved into $sysroot before switch_root)
            grep -q '/sbin/init.aa "$KOPT_root" "$sysroot"' "$WD/out/init" && echo "ARGS_OK"
            # idempotent: a second wrap must not insert the call twice
            wrap_boot_initramfs "$WD/initramfs" >/dev/null 2>&1
            rm -rf "$WD/out"; mkdir -p "$WD/out"
            ( cd "$WD/out" && gzip -dc "$WD/initramfs" | cpio -idm 2>/dev/null )
            echo "GUARD_CALLS=$(grep -c '/sbin/init.aa' "$WD/out/init")"
        }

        It 'injects /sbin/init.aa (with KOPT_root+sysroot args) before switch_root, idempotently'
            command -v cpio >/dev/null 2>&1 || Skip "cpio not available"
            When call wrap_and_inspect
            The output should include "HAS_GUARD_FILE"
            The output should include "ORDER_OK"
            The output should include "ARGS_OK"
            The output should include "GUARD_CALLS=1"
        End

        # When verity is enabled, aa-verity-open is embedded and a call inserted
        # before the root mount (anchored on `mount ... $sysroot`).
        wrap_verity_inspect() {
            VERITY_MODE=on
            # Rebuild the fixture init with a root-mount line for the verity anchor.
            printf '#!/bin/sh\nmount -t proc proc /proc\nmount -o ro "$KOPT_root" "$sysroot"\nexec switch_root "$sysroot" /sbin/init "$@"\n' > "$SRC/init"
            chmod +x "$SRC/init"
            ( cd "$SRC" && find . | cpio -o -H newc 2>/dev/null | gzip ) > "$WD/initramfs"
            wrap_boot_initramfs "$WD/initramfs" >/dev/null 2>&1
            rm -rf "$WD/out"; mkdir -p "$WD/out"
            ( cd "$WD/out" && gzip -dc "$WD/initramfs" | cpio -idm 2>/dev/null )
            [ -x "$WD/out/sbin/aa-verity-open" ] && echo "HAS_VERITY_FILE"
            awk '/aa-verity-open/{v=NR} /mount .*\$sysroot/{m=NR} END{ if (v>0 && m>0 && v<m) print "VERITY_BEFORE_MOUNT" }' "$WD/out/init"
        }

        It 'embeds aa-verity-open and calls it before the root mount when --verity'
            command -v cpio >/dev/null 2>&1 || Skip "cpio not available"
            When call wrap_verity_inspect
            The output should include "HAS_VERITY_FILE"
            The output should include "VERITY_BEFORE_MOUNT"
        End
    End

    Describe 'persist_host_keys()'
        setup() {
            HARDENED_MODE=false
            SSH_HOST_KEY_DIR=""
            KEYSRC=$(mktemp -d)
            ROOT=$(mktemp -d)
            printf 'PRIV' > "$KEYSRC/ssh_host_ed25519_key"
            printf 'PUB'  > "$KEYSRC/ssh_host_ed25519_key.pub"
        }
        cleanup() { rm -rf "$KEYSRC" "$ROOT"; }
        Before 'setup'
            After 'cleanup'

        It 'reuses the provided OpenSSH host identity for an OpenSSH image'
            SSH_HOST_KEY_DIR="$KEYSRC"
            When call persist_host_keys "$ROOT"
            The path "$ROOT/etc/ssh/ssh_host_ed25519_key" should be exist
            The path "$ROOT/etc/ssh/ssh_host_ed25519_key.pub" should be exist
            The stderr should include "reusing OpenSSH host keys"
        End
    End

    Describe 'capture_host_identity()'
        setup() {
            DEST=$(mktemp -d)
            FAKE_SSH=$(mktemp -d)   # stand-in we point at via a tiny wrapper
        }
        cleanup() { rm -rf "$DEST" "$FAKE_SSH"; }
        Before 'setup'
            After 'cleanup'

        It 'returns non-zero when the source has no host keys'
            # /etc/ssh and /etc/dropbear have no ssh_host_*/dropbear_* on the CI box
            ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 && Skip "host has OpenSSH keys"
            When call capture_host_identity "$DEST"
            The status should be failure
            The stderr should be defined
        End
    End
End
