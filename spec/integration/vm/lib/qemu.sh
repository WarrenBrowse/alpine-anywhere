#!/bin/sh
# qemu.sh - QEMU lifecycle helpers for the VM integration harness.
#
# These functions drive a single disposable guest over user-mode networking
# (host SSH forwarded to guest :22). They are deliberately provider-agnostic:
# the same primitives boot the seed OS, survive an alpine-anywhere takeover,
# and ride through the auto-reboots that the boot-counter rollback triggers.
#
# Relies on these globals (set by run.sh):
#   VM_QEMU       qemu-system-x86_64 binary
#   VM_PIDFILE    pidfile path
#   VM_SERIAL     serial-console log path
#   VM_SSH_PORT   host port forwarded to guest :22
#   VM_SSH_KEY    private key authorized on the guest
#   VM_RAM_MB / VM_ACCEL / VM_CPU

# SSH options for OUR assertions: a throwaway VM, so never touch known_hosts and
# never wedge on a changed host key (alpine-anywhere itself uses accept-new TOFU
# for its own connection; that is independent of this).
VM_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-o GlobalKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=8 \
-o IdentitiesOnly=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
-o LogLevel=ERROR"

# Resolve the acceleration backend once. KVM when the runner exposes a writable
# /dev/kvm (GitHub ubuntu-latest does), else TCG (correct but slow).
qemu_resolve_accel() {
    case "${AA_VM_ACCEL:-auto}" in
        kvm) echo kvm ;;
        tcg) echo tcg ;;
        *)   if [ -w /dev/kvm ]; then echo kvm; else echo tcg; fi ;;
    esac
}

# vm_ssh CMD...  - run a command on the guest as root, capturing its output.
vm_ssh() {
    # shellcheck disable=SC2086
    ssh $VM_SSH_OPTS -i "$VM_SSH_KEY" -p "$VM_SSH_PORT" root@127.0.0.1 "$@"
}

# vm_scp_to LOCAL REMOTE
vm_scp_to() {
    # shellcheck disable=SC2086
    scp $VM_SSH_OPTS -i "$VM_SSH_KEY" -P "$VM_SSH_PORT" "$1" "root@127.0.0.1:$2"
}

vm_is_running() {
    [ -f "$VM_PIDFILE" ] || return 1
    kill -0 "$(cat "$VM_PIDFILE" 2>/dev/null)" 2>/dev/null
}

# _vm_launch DEVICE_ARGS...  - common QEMU launch (backgrounded/daemonized). The
# caller passes the disk/cdrom -drive/-device args; everything else is fixed.
_vm_launch() {
    local accel cpu
    accel="$VM_ACCEL"
    if [ "$accel" = kvm ]; then cpu="host"; else cpu="max"; fi
    log "QEMU: accel=$accel cpu=$cpu ram=${VM_RAM_MB}M port=$VM_SSH_PORT"
    # -display none + -serial file is daemonize-safe (-nographic is not).
    "$VM_QEMU" \
        -name aa-vm \
        -machine "type=q35,accel=${accel}" \
        -cpu "$cpu" -smp 2 -m "${VM_RAM_MB}" \
        "$@" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=n0 \
        -display none -serial "file:${VM_SERIAL}" -monitor none \
        -pidfile "$VM_PIDFILE" -daemonize \
        || return 1
    sleep 1
    vm_is_running || { err "QEMU failed to start; serial tail:"; serial_tail; return 1; }
    return 0
}

# vm_start_seed SEED_DISK TARGET_DISK CIDATA_ISO
#
# Boot the stock Alpine cloud seed (the live control plane) from vda, with the
# blank install target attached as vdb and the NoCloud seed on cdrom. The seed
# cloud image carries its root on the whole vda device, so we never repartition
# vda; alpine-anywhere installs onto the separate blank vdb (which is how an
# installer is normally driven - from a live environment onto the destination
# disk). Only the seed is bootable here, so there is no boot-order ambiguity.
vm_start_seed() {
    # The NoCloud seed is attached as a read-only DISK (not -cdrom): cloud-init's
    # NoCloud datasource probes block devices by filesystem label (cidata), and
    # some images (Debian) do not scan the CD-ROM for it. A disk is found reliably.
    _vm_launch \
        -drive "if=none,id=seed,file=$1,format=qcow2,cache=writeback" \
        -device virtio-blk-pci,drive=seed,bootindex=0 \
        -drive "if=none,id=target,file=$2,format=qcow2,cache=writeback" \
        -device virtio-blk-pci,drive=target,bootindex=1 \
        -drive "if=none,id=cidata,file=$3,format=raw,readonly=on" \
        -device virtio-blk-pci,drive=cidata
}

# vm_start_installed TARGET_DISK
#
# Boot the freshly installed system from the target disk ALONE (the seed is gone).
# It becomes vda in the guest, but alpine-anywhere boots by root=PARTUUID, so the
# rename is irrelevant - and booting it alone keeps `aa status` from mis-detecting
# the still-present seed as the boot disk. The network is name-agnostic (the
# install's --custom-script baked eth0 DHCP), so the changed PCI topology is fine.
# Every reboot thereafter (upgrade/rollback) is a plain reboot within this VM.
vm_start_installed() {
    _vm_launch \
        -drive "if=none,id=target,file=$1,format=qcow2,cache=writeback" \
        -device virtio-blk-pci,drive=target,bootindex=0
}

vm_stop() {
    vm_is_running || { rm -f "$VM_PIDFILE"; return 0; }
    local pid; pid="$(cat "$VM_PIDFILE" 2>/dev/null)"
    kill "$pid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$VM_PIDFILE"
}

vm_boot_id() {
    vm_ssh 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' 2>/dev/null
}

serial_tail() {
    [ -f "$VM_SERIAL" ] || return 0
    echo "----- serial console (last 40 lines) -----" >&2
    tail -n 40 "$VM_SERIAL" >&2 2>/dev/null || true
    echo "-------------------------------------------" >&2
}

# vm_wait_ssh TIMEOUT  - block until the guest answers SSH.
vm_wait_ssh() {
    local timeout="$1" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if vm_is_running && vm_ssh true 2>/dev/null; then return 0; fi
        sleep 5; waited=$((waited + 5))
        if ! vm_is_running; then err "QEMU exited while waiting for SSH"; serial_tail; return 1; fi
    done
    err "timed out (${timeout}s) waiting for guest SSH"
    serial_tail
    return 1
}

# vm_wait_stable_boot TIMEOUT - SSH up AND boot_id unchanged for STABLE seconds.
# The boot-counter rollback can reboot the guest a second time on its own; this
# rides that out so assertions never race a half-finished boot.
vm_wait_stable_boot() {
    local timeout="$1" stable=12 last="" cur same=0 waited=0
    vm_wait_ssh "$timeout" || return 1
    while [ "$waited" -lt "$timeout" ]; do
        cur="$(vm_boot_id)"
        if [ -n "$cur" ] && [ "$cur" = "$last" ]; then
            same=$((same + 3))
            [ "$same" -ge "$stable" ] && return 0
        else
            same=0; last="$cur"
        fi
        sleep 3; waited=$((waited + 3))
        vm_is_running || { err "QEMU exited during boot settle"; serial_tail; return 1; }
    done
    # Settled enough to proceed even if boot_id kept jittering.
    [ -n "$last" ] && return 0
    return 1
}
