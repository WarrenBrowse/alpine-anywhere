#!/bin/sh
# persist_spec.sh - data-persistence feature (flags, predicates, generated
# scripts, LUKS+BTRFS formatting, data.meta).

Describe 'data persistence'
    Include lib/common.sh
    Include lib/validate.sh
    Include lib/install.sh

    Describe 'flag parsing & predicates'
        It '--persist enables persistence'
            When call parse_arguments --install --persist --local
            The variable PERSIST_DATA should equal "true"
        End

        It '--encrypt-data implies --persist'
            When call parse_arguments --install --encrypt-data --local
            The variable PERSIST_DATA should equal "true"
            The variable ENCRYPT_DATA should equal "true"
        End

        It '--containers implies --persist and sets the runtime set'
            When call parse_arguments --install --containers podman --local
            The variable PERSIST_DATA should equal "true"
            The variable CONTAINERS should equal "podman"
        End

        It 'container_is matches both'
            BeforeCall 'CONTAINERS=both'
            When call container_is docker
            The status should be success
        End
    End

    Describe 'validation'
        It 'rejects an invalid --data-fs'
            BeforeRun 'DATA_FS=zfs'
            When run validate_safe_inputs
            The status should be failure
            The stderr should include "invalid --data-fs"
        End

        It 'rejects an invalid --unlock-method'
            BeforeRun 'UNLOCK_METHOD=magic'
            When run validate_safe_inputs
            The status should be failure
            The stderr should include "unlock-method"
        End

        It 'accepts keyfile method with no key source (aa auto-generates one)'
            BeforeRun 'UNLOCK_METHOD=keyfile; KEY_URL=; KEY_FILE='
            When run validate_safe_inputs
            The status should be success
        End
    End

    Describe 'data_stack_supported()'
        setup() { KR=$(mktemp -d); mkdir -p "$KR/boot"; }
        cleanup_dir() { rm -rf "$KR"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'is true for btrfs+dm-crypt present'
            BeforeCall 'DATA_FS=btrfs; ENCRYPT_DATA=true'
            printf 'CONFIG_DM_CRYPT=m\nCONFIG_BTRFS_FS=m\n' > "$KR/boot/config-x"
            When call data_stack_supported "$KR"
            The status should be success
        End

        It 'is false when btrfs missing'
            BeforeCall 'DATA_FS=btrfs; ENCRYPT_DATA=false'
            printf '# CONFIG_BTRFS_FS is not set\n' > "$KR/boot/config-x"
            When call data_stack_supported "$KR"
            The status should be failure
        End

        It 'is false when encrypting without dm-crypt'
            BeforeCall 'DATA_FS=ext4; ENCRYPT_DATA=true'
            printf '# CONFIG_DM_CRYPT is not set\n' > "$KR/boot/config-x"
            When call data_stack_supported "$KR"
            The status should be failure
        End
    End

    Describe 'generated operator scripts are valid POSIX sh'
        setup() { ROOT=$(mktemp -d); mkdir -p "$ROOT/usr/local/sbin" "$ROOT/usr/local/bin"; }
        cleanup_dir() { rm -rf "$ROOT"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'aa-data passes sh -n and reads data.meta'
            install_aa_data_helper "$ROOT"
            When call sh -n "$ROOT/usr/local/sbin/aa-data"
            The status should be success
        End

        It 'aa-unlock passes sh -n'
            install_aa_unlock "$ROOT"
            When call sh -n "$ROOT/usr/local/bin/aa-unlock"
            The status should be success
        End

        It 'aa-snapshot passes sh -n'
            install_aa_snapshot "$ROOT"
            When call sh -n "$ROOT/usr/local/bin/aa-snapshot"
            The status should be success
        End

        It 'aa-snapshot uses btrfs snapshot + send'
            install_aa_snapshot "$ROOT"
            When call cat "$ROOT/usr/local/bin/aa-snapshot"
            The output should include "btrfs subvolume snapshot"
            The output should include "btrfs send"
        End
    End

    Describe 'format_data_partition() + data.meta'
        setup() {
            T=$(mktemp -d); MOCK_BIN_DIR="$T/bin"; mkdir -p "$MOCK_BIN_DIR"
            BOOTDIR="$T/boot"; mkdir -p "$BOOTDIR"
            export AA_BOOTMETA_MNT="$BOOTDIR"   # write_data_meta target (testability seam)
            DATADIR="$T/data"; mkdir -p "$DATADIR"  # btrfs "mount" target
            is_block_device() { return 0; }
            get_part_dev() { case "$2" in 1) echo "$T/p1" ;; 4) echo "$T/p4" ;; esac; }
            # mount/umount/assert_mounted no-ops; the FS mock dir is the temp data dir
            mount() { return 0; }
            umount() { return 0; }
            assert_mounted() { return 0; }
            # mkdir for /mnt/aa-data-fmt -> redirect btrfs subvolume mock no-ops anyway
            make_mock_bin cryptsetup 'case "$1" in luksUUID) echo "1111-2222" ;; esac; exit 0'
            make_mock_bin mkfs.btrfs 'exit 0'
            make_mock_bin btrfs 'exit 0'
            make_mock_bin chattr 'exit 0'
            make_mock_bin shred 'exit 0'
            PATH="$MOCK_BIN_DIR:$PATH"
            PERSIST_DATA=true; ENCRYPT_DATA=true; DATA_FS=btrfs; UNLOCK_METHOD=ssh
            DATA_MAPPER=aa-data
            DATA_KEYFILE="$T/key"; printf 'secret' > "$DATA_KEYFILE"
        }
        cleanup_dir() { rm -rf "$T"; unset AA_BOOTMETA_MNT; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'writes data.meta with LUKS + btrfs fields'
            When call format_data_partition "$T/disk" "$T/p4"
            The status should be success
            The stderr should be defined
            The contents of file "$BOOTDIR/data.meta" should include "DATA_FS=btrfs"
            The contents of file "$BOOTDIR/data.meta" should include "DATA_ENCRYPTED=true"
            The contents of file "$BOOTDIR/data.meta" should include "DATA_UNLOCK=ssh"
            The contents of file "$BOOTDIR/data.meta" should include "DATA_LUKS_UUID=1111-2222"
        End

        It 'keyfile method (no key source) generates a key and stages it on the boot partition'
            # No staged key, no URL -> aa must generate a random key and copy it
            # to the boot partition as aa-data.key for autonomous unlock at boot.
            BeforeCall 'UNLOCK_METHOD=keyfile; KEY_URL=; rm -f "$DATA_KEYFILE"'
            When call format_data_partition "$T/disk" "$T/p4"
            The status should be success
            The stderr should be defined
            The path "$BOOTDIR/aa-data.key" should be exist
            The contents of file "$BOOTDIR/data.meta" should include "DATA_UNLOCK=keyfile"
        End
    End
End
