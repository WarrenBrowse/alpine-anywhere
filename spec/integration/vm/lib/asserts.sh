#!/bin/sh
# asserts.sh - read the installed system's A/B state over SSH so the harness can
# assert which slot actually booted. Mirrors `aa status` output (lib/upgrade.sh):
#   Running slot:  A   (booted from /dev/vda2)
#   Boot slot:     B   (next boot -> ...)
#   Slot A [running] [boot]:
#     Boot count: 0
#     Verified:   true

# aa lives in /usr/local/bin + /usr/sbin; a non-login ssh shell may not have those
# on PATH, so fall back to explicit paths.
aa_status() {
    vm_ssh 'aa status 2>/dev/null || /usr/sbin/aa status 2>/dev/null || /usr/local/bin/aa status 2>/dev/null'
}

# running_slot -> A | B | "" (the slot the kernel actually booted from)
running_slot() {
    aa_status | awk '/^Running slot:/{print $3; exit}'
}

# boot_slot -> A | B | "" (the slot configured for the NEXT boot)
boot_slot() {
    aa_status | awk '/^Boot slot:/{print $3; exit}'
}

# slot_field SLOT LABEL -> value of a per-slot field from `aa status` (e.g.
# "Boot count", "Verified", "Version"). Parses the "Slot <S> ...:" block so we
# never have to remount the boot partition ourselves.
slot_field() {
    aa_status | awk -v s="^Slot $1( |\\[|:)" -v l="$2" '
        $0 ~ s        { inb=1; next }
        /^Slot /      { inb=0 }
        inb && index($0, l ":") {
            sub(".*" l ":[ \t]*", ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit
        }'
}

# is_alpine -> success if the booted system is Alpine
is_alpine() { vm_ssh 'test -f /etc/alpine-release' 2>/dev/null; }

# init_system -> s6 | openrc | unknown
init_system() {
    vm_ssh 'if [ -d /run/s6 ] || pgrep -x s6-svscan >/dev/null 2>&1; then echo s6; \
            elif command -v rc-status >/dev/null 2>&1; then echo openrc; else echo unknown; fi' 2>/dev/null
}
