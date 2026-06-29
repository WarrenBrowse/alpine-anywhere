# VM integration test — the path that can brick a box

The `shellspec` suites under `spec/lib/` and `spec/integration/` mock SSH, curl
and the disk entirely. They never boot, never partition and never reboot, so the
**riskiest code in this repo has no real coverage**:

- the **pivot / takeover** into a clean Alpine env (replacing PID 1 on the live machine),
- **partitioning a disk and laying down the immutable A/B slots**,
- the **A/B switch** and **upgrade**,
- the **boot-counter auto-rollback**.

These are exactly the operations that, when they go wrong, leave a remote server
unreachable. This harness exercises all of them end to end against a **disposable
QEMU guest**, the same way production drives the tool: a stock Debian cloud image
is the live control plane (`vda`), and `alpine-anywhere` over SSH installs the
immutable A/B system onto the destination disk (`vdb`). `bootindex` makes the
guest prefer `vdb`: while it is blank BIOS falls through to the seed; once
installed, `vdb` boots, so a plain reboot lands in the installed system. We then
power-cycle the guest and assert **which slot actually booted** at each step.

## What it does

| Step | Action | Assertion |
|------|--------|-----------|
| 1 | Boot a stock Debian **cloud image** (the partitioned "provider" seed) | seed answers SSH, root disk is partitioned, has the build tools |
| 2 | `alpine-anywhere --install /dev/vdb` (pivot + partition + A/B), reboot | booted **slot A**, running Alpine |
| 3 | Write a file to `/`, reboot | change **did not persist** (immutable squashfs + tmpfs overlay) |
| 4 | `alpine-anywhere upgrade`, reboot | **next boot = B**, then booted **slot B** |
| 5 | `aa rollback` (force-reboots) | back on **slot A** |
| 6 | `aa switch B` then reboot twice **without** `aa verify` | unverified slot **auto-rolls back to A** |

Exit code: `0` if every assertion passes **or** if it cleanly SKIPs (QEMU
absent); `1` on any failure. On failure it dumps the guest serial console.

## Running it

```sh
make test-vm
# or directly:
sh spec/integration/vm/run.sh
```

Requirements on the host: `qemu-system-x86_64`, `qemu-img`, `ssh`/`ssh-keygen`,
`curl`, and a NoCloud ISO builder (`cloud-localds`, or `genisoimage`/`mkisofs`/
`xorrisofs`). With **KVM** (`/dev/kvm` writable, e.g. a native Linux box) a full
run is a few minutes; under **TCG** emulation (no KVM, e.g. macOS) it works but
is slow. When QEMU is not installed the test prints `SKIP` and exits `0`, so
`make test` stays green on dev machines.

In CI (`.github/workflows/vm-integration.yml`) it runs on the org's self-hosted
Debian x86_64 runner (label `warren`) on push/PR. This is the gate to run
**before each exit-fleet bump** (see warren-core `CLAUDE.md` §6 quater): the same
logic that says "networking integration tests don't suffice, validate on real
hardware" applied to the boot path.

## Knobs (env)

| Var | Default | Meaning |
|-----|---------|---------|
| `AA_VM_SEED_URL` | Debian 12 genericcloud qcow2 | seed qcow2 to convert; must be a **partitioned** provider image (see below) |
| `AA_VM_RAM_MB` | `3072` | guest RAM |
| `AA_VM_DISK_GB` | `8` | guest disk (overlay) size |
| `AA_VM_SSH_PORT` | `2222` | host port forwarded to guest `:22` |
| `AA_VM_ACCEL` | `auto` | `auto`/`kvm`/`tcg` |
| `AA_VM_CACHE` | workdir | directory to cache the downloaded seed image between runs |
| `AA_VM_KEEP` | `0` | `1` leaves the VM + workdir up for debugging (prints the ssh line) |
| `AA_VM_SKIP_AUTOROLLBACK` | `0` | `1` skips the slowest phase (two extra reboots) |
| `AA_VM_TIMEOUT_INSTALL` | `2400` | seconds before a hung install/upgrade is killed |

## Why a Debian seed (and the partitioned-disk requirement)

The seed must be a **partitioned** provider image, because alpine-anywhere's
reboot-into-RAM installer stages `installer.img` onto **partition 1 of the
running root disk** (`lib/pivot.sh`). Debian genericcloud is GPT with `vda1` =
root — exactly a real provider's shape. An Alpine "nocloud" image puts root on
the whole unpartitioned device (no `vda1`), which breaks the staging, so it is
**not** a valid seed here. `AA_VM_SEED_URL` may point at any other partitioned
cloud qcow2 (e.g. Ubuntu genericcloud); the seed prep is distro-aware (apt or
apk), cloud-init injects the test key and unlocks root, and the immutable A/B is
installed onto a separate blank target disk (`vdb`).

## Files

| File | Role |
|------|------|
| `run.sh` | orchestrator: config, phases, assertions, summary |
| `lib/qemu.sh` | boot / reboot-and-wait / stable-boot / SSH helpers (rides out auto-reboots) |
| `lib/seed.sh` | resolve + fetch seed image, build qcow2 overlay and NoCloud seed ISO |
| `lib/asserts.sh` | parse `aa status` over SSH: running slot, boot slot, per-slot fields |
