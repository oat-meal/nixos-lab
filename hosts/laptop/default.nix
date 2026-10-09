# Framework 13 laptop configuration
# AMD Ryzen, MangoWM compositor, power management optimized

{ config, pkgs, lib, ... }:

{
  imports = [
    # Security
    ../common/optional/security/luks.nix
    ../common/optional/security/hardening.nix

    ./hardware-configuration.nix

    # Core (required)
    ../common/core

    # Desktop environment (MangoWM + Noctalia; base = shared greetd/portals/polkit)
    ../common/optional/desktop/base.nix
    ../common/optional/desktop/mango
    ../common/optional/desktop/audio.nix
    ../common/optional/desktop/fonts.nix
    ../common/optional/desktop/apps.nix

    # Gaming
    ../common/optional/gaming

    # Hardware
    ../common/optional/hardware/amd.nix
    ../common/optional/hardware/bluetooth.nix
    ../common/optional/hardware/framework.nix
    ../common/optional/hardware/kernel-module-autoload.nix

    # Networking
    ../common/optional/networking/firewall.nix
    ../common/optional/networking/nordvpn.nix
    ../common/optional/networking/sops.nix
    ../common/optional/networking/ssh.nix
    ../common/optional/networking/syncthing.nix
    ../common/optional/networking/wifi.nix
    ../common/optional/networking/wireguard.nix

    # Power
    ../common/optional/power/portable.nix
    ../common/optional/power/hibernate.nix

    # Security
    ../common/optional/security/sudo.nix
    ../common/optional/security/lab-monitor.nix

    # Storage
    ../common/optional/storage/zfs-maintenance.nix
    ../common/optional/monitoring/post-rebuild-verify.nix
  ];

  ################################
  ## Host identity
  ################################
  networking.hostName = "laptop-nixos";
  system.stateVersion = "25.05";

  ################################
  ## Kernel
  ################################
  # Pinned explicitly, like the other two hosts — never via
  # zfs.latestCompatibleLinuxPackages, which is deprecated and now resolves to the
  # nixpkgs default kernel rather than the newest ZFS-compatible one (it silently
  # downgraded server-nixos 7.0.10 → 6.12.93 on 2026-08-16; see hosts/server).
  # 6.12 is the LTS and is what this host has been validated on; workstation and
  # server run 7.0. Bump deliberately and reboot-test WiFi/ZFS when doing so.
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_12;
  boot.consoleLogLevel = 1;

  # Laptop-specific kernel params
  boot.kernelParams = lib.mkAfter [
    "amd_pstate.shared_mem=1"
    "amdgpu.abmlevel=0"  # Disable adaptive backlight to prevent GPU idle lockups
  ];

  # Kernel module autoload fix (first diagnosed here 2026-08-10) now lives in
  # ../common/optional/hardware/kernel-module-autoload.nix, imported above — the
  # server hit the same bug on 2026-08-16.

  ################################
  ## GameMode override (laptop)
  ################################
  # 8-core laptop CPU: reserve 4 cores for system, pin games to 4
  programs.gamemode.settings.cpu.core_count = lib.mkForce 4;
  programs.gamemode.settings.gpu.gpu_device = lib.mkForce 1;  # GPU is card1 on this laptop

  ################################
  ## WiFi power saving (laptop)
  ################################
  networking.networkmanager.wifi.powersave = true;

  ################################
  ## User groups
  ################################
  users.users.oat.extraGroups = lib.mkAfter [ "audio" "video" "input" "gamemode" ];

  ################################
  ## Moonlight — game-stream client for the workstation's Sunshine host (wg0)
  ################################
  # For remote playtest: connect to workstation-nixos (10.100.0.1).
  environment.systemPackages = [ pkgs.moonlight-qt ];

  # Units oat may start/stop/restart without sudo (polkit; see security/sudo.nix).
  lab.restartableUnits = [
    "syncthing.service"
    "wireguard-wg0.service"
  ];
}
