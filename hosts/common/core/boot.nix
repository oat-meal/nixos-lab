# Bootloader configuration
# UEFI + systemd-boot (default, can be overridden for servers)

{ lib, ... }:

{
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Bound the entries written to the ESP. nix.gc keeps 30 days of generations, which
  # is unbounded in ESP terms: each entry costs ~45MB (kernel + initrd) against a
  # 512MB partition, so ~11 fit. server-nixos was already at 54% with 6 entries, and a
  # single day of iteration can add five. A full ESP fails `nixos-rebuild` at the
  # bootloader step — on the headless host that means a console trip. 10 generations
  # is still a deep rollback history.
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

  # No kernel-command-line editing at the boot menu. With it on (the NixOS default),
  # anyone at the console can append `init=/bin/sh` — and on the server, whose LUKS
  # unlocks from the TPM (PCRs 0+7) with no Secure Boot, the disks unlock regardless
  # and that is a root shell. Off, previous generations are still selectable; only
  # editing is gone. Not a full fix for the server: booting other media is still
  # possible until Secure Boot or a tighter PCR policy lands (found by a cold review,
  # 2026-10-09).
  boot.loader.systemd-boot.editor = false;

  # All three hosts are ZFS-root, so this applies fleet-wide.
  #
  # Pinned to the CURRENT default rather than changed. 26.05 warns that this flips to
  # false in 26.11; setting it explicitly keeps the 26.05 migration behaviour-neutral
  # and silences the warning. Moving to false is a SEPARATE decision — false is the
  # safer value (it refuses to import a pool another system may still own), and the
  # single-host-owns-its-rpool assumption should be confirmed per host before flipping.
  boot.zfs.forceImportRoot = lib.mkDefault true;
}
