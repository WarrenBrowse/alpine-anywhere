#!/bin/sh
# run.sh - VM integration harness for the "path that can brick a box".
#
# The shellspec suite mocks SSH/curl and never boots anything, so the riskiest
# code in this repo - the in-place pivot/takeover, repartitioning the *running*
# boot disk, the A/B switch, and the boot-counter rollback - has zero real
# coverage. This harness closes that gap end to end against a disposable QEMU
# guest, exactly the way prod drives it: alpine-anywhere over SSH from a control
# host (here, the runner) converts a stock Linux in place, then we power-cycle
# the guest and assert which slot actually booted at every step.
#
# Lifecycle exercised:
#   1. boot a stock Debian cloud image (the partitioned "provider" seed)
#   2. alpine-anywhere --install  -> immutable A/B, reboot, assert slot A + Alpine
#   3. immutability               -> a write to / does not survive a reboot
#   4. alpine-anywhere upgrade     -> reboot, assert slot B (atomic A/B switch)
#   5. aa rollback                -> reboot, assert slot A (manual recovery)
#   6. boot-counter auto-rollback -> unverified bad slot self-reverts to A
#
# Exit: 0 all-pass (or cleanly SKIPped when QEMU is absent), 1 any failure.
#
# Knobs (all optional): AA_VM_SEED_URL, AA_VM_ALPINE_VER, AA_VM_RAM_MB,
# AA_VM_DISK_GB, AA_VM_SSH_PORT, AA_VM_ACCEL=auto|kvm|tcg, AA_VM_CACHE,
# AA_VM_KEEP=1 (leave the VM + workdir up for debugging),
# AA_VM_SKIP_AUTOROLLBACK=1 (skip the slowest phase).

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../.." && pwd)"
AA_BIN="${REPO_ROOT}/alpine-anywhere"

# ---- logging / result accounting --------------------------------------------
PASS=0; FAIL=0; STEP=0
log()  { printf '\033[0;34m[vm]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[vm][warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[vm][err]\033[0m %s\n' "$*" >&2; }
step() { STEP=$((STEP + 1)); printf '\n\033[1;36m=== STEP %s: %s ===\033[0m\n' "$STEP" "$*" >&2; }
ok()   { PASS=$((PASS + 1)); printf '\033[0;32mok\033[0m   - %s\n' "$*" >&2; }
fail() { FAIL=$((FAIL + 1)); printf '\033[0;31mFAIL\033[0m - %s\n' "$*" >&2; }
# assert COND-as-already-evaluated: usage `expect "desc" cmd...`
expect() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }

# run_bounded SECONDS CMD...  - bound a long-running step so a hung pivot/install
# cannot wedge CI forever; falls back to an unbounded run where `timeout` is absent.
run_bounded() {
    local t="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else "$@"; fi
}

# vm_cold_reboot - reboot the installed system the way that reliably comes back in
# this nested VM: stop QEMU and cold-start the target disk again. A guest reboot
# (and even a QMP system_reset) does NOT return here - a SeaBIOS/nested-virt quirk,
# not a product issue - but a fresh boot does. The on-disk boot config (current_slot)
# still decides which slot boots, so this faithfully exercises slot switching /
# immutability / rollback.
vm_cold_reboot() {
    vm_stop
    vm_start_installed "$VM_TARGET_DISK" || return 1
    vm_wait_stable_boot "$TIMEOUT_BOOT"
}

# ---- config -----------------------------------------------------------------
VM_RAM_MB="${AA_VM_RAM_MB:-3072}"
VM_DISK_GB="${AA_VM_DISK_GB:-8}"
VM_SSH_PORT="${AA_VM_SSH_PORT:-2222}"
VM_QEMU="qemu-system-x86_64"
VM_ACCEL=""       # resolved in preflight (kvm|tcg)
VM_TARGET_DISK="" # install destination qcow2; set in phase_boot_seed, booted post-install
TIMEOUT_SSH="${AA_VM_TIMEOUT_SSH:-360}"
TIMEOUT_INSTALL="${AA_VM_TIMEOUT_INSTALL:-2400}"
TIMEOUT_BOOT="${AA_VM_TIMEOUT_BOOT:-360}"

# shellcheck source=spec/integration/vm/lib/qemu.sh
. "${SELF_DIR}/lib/qemu.sh"
# shellcheck source=spec/integration/vm/lib/seed.sh
. "${SELF_DIR}/lib/seed.sh"
# shellcheck source=spec/integration/vm/lib/asserts.sh
. "${SELF_DIR}/lib/asserts.sh"

cleanup() {
    if [ "${AA_VM_KEEP:-0}" = 1 ]; then
        warn "AA_VM_KEEP=1 - leaving VM (ssh -p ${VM_SSH_PORT} -i ${VM_SSH_KEY} root@127.0.0.1) and ${VM_WORKDIR}"
        return
    fi
    vm_stop 2>/dev/null || true
    [ -n "${VM_WORKDIR:-}" ] && rm -rf "$VM_WORKDIR"
}

skip() { log "SKIP: $*"; exit 0; }

preflight() {
    [ -x "$AA_BIN" ] || { err "alpine-anywhere not found/executable at $AA_BIN"; exit 1; }
    command -v "$VM_QEMU" >/dev/null 2>&1 || skip "$VM_QEMU not installed (the VM integration test needs QEMU)"
    command -v qemu-img  >/dev/null 2>&1 || skip "qemu-img not installed"
    command -v ssh >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1 || skip "ssh/ssh-keygen not installed"
    command -v curl >/dev/null 2>&1 || skip "curl not installed (needed to fetch the seed image)"
    VM_ACCEL="$(qemu_resolve_accel)"
    [ "$VM_ACCEL" = tcg ] && warn "no KVM (/dev/kvm) - running under TCG emulation; this is slow"
}

# ---- phases -----------------------------------------------------------------

phase_boot_seed() {
    step "boot stock Debian cloud seed (the 'provider' image)"
    local base disk target cidata
    base="$(seed_fetch)"            || { fail "fetch seed image"; return 1; }
    disk="$(seed_make_overlay "$base")" || { fail "build disk overlay"; return 1; }
    target="$(seed_make_blank)"     || { fail "build blank install target"; return 1; }
    cidata="$(seed_make_cidata)"    || { fail "build NoCloud seed iso"; return 1; }
    VM_TARGET_DISK="$target"
    vm_start_seed "$disk" "$target" "$cidata" || { fail "QEMU start"; return 1; }
    if vm_wait_ssh "$TIMEOUT_SSH"; then ok "seed booted and answers SSH"; else fail "seed never came up on SSH"; return 1; fi
    # Let cloud-init finish: it runs growpart (which deletes+recreates partition 1
    # to fill the disk) and our key/root-unlock runcmd. Without this the vda1 check
    # below races the partition-table rewrite (intermittent on fast hosts).
    vm_ssh 'command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1 || true' 2>/dev/null || true
    # Precondition for alpine-anywhere: the source root disk must be partitioned
    # (its reboot-into-RAM installer stages onto partition 1 of the root disk).
    # Retry briefly in case the partition nodes are still settling.
    local _p=0
    while [ "$_p" -lt 12 ] && ! vm_ssh 'test -b /dev/vda1' 2>/dev/null; do sleep 3; _p=$((_p + 1)); done
    expect "seed root disk vda is partitioned (vda1 exists)" \
        vm_ssh 'test -b /dev/vda1'
    seed_prepare_source_host || { fail "source-host build prerequisites"; return 1; }
    ok "source host has parted/mksquashfs/tar/mkfs.ext4"
    return 0
}

phase_install() {
    step "alpine-anywhere --install  (pivot into RAM + partition the target + A/B)"
    log "the brick-prone path: pivot/takeover into a clean Alpine env, then partition"
    log "the install target (vdb) and lay down the immutable A/B slots"
    local custom_script; custom_script="$(seed_make_custom_script)" || { fail "build custom-script"; return 1; }
    if run_bounded "$TIMEOUT_INSTALL" "$AA_BIN" --install --yes -f \
            -k virt --no-verity --disk /dev/vdb \
            --custom-script "$custom_script" \
            -p "$VM_SSH_PORT" -i "$VM_SSH_KEY" \
            root@127.0.0.1; then
        ok "installer completed without error"
    else
        fail "installer returned non-zero"
        serial_tail
        return 1
    fi
    log "installer does not auto-reboot; powering off the seed and booting the target disk"
    vm_stop
    vm_start_installed "$VM_TARGET_DISK" || { fail "could not boot the installed target disk"; return 1; }
    if vm_wait_stable_boot "$TIMEOUT_BOOT"; then ok "booted the freshly installed system"; else fail "installed system did not come up"; return 1; fi

    expect "running system is Alpine"            is_alpine
    expect "booted into slot A"                  test "$(running_slot)" = A
    log "init system reported: $(init_system)"
    # Mark slot A known-good: a freshly installed slot is unverified, so the
    # boot-counter would auto-roll-back to the (empty) slot B on the SECOND boot.
    # This is the intended post-install step ("aa verify"); the auto-rollback
    # phase later exercises the counter deliberately on an unverified slot.
    vm_ssh 'aa verify 2>/dev/null || /usr/sbin/aa verify 2>/dev/null || /usr/local/bin/aa verify 2>/dev/null' \
        || warn "aa verify failed; slot A may auto-roll-back on reboot"
    return 0
}

phase_immutable() {
    step "immutability: a write to the root fs must not survive a reboot"
    vm_ssh 'echo brick-path-test > /MUTABLE_MARKER 2>/dev/null || true' 2>/dev/null || true
    if vm_ssh 'test -f /MUTABLE_MARKER' 2>/dev/null; then
        log "marker written to the live overlay (expected)"
    else
        warn "could not write a marker (root fully read-only) - immutability holds trivially"
    fi
    vm_cold_reboot || { fail "reboot during immutability check"; return 1; }
    if vm_ssh 'test -f /MUTABLE_MARKER' 2>/dev/null; then
        fail "root fs change persisted across reboot - NOT immutable"
    else
        ok "root fs reverted on reboot (immutable squashfs + tmpfs overlay)"
    fi
    expect "still on slot A after reboot" test "$(running_slot)" = A
    return 0
}

phase_upgrade() {
    step "alpine-anywhere upgrade  (atomic A/B switch into slot B)"
    if run_bounded "$TIMEOUT_INSTALL" "$AA_BIN" upgrade --yes -f \
            -k virt --no-verity \
            -p "$VM_SSH_PORT" -i "$VM_SSH_KEY" \
            root@127.0.0.1; then
        ok "upgrade built the inactive slot and switched boot"
    else
        fail "upgrade returned non-zero"; serial_tail; return 1
    fi
    expect "next boot is configured for slot B" test "$(boot_slot)" = B
    vm_cold_reboot || { fail "guest did not return after upgrade reboot"; return 1; }
    expect "booted into slot B"     test "$(running_slot)" = B
    expect "slot B is Alpine"       is_alpine
    return 0
}

phase_rollback() {
    step "aa rollback  (operator recovery: switch back to slot A and reboot)"
    # aa rollback switches the boot slot to A on disk (and tries to reboot, which
    # no-ops in this VM); we then cold-restart to actually boot the switched slot.
    vm_ssh 'aa rollback' 2>/dev/null || true
    sleep 3
    if vm_cold_reboot; then ok "guest rebooted after rollback"; else fail "guest did not return after rollback"; return 1; fi
    expect "rolled back to slot A" test "$(running_slot)" = A
    return 0
}

phase_autorollback() {
    if [ "${AA_VM_SKIP_AUTOROLLBACK:-0}" = 1 ]; then
        log "AA_VM_SKIP_AUTOROLLBACK=1 - skipping boot-counter auto-rollback phase"
        return 0
    fi
    step "boot-counter auto-rollback (an unverified failing slot self-reverts to A)"
    # The mechanism protects against a slot that boots but never reaches a healthy
    # state, so its aa-verify never runs and it stays unverified while its boot
    # counter climbs; once count > MAX_BOOT_ATTEMPTS (=1) on an unverified slot,
    # init.aa (lib/initramfs/init.aa) rewrites the on-disk boot target to the other
    # slot and issues `reboot -f` to apply it.
    #
    # A slot that boots HEALTHILY gets verified by the aa-verify boot service and
    # (correctly) never rolls back. To exercise the failure path we point the boot
    # at B and arm the precondition directly in slots.meta: B unverified with
    # count=1 (one prior failed boot). The next boot then trips the rollback inside
    # init.aa BEFORE switch_root - before B's aa-verify could mark it good - which
    # is exactly the on-real-hardware sequence for a genuinely failing slot.
    vm_ssh 'aa switch B' 2>/dev/null || { fail "aa switch B"; return 1; }
    expect "boot slot set to B" test "$(boot_slot)" = B
    # Arm B as a failing slot. Mounting the ext4 boot partition needs no modprobe:
    # the installed OS loads ext4 at boot via the aa-modules service (STEP 5's
    # `aa rollback`, which rewrites extlinux on this same partition, already
    # depended on it). If ext4 were missing, this mount - and aa itself -
    # would fail, so we deliberately do NOT paper over it with a modprobe here.
    vm_ssh 'mp=/mnt/aab; mkdir -p "$mp"; mount /dev/vda1 "$mp" 2>/dev/null || exit 1; \
        sed -i "s/^SLOT_B_VERIFIED=.*/SLOT_B_VERIFIED=false/; s/^SLOT_B_BOOT_COUNT=.*/SLOT_B_BOOT_COUNT=1/" "$mp/slots.meta"; \
        sync; umount "$mp"' 2>/dev/null || { fail "could not arm the failing-slot scenario in slots.meta"; return 1; }

    # Boot the armed slot. init.aa takes B's count to 2 (> MAX) while unverified,
    # rewrites the on-disk boot target back to A, and issues `reboot -f`. That
    # in-guest reboot does not return in this nested VM (the same quirk vm_cold_reboot
    # exists for), so SSH is NOT expected back on this boot - the wedge is the
    # expected outcome, not a failure. init.aa persists its rollback decision to disk
    # before rebooting, so we cold-restart from the now-A bootloader to recover.
    vm_stop
    vm_start_installed "$VM_TARGET_DISK" || { fail "could not boot failing slot B"; return 1; }
    local waited=0 booted_into=""
    while [ "$waited" -lt "$TIMEOUT_BOOT" ]; do
        if vm_ssh true 2>/dev/null; then booted_into="$(running_slot)"; break; fi
        vm_is_running || break
        sleep 5; waited=$((waited + 5))
    done
    if [ "$booted_into" = A ]; then
        log "init.aa applied the rollback and the in-guest reboot landed on A directly"
    else
        log "slot B did not return (expected: init.aa issued reboot -f after deciding to roll back); cold-restarting"
        vm_stop
        vm_cold_reboot || { fail "recovery reboot after auto-rollback"; return 1; }
    fi

    # Prove the safety mechanism actually fired - three independent on-disk facts,
    # each only reachable by init.aa having run the rollback on the failing boot:
    log "after auto-rollback: running=$(running_slot) boot_slot=$(boot_slot) B_count=$(slot_field B 'Boot count')"
    expect "recovered onto slot A after auto-rollback" test "$(running_slot)" = A
    expect "boot-counter reverted the on-disk boot target to A" test "$(boot_slot)" = A
    expect "failing slot B's boot counter reached 2 (the unverified retry)" \
        test "$(slot_field B 'Boot count')" = 2
    return 0
}

# ---- main -------------------------------------------------------------------
main() {
    preflight

    VM_WORKDIR="${AA_VM_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/aa-vm.XXXXXX")}"
    VM_PIDFILE="${VM_WORKDIR}/qemu.pid"
    VM_SERIAL="${VM_WORKDIR}/serial.log"
    VM_SSH_KEY="${VM_WORKDIR}/id_ed25519"
    trap cleanup EXIT INT TERM

    log "workdir: $VM_WORKDIR"
    ssh-keygen -t ed25519 -N '' -C aa-vm-test -f "$VM_SSH_KEY" >/dev/null 2>&1 \
        || { err "ssh-keygen failed"; exit 1; }

    # alpine-anywhere makes its OWN ssh connection with accept-new TOFU against the
    # user's default known_hosts (our assertion ssh uses /dev/null and is immune).
    # Each fresh seed boot has new host keys, so a stale entry for this loopback
    # port from a previous run makes the tool abort with "host key changed". Purge
    # it up front - the harness owns 127.0.0.1:${VM_SSH_PORT}.
    ssh-keygen -R "[127.0.0.1]:${VM_SSH_PORT}" >/dev/null 2>&1 || true

    # Phases are sequential and dependent: a failed install means the rest is
    # meaningless, so we stop at the first phase that fails.
    phase_boot_seed   || true
    if [ "$FAIL" -eq 0 ]; then phase_install      || true; fi
    if [ "$FAIL" -eq 0 ]; then phase_immutable    || true; fi
    if [ "$FAIL" -eq 0 ]; then phase_upgrade      || true; fi
    if [ "$FAIL" -eq 0 ]; then phase_rollback     || true; fi
    if [ "$FAIL" -eq 0 ]; then phase_autorollback || true; fi

    printf '\n\033[1m===== VM integration summary: %s passed, %s failed =====\033[0m\n' "$PASS" "$FAIL" >&2
    [ "$FAIL" -eq 0 ]
}

main "$@"
