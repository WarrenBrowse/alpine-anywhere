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

    It 'opens the mapper when a base64 minisig is present and minisign verifies'
        # ROOT_HASH_SIG is the base64 of the detached minisig; the opener must
        # decode it, hand a real minisig to minisign, and open on success.
        sig_b64=$(printf 'untrusted comment: x\nRWQsig\ntrusted comment: t\nRWQglobal\n' | base64 | tr -d '\n')
        printf 'SLOT_A_ROOT_HASH=deadbeef\nSLOT_A_DATA_SIZE=4096\nSLOT_A_ROOT_HASH_SIG=%s\n' "$sig_b64" > "${BOOTD}/slots.meta"
        printf 'untrusted comment: pk\nRWQ...\n' > "${BOOTD}/nope.pub"
        # minisign mock asserts it received a decodable 4-line minisig, not the
        # raw base64: fail unless the sig file starts with "untrusted comment:".
        make_mock_bin minisign 'f=""; prev=""; for a in "$@"; do case "$prev" in -x) f="$a";; esac; prev="$a"; done; head -n1 "$f" | grep -q "^untrusted comment:" || exit 3; exit 0'
        When run sh lib/initramfs/aa-verity-open /dev/sda2 ""
        The status should be success
        The output should include "/dev/mapper/aa-root"
        The stderr should be defined
    End

    It 'refuses when the stored signature is not valid base64'
        printf 'SLOT_A_ROOT_HASH=deadbeef\nSLOT_A_DATA_SIZE=4096\nSLOT_A_ROOT_HASH_SIG=@@not-base64@@\n' > "${BOOTD}/slots.meta"
        printf 'untrusted comment: pk\nRWQ...\n' > "${BOOTD}/nope.pub"
        # base64 -d must reject the payload; force a strict decoder mock.
        make_mock_bin base64 'if [ "$1" = "-d" ] || [ "$1" = "-D" ]; then echo "$0: invalid input" >&2; exit 1; fi; exec /usr/bin/base64 "$@"'
        When run sh lib/initramfs/aa-verity-open /dev/sda2 ""
        The status should be failure
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
