# Workstation configuration
# AMD Ryzen 9950X, dedicated GPU, gaming-optimized

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
    ../common/optional/desktop/sunshine.nix  # game-stream host → Moonlight on laptop (wg0)

    # Gaming
    ../common/optional/gaming
    ../common/optional/ai/eliteintel.nix
    ../common/optional/ai/comfyui-render.nix  # image-gen render node (ComfyUI on the 9070 XT)

    # Development
    ../common/optional/dev/gamedev.nix  # Blender — required by 7 forge build-time tools

    # Hardware
    ../common/optional/hardware/amd.nix
    ../common/optional/hardware/kernel-module-autoload.nix
    ../common/optional/hardware/bluetooth.nix
    ../common/optional/hardware/printing.nix

    # Networking
    ../common/optional/networking/firewall.nix
    ../common/optional/networking/nordvpn.nix
    ../common/optional/networking/sops.nix
    ../common/optional/networking/ssh.nix
    ../common/optional/networking/syncthing.nix
    ../common/optional/networking/tailscale.nix
    ../common/optional/networking/wifi.nix
    ../common/optional/networking/wireguard.nix

    # Power
    ../common/optional/power/performance.nix
    ../common/optional/power/memory-pressure.nix  # oomd enrollment + coredump cap (2026-09-11 desktop stall)

    # Security
    ../common/optional/security/sudo.nix

    # Storage
    ../common/optional/storage/zfs-maintenance.nix

    # Monitoring — PARKED (2026-08-16). Not blocked, deliberately deferred until the
    # lab's observability tooling/strategy is re-evaluated as a whole.
    #
    # History: disabled 2026-08-03 while bisecting the WiFi regression (these were the
    # only functional additions between working gen 50 and failing gen 51, ath12k
    # "wpa_supplicant couldn't grab interface"). That investigation CLOSED — the cause
    # was confirmed as stack-smoke-test's Persistent timer + wants=network-online.target
    # pulling the target into the boot transaction (commit 183f279, postmortem item 8).
    #
    # Both modules are now safe to re-enable on the technical merits: the anti-pattern
    # was removed from stack-smoke-test (2026-08-16) and post-rebuild-verify never had
    # it. They stay off by choice, not by risk. When observability is revisited, decide
    # whether these ad-hoc units are still the right shape at all — note both alert to
    # the lab ntfy hub on the server, so neither can report a server that is itself down
    # (postmortem action item #3, still open).
    #
    # See docs/audit/workstation.md and docs/audit/postmortem-2026-08-wcn7850-wifi.md.
    # ../common/optional/monitoring/post-rebuild-verify.nix
    # ../common/optional/monitoring/stack-smoke-test.nix

    # ON by choice, unlike the two above: this one reports a failure mode that is
    # otherwise indistinguishable from dead hardware, and whose recovery (SysRq forced
    # reboot) you will not guess. Carries no boot-ordering risk — no Persistent timer,
    # no wants=network-online.target. See the module header for the 2026-08-16 chain.
    ../common/optional/monitoring/gpu-wedge-sentinel.nix
  ];

  ################################
  ## Host identity
  ################################
  networking.hostName = "workstation-nixos";
  system.stateVersion = "25.05";

  ################################
  ## ZFS snapshots — retention capped for a pool near capacity
  ################################
  # ⚠️ THIS HOST WAS SNAPSHOTTING NOTHING, AND EVERY TIMER SAID OTHERWISE.
  # Found 2026-09-10 while attempting to recover a file deleted an hour earlier.
  # All five zfs-snapshot units were enabled, armed, and had just run with
  # status=0/SUCCESS; the recovery failed because the newest snapshot on the
  # machine was pre-26.05-migration-20260821-1218, three weeks old. Cause:
  # zfs-auto-snapshot acts only on datasets with com.sun:auto-snapshot=true, and
  # 0 of 30 datasets carried it. The run log said "IO: 0B read, 0B written"
  # directly under "Finished ZFS auto-snapshotting every 15 mins".
  #
  # Fixed out of band, because a dataset property is pool metadata and not a nix
  # option:  zfs set com.sun:auto-snapshot=true rpool/home   (children inherit)
  # ⚠️ NOTHING CHECKS THAT, AND THAT IS THE UNFIXED HALF. The property lives in
  # pool metadata, so a host can import this module, pass every check, run every
  # timer green and protect nothing — which is exactly what happened here for
  # three weeks. What is missing is a probe asserting a RECENT SNAPSHOT EXISTS,
  # per dataset, rather than asserting that a unit is happy. Not built: the
  # monitoring section above records observability as deliberately parked, and
  # both parked sentinels alert to ntfy on the server, so this one would need
  # somewhere else to report. Declared absent rather than omitted.
  #
  # Retention is capped at 7 days here, against the shared default of 12 months.
  # Measured on rpool at the time of the decision:
  #   pool          928G, 92% full, 71.2G free
  #   /home         737G referenced, 282G written in 20 days (~14G/day)
  #   pinned by one 20-day-old snapshot   6.73G  (~0.34G/day of long-lived
  #                                              deletions -> ~10G/month)
  # A 12-month tail projects to ~120G of pinned deletions against 71.2G free, so
  # the default would fill this pool before its first monthly rolled off. And
  # 0.34G/day is a FLOOR: measured under a single 20-day-old snapshot, nothing
  # created-and-deleted in between was ever pinned. At a 15-minute cadence the
  # caches, nix builds and Electron test runs that make up most of the 14G/day
  # start counting. Seven days bounds that; a year does not.
  #
  # 0 means NONE CREATED, not "unlimited" — verified in zfstools 0.3.6 rather
  # than assumed: bin/zfs-auto-snapshot line 68 is
  #   do_new_snapshots(datasets, interval) if keep > 0
  # and line 71 then cleans up existing snapshots of that interval down to the
  # keep count. The weekly and monthly TIMERS still exist and still run green;
  # they now do nothing on purpose, which is the same shape as the defect above
  # and is why the intent is written here rather than left to be inferred.
  services.zfs.autoSnapshot = {
    weekly = 0;
    monthly = 0;
  };

  ################################
  ## Kernel
  ################################
  # 6.18 LTS (supported upstream to Dec 2028) — the newest kernel that both EXISTS in
  # 26.05 and works with ZFS. This host is ZFS-root (rpool + storage). Measured:
  #   6.18.44  present, zfs_2_4 builds      <- chosen
  #   6.19     REMOVED from nixpkgs (EOL upstream)
  #   7.0      REMOVED from nixpkgs (EOL upstream)  <- what runs here today
  #   7.1.8    present, zfs_2_4 REFUSES
  #   7.2      present, zfs_2_4 REFUSES
  #
  # So this is not a choice between old and new: 7.0 is already dead upstream and
  # gone from nixpkgs. Numerically 6.18 is two releases back (6.18 -> 6.19 -> 7.0;
  # the "7" is a rollover, not an architectural break), but in support terms it is a
  # move from an EOL non-LTS branch onto a live LTS one.
  #
  # The gap is narrow and unlucky rather than fundamental. zfs_2_4 declares
  # kernelMaxSupportedMajorMinor = "7.0", so ZFS DOES support 7.0 — it is the kernel
  # that vanished, not ZFS support for it. Meanwhile nixpkgs keeps only LTS branches
  # plus the newest non-LTS (here: 7.1, 7.2), which both exceed ZFS's ceiling. So the
  # highest kernel that is simultaneously packaged and ZFS-supported is 6.18.
  # Revisit when OpenZFS ships 7.1 support (openzfs/zfs#18760, still open) and
  # nixpkgs raises the ceiling — then 7.1/7.2 open up.
  #
  # VERIFIED on the 2026-08-21 reboot: 6.18.44 boots, ZFS 2.4.3 loads and imports both
  # pools, 0 failed units, and the 9070 XT comes up on Mesa 26.1.5 (gfx1201, DRM 3.64)
  # with the KFD compute nodes present and the ComfyUI container running.
  #
  # WiFi is NOT part of that check, and must not be re-added to it: the WCN7850 is
  # DISABLED IN BIOS as of 2026-08-21 and this host is wired-only (enp17s0, RTL8126
  # 5GbE). A BIOS disable removes the card from PCI enumeration entirely, so the
  # absence of `wlp16s0`, of any ath12k log line, and NetworkManager reporting
  # `WIFI-HW: missing` are all EXPECTED here — not a driver or kernel regression.
  # The ath12k plumbing below (initrd module, shutdown cleanup unit) is retained
  # deliberately so re-enabling in BIOS is the only step needed to get WiFi back.
  #
  # NOTE (2026-08-03): the earlier "7.0.14 breaks WiFi (-517)" belief was WRONG — it
  # was confounded by the stack-smoke-test monitoring's boot-ordering grab race.
  boot.kernelPackages = pkgs.linuxPackages_6_18;
  boot.consoleLogLevel = 1;

  # Desktop-specific kernel params (gaming optimized)
  boot.kernelParams = lib.mkAfter [
    "transparent_hugepage=madvise"
    "hugepagesz=2M"
    "default_hugepagesz=2M"
    "preempt=full"
    "snd_hda_intel.power_save=0"
    "usbhid.mousepoll=1"
    "pci=pcie_bus_perf"
    "usbcore.autosuspend=-1"
    "pcie_aspm=off"
    # Cap ZFS ARC at 16 GB. Default (uncapped ≈ 50% RAM) held ~34 GB of the 60 GB
    # and starved games — a Steam update's write/decompress burst pushed RAM into
    # swap and stalled the desktop. 16 GB cache leaves ~44 GB for games.
    "zfs.zfs_arc_max=17179869184"
    # Don't penalize bus-locking threads. The kernel was rate-limiting Steam's job
    # threads (CJobMgr bus_lock traps) during the update, causing brief hitches.
    "split_lock_detect=off"
  ];

  boot.kernelModules = [
    "ath12k_pci"
  ];

  ################################
  ## Anti-cheat (EAC) override
  ################################
  # EasyAntiCheat (Elden Ring Nightreign, etc.) must ptrace the game process
  # it launches; hardening.nix sets scope 2 (admin-only), which makes EAC fail
  # module mapping with "Unexpected error (#1)". Scope 1 = descendants-only,
  # which is enough for EAC and matches hardening.nix's documented intent.
  # Workstation-only override — server and laptop keep scope 2.
  boot.kernel.sysctl."kernel.yama.ptrace_scope" = lib.mkForce 1;

  ################################
  ## GameMode override (16-core CPU)
  ################################
  # Ryzen 9950X: reserve 4 cores for system, pin games to 12
  programs.gamemode.settings.cpu.core_count = lib.mkForce 12;

  ################################
  ## User groups (extended for desktop peripherals)
  ################################
  users.groups.plugdev = {};
  users.users.oat.extraGroups = lib.mkAfter [ "audio" "video" "dialout" "uucp" "plugdev" "input" ];

  ################################
  ## USB device support (gaming peripherals, VR)
  ################################
  hardware.usb-modeswitch.enable = true;

  services.udev.extraRules = ''
    # ASUS ROG devices
    SUBSYSTEM=="usb", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="1aa2", TAG+="uaccess"
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0b05", TAG+="uaccess"

    # Gaming peripherals
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", MODE="0664", GROUP="input"

    # Xbox controllers
    KERNEL=="hidraw*", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="02fd", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="0b12", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="0b13", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="0b20", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="0b21", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="045e", ATTRS{idProduct}=="0b22", MODE="0664", GROUP="input", TAG+="uaccess"

    # PS5 DualSense
    KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="js*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="event*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0664", GROUP="input", TAG+="uaccess"

    # PS4 DualShock
    KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="09cc", MODE="0664", GROUP="input", TAG+="uaccess"
    KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="05c4", MODE="0664", GROUP="input", TAG+="uaccess"

    # Meta Quest VR
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2833", ATTRS{idProduct}=="0186", MODE="0664", GROUP="plugdev", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2833", ATTRS{idProduct}=="0051", MODE="0664", GROUP="plugdev", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2833", ATTRS{idProduct}=="0183", MODE="0664", GROUP="plugdev", TAG+="uaccess"

    # USB audio
    SUBSYSTEM=="usb", ATTRS{bInterfaceClass}=="01", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTRS{bInterfaceClass}=="03", TAG+="uaccess"

    # WiFi power management (USB/PCI power rules removed — usbcore.autosuspend=-1 handles globally)
    SUBSYSTEM=="net", ACTION=="add", KERNEL=="wl*", RUN+="/bin/sh -c 'echo on > /sys/class/net/%k/device/power/control'"

    # NVMe scheduler
    ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"

    # Hide ZFS member devices from udisks2/Thunar sidebar
    ENV{ID_FS_TYPE}=="zfs_member", ENV{UDISKS_IGNORE}="1"
  '';

  ################################
  ## WiFi shutdown cleanup (desktop-specific driver issue)
  ################################
  systemd.services.wifi-shutdown-cleanup = {
    description = "Clean ath12k WiFi driver before shutdown";
    wantedBy = [ "shutdown.target" ];
    before = [ "shutdown.target" "reboot.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = pkgs.writeShellScript "wifi-shutdown-cleanup" ''
        echo "Disabling WiFi interface wlp16s0 for clean shutdown"
        ${pkgs.iproute2}/bin/ip link set wlp16s0 down 2>/dev/null || true
        echo "on" > /sys/class/net/wlp16s0/power/control 2>/dev/null || true
        sleep 2
      '';
      TimeoutStopSec = "15s";
    };
  };

  ################################
  ## NFS mount — server storage
  ################################
  fileSystems."/mnt/server" = {
    device = "10.100.0.2:/storage";
    fsType = "nfs";
    # hard mount (implicit default) for data integrity; fast-fail so touching
    # /mnt/server while the server is offline errors in ~10s instead of hanging
    # Thunar for minutes. Re-mounts automatically on next access when server is up.
    options = [
      "x-systemd.automount"
      "noauto"
      "_netdev"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=10s"  # systemd cancels the mount job after 10s
      "retry=0"                       # mount.nfs: fail now, no 2-min fg retry loop
      "timeo=50"                      # 5s per-RPC timeout (deciseconds)
      "retrans=2"                     # 2 retries before "server not responding"
    ];
  };

  ################################
  ## Flatpak support
  ################################
  services.flatpak.enable = true;

  ################################
  ## nix-ld for unpatched binaries (Fightcade, etc.)
  ################################
  # nix-ld for unpatched binaries (Fightcade, AppImages)
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      # Electron/Chromium runtime (Fightcade, Discord AppImage)
      nss nspr atk at-spi2-atk at-spi2-core cups libdrm
      gtk3 pango cairo gdk-pixbuf glib dbus expat libxkbcommon
      # Graphics
      alsa-lib mesa libGL libGLU
      # System
      systemd udev zlib stdenv.cc.cc.lib
      # X11 (required by most unpatched Linux binaries)
      # The xorg package set is deprecated in 26.05; these are the top-level names.
      libx11 libxcomposite libxdamage libxext
      libxfixes libxrandr libxcb libxcursor
      libxi libxrender libxtst libxscrnsaver
      libxshmfence
      # Audio/desktop integration
      libpulseaudio libnotify libappindicator-gtk3 libsecret ffmpeg
    ];
  };
}
