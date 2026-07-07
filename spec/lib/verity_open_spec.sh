#!/bin/sh
# verity_open_spec.sh - functional tests for the initramfs dm-verity opener.
# Exercises the security-critical decision logic (slot detection, the S3
# signature-required guard, and the no-pubkey fallback) by running the real
# script with mounts/veritysetup/minisign mocked and the boot dir + pubkey path
# pointed at test fixtures (AA_BOOT_DIR / AA_VERITY_PUBKEY seams).

Describe 'aa-verity-open'
    setup() {
        BOOTD=$(mktemp -d)
        MOCK_BIN_DIR=$(mktemp -d)
        PATH="${MOCK_BIN_DIR}:$PATH"
        export MOCK_BIN_DIR
        # Mounts/module loads are no-ops: AA_BOOT_DIR is pre-populated in place.
        make_mock_bin mount 'exit 0'
        make_mock_bin umount 'exit 0'
        make_mock_bin modprobe 'exit 0'
        make_mock_bin findfs 'exit 1'
        # veritysetup/minisign default to SUCCESS; individual tests override.
        make_mock_bin veritysetup 'exit 0'
        make_mock_bin minisign 'exit 0'
        AA_BOOT_DIR="$BOOTD"
        AA_MAPPER="aa-root"
        AA_VERITY_PUBKEY="${BOOTD}/nope.pub"   # absent by default
        export AA_BOOT_DIR AA_MAPPER AA_VERITY_PUBKEY
    }
    cleanup() { rm -rf "$BOOTD" "$MOCK_BIN_DIR"; }
    Before 'setup'
    After 'cleanup'

    It 'refuses a root device that is not an A/B slot'
        When run sh lib/initramfs/aa-verity-open /dev/sda9 ""
        The status should be failure
        The stderr should be defined
    End

    It 'refuses when ROOT_HASH/DATA_SIZE are missing'
        printf 'SLOT_A_VERSION=3.20\n' > "${BOOTD}/slots.meta"
        When run sh lib/initramfs/aa-verity-open /dev/sda2 ""
        The status should be failure
        The stderr should be defined
    End

    It 'refuses a signed-required slot with no signature (downgrade guard)'
        printf 'SLOT_A_ROOT_HASH=deadbeef\nSLOT_A_DATA_SIZE=4096\n' > "${BOOTD}/slots.meta"
        printf 'untrusted comment: pk\nRWQ...\n' > "${BOOTD}/nope.pub"   # pubkey now present
        When run sh lib/initramfs/aa-verity-open /dev/sda2 ""
        The status should be failure
        The stderr should be defined
    End

    It 'opens the verified mapper when no pubkey is embedded and veritysetup succeeds'
        printf 'SLOT_A_ROOT_HASH=deadbeef\nSLOT_A_DATA_SIZE=4096\n' > "${BOOTD}/slots.meta"
        When run sh lib/initramfs/aa-verity-open /dev/sda2 ""
        The status should be success
        The output should include "/dev/mapper/aa-root"
        The stderr should be defined
    End

    It 'refuses when veritysetup fails (corrupt or tampered slot)'
        printf 'SLOT_A_ROOT_HASH=deadbeef\nSLOT_A_DATA_SIZE=4096\n' > "${BOOTD}/slots.meta"
        make_mock_bin veritysetup 'exit 1'
        When run sh lib/initramfs/aa-verity-open /dev/sda2 ""
        The status should be failure
        The stderr should be defined
    End
End
