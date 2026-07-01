#!/bin/sh
# init_aa_spec.sh - Unit tests for the A/B boot-guard lib/initramfs/init.aa
#
# init.aa is a standalone script run before switch_root. We exercise its
# rollback logic in a sandbox: AA_BOOT_DIR points at a temp dir we pre-populate,
# and mount/umount/reboot/sync are mocked as no-ops so the script runs to
# completion and we can inspect what it wrote.

Describe 'init.aa boot-guard'
    INIT_AA="lib/initramfs/init.aa"

    setup() {
        SANDBOX=$(mktemp -d)
        export AA_BOOT_DIR="$SANDBOX/aa-boot"
        mkdir -p "$AA_BOOT_DIR"
        export MOCK_BIN_DIR="$SANDBOX/bin"
        mkdir -p "$MOCK_BIN_DIR"
        # No-op the system-mutating applets. reboot just records that it fired.
        for b in mount umount sync reboot; do
            printf '#!/bin/sh\n' > "$MOCK_BIN_DIR/$b"
            chmod +x "$MOCK_BIN_DIR/$b"
        done
        printf '#!/bin/sh\necho fired >> "%s/reboot.fired"\n' "$SANDBOX" > "$MOCK_BIN_DIR/reboot"
        chmod +x "$MOCK_BIN_DIR/reboot"
        PATH="$MOCK_BIN_DIR:$PATH"
    }
    cleanup() { rm -rf "$SANDBOX"; }
    Before 'setup'
    After 'cleanup'

    # Write a slots.meta + RPi config to the sandbox boot dir.
    seed_meta() { printf '%s\n' "$@" > "$AA_BOOT_DIR/slots.meta"; }
    seed_config() {
        printf 'kernel=vmlinuz-A\ninitramfs initramfs-A followkernel\n' > "$AA_BOOT_DIR/config.txt"
        printf 'root=/dev/sda2 rootfstype=squashfs\n' > "$AA_BOOT_DIR/cmdline.txt"
    }

    It 'skips quietly when root is not an A/B slot'
        When run sh "$INIT_AA" /dev/sda1 ""
        The status should be success
        The output should include "not an A/B slot"
        The stderr should be defined
    End

    It 'increments the boot counter on a normal first boot (no rollback)'
        seed_meta "SLOT_A_VERSION=3.20" "SLOT_A_VERIFIED=false" "SLOT_A_BOOT_COUNT=0" \
                  "SLOT_B_VERSION=3.20" "SLOT_B_VERIFIED=true" "SLOT_B_BOOT_COUNT=0"
        seed_config
        When run sh "$INIT_AA" /dev/sda2 ""
        The status should be success
        The contents of file "$AA_BOOT_DIR/slots.meta" should include "SLOT_A_BOOT_COUNT=1"
        The path "$SANDBOX/reboot.fired" should not be exist
        The stdout should be defined
        The stderr should be defined
    End

    It 'rolls back to the other slot on the 2nd unverified boot'
        seed_meta "SLOT_A_VERSION=3.20" "SLOT_A_VERIFIED=false" "SLOT_A_BOOT_COUNT=1" \
                  "SLOT_B_VERSION=3.20" "SLOT_B_VERIFIED=true" "SLOT_B_BOOT_COUNT=0"
        seed_config
        When run sh "$INIT_AA" /dev/sda2 ""
        The status should be success
        The contents of file "$AA_BOOT_DIR/config.txt" should include "kernel=vmlinuz-B"
        The contents of file "$AA_BOOT_DIR/cmdline.txt" should include "root=/dev/sda3"
        The contents of file "$AA_BOOT_DIR/current_slot" should include "B"
        # rollback target counter reset (avoids ping-pong)
        The contents of file "$AA_BOOT_DIR/slots.meta" should include "SLOT_B_BOOT_COUNT=0"
        The path "$SANDBOX/reboot.fired" should be exist
        The stdout should be defined
        The stderr should be defined
    End

    It 'rolls back on a GRUB-only boot partition (no config.txt, no extlinux)'
        seed_meta "SLOT_A_VERSION=3.20" "SLOT_A_VERIFIED=false" "SLOT_A_BOOT_COUNT=1" \
                  "SLOT_B_VERSION=3.20" "SLOT_B_VERIFIED=true" "SLOT_B_BOOT_COUNT=0"
        mkdir -p "$AA_BOOT_DIR/grub"
        printf 'set default=alpine-A\n' > "$AA_BOOT_DIR/grub/grub_aa_default.cfg"
        When run sh "$INIT_AA" /dev/sda2 ""
        The status should be success
        The contents of file "$AA_BOOT_DIR/grub/grub_aa_default.cfg" should include "set default=alpine-B"
        The contents of file "$AA_BOOT_DIR/current_slot" should include "B"
        The contents of file "$AA_BOOT_DIR/slots.meta" should include "SLOT_B_BOOT_COUNT=0"
        The path "$SANDBOX/reboot.fired" should be exist
        The stdout should be defined
        The stderr should be defined
    End

    It 'does not roll back when the other slot has no image'
        seed_meta "SLOT_A_VERSION=3.20" "SLOT_A_VERIFIED=false" "SLOT_A_BOOT_COUNT=1" \
                  "SLOT_B_VERSION=" "SLOT_B_VERIFIED=false" "SLOT_B_BOOT_COUNT=0"
        seed_config
        When run sh "$INIT_AA" /dev/sda2 ""
        The status should be success
        The output should include "cannot roll back"
        The path "$SANDBOX/reboot.fired" should not be exist
        The contents of file "$AA_BOOT_DIR/config.txt" should include "kernel=vmlinuz-A"
        The stderr should be defined
    End

    It 'stops flipping once BOOT_HALTED is set (no reboot loop)'
        seed_meta "BOOT_HALTED=1" \
                  "SLOT_A_VERSION=3.20" "SLOT_A_VERIFIED=false" "SLOT_A_BOOT_COUNT=5" \
                  "SLOT_B_VERSION=3.20" "SLOT_B_VERIFIED=false" "SLOT_B_BOOT_COUNT=5"
        seed_config
        When run sh "$INIT_AA" /dev/sda2 ""
        The status should be success
        The output should include "BOOT_HALTED"
        The path "$SANDBOX/reboot.fired" should not be exist
        The stderr should be defined
    End

    It 'exits cleanly when slots.meta is missing'
        seed_config
        When run sh "$INIT_AA" /dev/sda2 ""
        The status should be success
        The output should include "no slots.meta"
        The stderr should be defined
    End
End
