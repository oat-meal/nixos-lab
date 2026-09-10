# ZFS maintenance — scrub, snapshots, SMART monitoring
# Shared across all ZFS hosts

{ lib, pkgs, ... }:

{
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };

  # ⚠️ THESE UNITS RUN AND REPORT SUCCESS ON A HOST WHERE NOTHING IS SNAPSHOTTED.
  # zfs-auto-snapshot only acts on datasets carrying com.sun:auto-snapshot=true.
  # Measured on workstation 2026-09-10: 0 of 30 datasets had it, so all five
  # timers had been firing since at least 2026-09-01 with status=0/SUCCESS and
  # "IO: 0B read, 0B written", and the newest snapshot on the machine was from
  # 2026-08-21. Enabling this module is HALF the configuration; the property on
  # the datasets is the other half and does not live in nix.
  #
  # Retention is mkDefault so a host can cap its own tail. A pool near capacity
  # cannot afford a 12-month pinning window, and that is a per-host fact.
  services.zfs.autoSnapshot = {
    enable = true;
    frequent = lib.mkDefault 4;
    hourly = lib.mkDefault 24;
    daily = lib.mkDefault 7;
    weekly = lib.mkDefault 4;
    monthly = lib.mkDefault 12;
  };

  services.logrotate.enable = true;

  # SMART disk health monitoring
  services.smartd = {
    enable = true;
    autodetect = true;
  };

  environment.systemPackages = with pkgs; [
    smartmontools
  ];
}
