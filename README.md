# alpine-anywhere

Take over a running Linux server over SSH and install an **immutable Alpine
Linux A/B system**: a musl, RAM-overlay root served from a read-only squashfs
slot, with atomic no-reboot upgrades and initramfs auto-rollback. It is the tool
that provisions the Warren exit-node fleet.

It also supports a temporary RAM-only **live** boot (reverts on reboot) and
on-device slot management (`aa status/verify/rollback/switch/upgrade`).

## What it produces

An immutable A/B install (see [`docs/BOOT.md`](docs/BOOT.md) for the boot
architecture):

- Two squashfs root slots (A/B) on raw partitions; the live root is an overlay
  (squashfs `ro` + tmpfs `rw`), so the running system is disposable.
- A FAT/ext4 boot partition holding `vmlinuz-A/B`, initramfs, `slots.meta`,
  `current_slot`, and the bootloader config (extlinux for BIOS, GRUB for UEFI,
  `config.txt` for Raspberry Pi).
- An initramfs **boot-guard** (`init.aa`, injected before `switch_root`) that
  counts boot attempts and rolls back to the other slot if a new slot fails to
  reach the verified state. `aa verify` (run once a boot is healthy) commits the
  slot and stops the rollback.
- `--hardened`: s6 init + key-only dropbear (instead of OpenRC + OpenSSH), a
  KSPP-aligned kernel cmdline (cloud-KVM safe: no `iommu=force`, no SMT disable),
  hardened_malloc, sysctl hardening, and an nftables firewall.

## Usage

```sh
# Install an immutable A/B system onto a remote server (repartitions the disk)
alpine-anywhere --install --hardened root@server

# Temporary RAM-only Alpine (reverts on reboot)
alpine-anywhere root@server

# Atomic A/B upgrade of an already-installed system (no reboot; operator reboots later)
alpine-anywhere upgrade root@server

# On the installed device (or `<subcommand> user@host` to run it remotely):
aa status          # active slot + per-slot metadata
aa verify          # mark the running slot known-good (stops auto-rollback)
aa switch A|B      # set the next-boot slot
aa rollback        # switch to the other slot and reboot
aa upgrade         # rebuild the inactive slot and point the bootloader at it
aa --version       # print the git describe of the installed build
```

Run `alpine-anywhere --help` for the full option list.

### Rollback semantics

- A freshly installed/switched slot is **unverified**. `init.aa` increments its
  boot counter each boot; a healthy boot runs `aa verify`, which resets the
  counter. If the slot fails to verify, the second unverified boot
  (`MAX_BOOT_ATTEMPTS=1`, i.e. one retry) rolls back to the other slot.
- Rollback lives in the **initramfs**. A slot whose kernel/initramfs never
  executes (corrupt kernel, broken bootloader core) cannot self-roll-back; there
  is no bootloader-level try-counter. Validate a new build before wide rollout.

### Build hooks (`--custom-script` / `--custom-files`)

`--custom-files PATH` stages a file or directory into the image build, exposed to
`--custom-script` via `$AA_CUSTOM_FILES_DIR`. `--custom-script FILE` runs inside
the image chroot at build time (e.g. to drop in a pre-built binary without
network access). See [`examples/custom-script.sh`](examples/custom-script.sh).

## Integrity and signing

- Every artifact download (minirootfs, kexec installer kernel/modloop) is
  verified against its published `sha512` and **fails closed** if the checksum is
  missing (override with `--checksum-dir` for an air-gapped mirror, or the unsafe
  `--no-verify`). Slot images written on a live system are read back and
  sha256-checked.
- dm-verity (`--verity`, on by default under `--hardened` unless `--no-verity`)
  fails closed at boot: if the verified mapper cannot be opened the initramfs
  refuses to mount the raw slot and reboots into rollback. If a signing public
  key is embedded (`/etc/alpine-anywhere/verity.pub`), a valid minisign
  signature of the root hash is **required** (closes downgrade-by-suppression).
  The Warren fleet currently runs `--no-verity`.
- Signing invocation: `--verity-pubkey verity.pub` to require signatures at boot,
  plus either `--verity-sig rh.minisig` (detached signature produced offline on
  the release box, production) or `--verity-sign-key dev.key` (inline dev/test).

## Install / development

```sh
make test          # unit + integration (shellspec, mocked)
make test-vm       # real QEMU lifecycle: install -> upgrade -> rollback (needs QEMU)
make lint          # shellcheck + POSIX syntax check
make install       # install to PREFIX (default /usr/local; script -> bin, libs -> lib/aa)
```

Requires a POSIX `/bin/sh` (BusyBox ash, dash, or bash). The generated system is
musl; a slot binary must be built for musl.

## Warren fleet

This repo provisions the Warren exit nodes. The deploy tooling
(`warren-core/infra/aadeploy/deploy-exit.sh`) drives `alpine-anywhere` for
install and the hot-swap + persist upgrade flow; see the Warren workspace runbook
for the fleet rollout procedure.
