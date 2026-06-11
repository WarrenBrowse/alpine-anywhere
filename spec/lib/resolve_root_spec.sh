#!/bin/sh
# resolve_root_spec.sh - Unit tests for lib/initramfs/aa-resolve-root
#
# aa-resolve-root turns a tag-style root spec (PARTUUID=/PARTLABEL=/.../dev path)
# into a concrete /dev node by reading the GPT directly with dd+hexdump. We build
# a sandbox "disk" (a regular file holding a minimal GPT) plus a fake sysfs tree
# so the resolver runs unmodified with AA_SYS/AA_DEV pointed at the sandbox.

Describe 'aa-resolve-root'
    RR="lib/initramfs/aa-resolve-root"

    # Write the raw bytes of a hex string to a file at a byte offset (portable:
    # POSIX printf octal escapes; no gawk strtonum / GNU dd iflag needed).
    write_hex_at() {  # $1=hexstring $2=file $3=offset
        _hx="$1"; _f="$2"; _ofs="$3"
        _i=1
        while [ "$_i" -le ${#_hx} ]; do
            _byte=$(printf '%s' "$_hx" | cut -c "$_i"-"$((_i + 1))")
            _oct=$(printf '%o' "$((0x$_byte))")
            printf "\\$_oct" | dd of="$_f" bs=1 seek="$_ofs" conv=notrunc 2>/dev/null
            _ofs=$((_ofs + 1)); _i=$((_i + 2))
        done
    }

    setup() {
        SANDBOX=$(mktemp -d)
        export AA_SYS="$SANDBOX/sys"
        export AA_DEV="$SANDBOX/dev"
        mkdir -p "$AA_DEV" "$AA_SYS/class/block" \
                 "$AA_SYS/devices/pci/block/sda/sda1" \
                 "$AA_SYS/devices/pci/block/sda/sda2"
        # A 4 KiB zeroed "disk". GPT header is left zero on purpose so the resolver
        # falls back to the universal layout (entry array @ LBA2, 128-byte entries).
        dd if=/dev/zero of="$AA_DEV/sda" bs=1 count=4096 2>/dev/null
        : > "$AA_DEV/sda1"; : > "$AA_DEV/sda2"
        # Partition entry K (1-indexed) unique-GUID lives at 2*512 + (K-1)*128 + 16.
        # GUID is stored mixed-endian: first three groups byte-reversed.
        #   sda1 PARTUUID 12345678-9abc-def0-1122-334455667788
        write_hex_at "78563412bc9af0de1122334455667788" "$AA_DEV/sda" $((1024 + 0 * 128 + 16))
        #   sda2 PARTUUID aabbccdd-eeff-0011-2233-445566778899
        write_hex_at "ddccbbaaffee11002233445566778899" "$AA_DEV/sda" $((1024 + 1 * 128 + 16))
        # Fake sysfs: each partition has a `partition` file and is a symlink whose
        # parent dir basename is the disk ("sda"), matching the real layout.
        for n in 1 2; do
            printf '%s\n' "$n" > "$AA_SYS/devices/pci/block/sda/sda${n}/partition"
            printf 'PARTNAME=slot%s\n' "$n" > "$AA_SYS/devices/pci/block/sda/sda${n}/uevent"
            ln -s "../../devices/pci/block/sda/sda${n}" "$AA_SYS/class/block/sda${n}"
        done
    }
    cleanup() { rm -rf "$SANDBOX"; }
    Before 'setup'
    After 'cleanup'

    It 'resolves a PARTUUID to the matching /dev node'
        When run sh "$RR" "PARTUUID=aabbccdd-eeff-0011-2233-445566778899"
        The status should be success
        The output should equal "$SANDBOX/dev/sda2"
    End

    It 'resolves the first partition PARTUUID too'
        When run sh "$RR" "PARTUUID=12345678-9abc-def0-1122-334455667788"
        The status should be success
        The output should equal "$SANDBOX/dev/sda1"
    End

    It 'is case-insensitive on the PARTUUID'
        When run sh "$RR" "PARTUUID=AABBCCDD-EEFF-0011-2233-445566778899"
        The status should be success
        The output should equal "$SANDBOX/dev/sda2"
    End

    It 'prints nothing for an unknown PARTUUID (caller falls back)'
        When run sh "$RR" "PARTUUID=00000000-0000-0000-0000-000000000000"
        The status should be success
        The output should equal ""
    End

    It 'resolves a PARTLABEL via the kernel PARTNAME uevent'
        When run sh "$RR" "PARTLABEL=slot2"
        The status should be success
        The output should equal "$SANDBOX/dev/sda2"
    End

    It 'echoes a bare /dev path back unchanged'
        When run sh "$RR" "/dev/sda2"
        The status should be success
        The output should equal "/dev/sda2"
    End

    It 'passes filesystem UUID= through unchanged (busybox findfs handles it)'
        When run sh "$RR" "UUID=1234-5678"
        The status should be success
        The output should equal "UUID=1234-5678"
    End

    It 'exits cleanly on empty input'
        When run sh "$RR" ""
        The status should be success
        The output should equal ""
    End
End
