# Boot architecture (x86_64: BIOS + UEFI)

alpine-anywhere installs an immutable A/B system that boots on **both** legacy
BIOS and UEFI firmware. The selection is driven by one piece of state, mirrored
into each firmware's bootloader, so a slot switch or auto-rollback is honoured
whichever way the machine boots.

## Partition layout (GPT)

| # | Name  | FS    | Role |
|---|-------|-------|------|
| 1 | boot  | ext4  | kernels (`vmlinuz-A/B`), initramfs, `extlinux/` (BIOS) + `grub/` (UEFI), `slots.meta`, `current_slot` |
| 2 | slota | raw   | squashfs root image, slot A (optionally dm-verity) |
| 3 | slotb | raw   | squashfs root image, slot B |
| 4 | data  | ext4  | persistent overlay (optional) |
| last | esp | FAT32 | EFI System Partition (x86 UEFI only) |

The ESP is appended **last** so partitions 1-4 never renumber; `init.aa` and the
A/B logic key off the fixed boot/slotA/slotB/data numbers. RPi has no ESP (its
firmware reads the FAT boot partition directly).

## BIOS path

- Part 1 carries the GPT `legacy_boot` attribute; `gptmbr.bin` in the protective
  MBR chainloads its `extlinux` VBR.
- `extlinux/extlinux.conf` selects the slot via `DEFAULT alpine-A|B`.

## UEFI path

- A GRUB-EFI core is installed to the firmware **removable/fallback** path,
  `ESP:/EFI/BOOT/BOOTX64.EFI`, via `grub-install --removable --no-nvram`. No
  NVRAM boot entry is created, so it boots on cloud firmware whose NVRAM is
  reset or absent (e.g. Hetzner Cloud).
- The core embeds the modules needed to reach its prefix on the **ext4** boot
  partition (notably `ext2`), then reads `ALPINE_BOOT/grub/grub.cfg`. That config
  defines the A/B menuentries (same kernels, `root=PARTUUID`, and kernel options
  as extlinux) and `source`s the active slot from `grub/grub_aa_default.cfg`.

## A/B selection: one switch, two bootloaders

Every place that changes the boot slot updates **both** configs on the (ext4)
boot partition in the same step:

| Operation | extlinux | GRUB |
|-----------|----------|------|
| install (`install_boot_config` / `write_grub_cfg`) | `DEFAULT alpine-<slot>` | `grub_aa_default.cfg` |
| `aa switch` / upgrade (`switch_slot`) | rewrites `DEFAULT` | rewrites `grub_aa_default.cfg` |
| auto-rollback (`init.aa`, in the initramfs) | rewrites `DEFAULT` | rewrites `grub_aa_default.cfg` |

All three write to the boot partition that `init.aa` already mounts, so there is
no second mount and no extra state to keep in sync. A box with no ESP (BIOS-only)
simply has no `grub/` directory, and the GRUB writes are skipped. Conversely, a
GRUB-only box (UEFI without `extlinux/extlinux.conf` or `config.txt`, e.g. a
Hetzner cloud server) is first-class: `switch_slot` and `init.aa` treat the
`grub_aa_default.cfg` write itself as the slot flip.

TODO: extend the QEMU VM integration matrix (`spec/integration/vm/`) with a
GRUB-only (UEFI, no extlinux.conf) case; that layout is currently covered by
unit specs only, so an on-box validation on the Hetzner exits is still required
before trusting the persist path there.
