# Framework Server — headless home server
# AMD Ryzen AI Max+ 395, 128GB unified RAM, 2x 1TB NVMe (ZFS mirror)
# Services: Ollama, Jellyfin, AdGuard Home, NFS

{ config, pkgs, lib, ... }:

let
  secrets = import ../../secrets/network.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Core (required)
    ../common/core

    # Hardware
    ../common/optional/hardware/amd.nix
    ../common/optional/hardware/kernel-module-autoload.nix

    # Networking
    ../common/optional/networking/sops.nix
    ../common/optional/networking/ssh.nix
    ../common/optional/networking/syncthing.nix
    ../common/optional/networking/wifi.nix
    ../common/optional/networking/wireguard.nix

    # Security
    ../common/optional/security/luks.nix
    ../common/optional/security/hardening.nix
    ../common/optional/security/sudo.nix

    # Storage
    ../common/optional/storage/zfs-maintenance.nix
    ../common/optional/monitoring/post-rebuild-verify.nix
    ../common/optional/monitoring/update-advisor.nix

    # AI lab
    ../common/optional/ai/mcp-host-health.nix
    ../common/optional/ai/fleet-sentinel.nix
    ../common/optional/ai/open-webui.nix
    ../common/optional/ai/searxng.nix
    ../common/optional/ai/search-sentinel.nix   # asserts searxng SEARCHES, not just responds
    ../common/optional/ai/chromadb.nix
    ../common/optional/ai/lab-tools.nix
    ../common/optional/ai/lab-api.nix
    ../common/optional/ai/comfyui.nix
    ../common/optional/ai/dashboard.nix
    ../common/optional/ai/kokoro.nix
    ../common/optional/ai/hy-motion.nix          # text-to-motion; CPU-only, no vendor exists for this
    ../common/optional/ai/ntfy.nix
  ];

  ################################
  ## Host identity
  ################################
  networking.hostName = "server-nixos";
  system.stateVersion = "25.11";
  networking.hostId = "dc598b84";

  ################################
  ## Kernel
  ################################
  # ZFS host: pin explicitly. Do NOT use zfs.latestCompatibleLinuxPackages — it is
  # deprecated and now resolves to the nixpkgs *default* kernel rather than the newest
  # ZFS-compatible one, inverting the guarantee it was chosen for. Caught 2026-08-16: it
  # silently built 6.12.93 for a host running 7.0.10, i.e. a major downgrade on the next
  # reboot with no signal beyond an eval warning.
  #
  # 6.18 LTS (supported upstream to Dec 2028) — matches workstation-nixos. See the
  # kernel comment there for the full measurement; the short version is that 6.19 and
  # 7.0 were REMOVED from nixpkgs as EOL upstream, 7.1/7.2 exist but exceed zfs_2_4's
  # declared kernelMaxSupportedMajorMinor of "7.0", and 6.18 is the newest kernel that
  # is both packaged and ZFS-supported. Note ZFS does support 7.0 — it is the kernel
  # that vanished, not ZFS support for it.
  #
  # Not an old-vs-new tradeoff: the 7.0.14 running here today is already EOL upstream
  # and no longer packaged. This moves onto a live LTS branch, which is also what
  # stops the 2026-08-16 recurrence (pinning a non-LTS line ZFS does not follow).
  #
  # The Strix Halo iGPU (gfx1151) is the thing to watch: its support landed around
  # 6.14-6.15, so 6.18 should cover it, but ROCm/Ollama on gfx1151 is UNVERIFIED on
  # this kernel — check ollama serves a model after the first reboot.
  boot.kernelPackages = pkgs.linuxPackages_6_18;

  # ZFS ARC 32GB
  boot.kernelParams = [
    "zfs.zfs_arc_max=34359738368"
    "spl.spl_hostid=0xdc598b84"  # claim rpool with system hostid at initrd import; clears hostid-mismatch warning

    # amdgpu defaults GTT to 50% of RAM — measured 62.5 GiB here — which caps what
    # the iGPU can address no matter how much is installed (ROCm#5595, open). That
    # ceiling, not the 125 GiB fitted, is what bounds model size on this host.
    #
    # gttsize is in MiB and must be matched by ttm.pages_limit in 4 KiB pages, or
    # allocations fail once they pass the lower of the two. 80 GiB = 81920 MiB =
    # 20971520 pages. Budget: 125 total - 80 GTT - 32 ARC leaves ~13 GiB for the OS
    # and the rest of the service set. GTT is a ceiling rather than a reservation,
    # but GPU-pinned pages are not reclaimable, so it is sized against zfs_arc_max
    # above — raising one means lowering the other.
    #
    # amdgpu.gtt_size (underscore) is the deprecated spelling and is silently
    # ignored; the value has to be on amdgpu.gttsize to take effect.
    "amdgpu.gttsize=81920"
    "ttm.pages_limit=20971520"
  ];

  # Load amdgpu early for display during LUKS passphrase prompt (RDNA 3.5)
  boot.initrd.kernelModules = [ "amdgpu" ];

  # Lower than the fleet default of 10 (hosts/common/core/boot.nix). This host's initrd is
  # the fattest — ZFS + amdgpu + systemd-initrd — at ~45MB per ESP entry against a 510MB
  # partition. Ten entries would sit at ~88%, and systemd-boot writes the new entry BEFORE
  # pruning the old ones, so a switch momentarily needs eleven (~97%). A full ESP fails
  # nixos-rebuild at the bootloader step, which on a headless host means a console trip.
  boot.loader.systemd-boot.configurationLimit = 6;

  ################################
  ## Wired-only networking
  ################################
  # This host is always wired (enp191s0, persistent NM static 192.168.10.50), so the
  # MT7925 radio stays off. With WiFi live the box was dual-homed — two default routes
  # to the same gateway, one per interface — which gives ambiguous source-address
  # selection for the wg0 endpoint and invites asymmetric routing. Blacklisting the
  # driver removes the interface outright rather than leaving an unmanaged one to be
  # re-enabled by accident.
  #
  # To restore WiFi: drop this line and rebuild. Note there is no fallback path in if
  # the wired NIC is down — that recovery is console-only.
  boot.blacklistedKernelModules = [ "mt7925e" ];

  # The wired address is declared here rather than left to a hand-made NetworkManager
  # profile. The previous static .50 profile was created by hand and vanished across a
  # reboot — NM fell back to an auto-generated DHCP profile and took .84, while
  # secrets/network.nix still advertised .50 as this host's wg0 endpoint. The mesh then
  # only converged in the direction the server happened to initiate. Declaring the
  # profile keeps the address and secrets/network.nix in agreement by construction.
  #
  # NOTE: .50 must sit outside the router's DHCP pool, or be reserved for
  # 9c:bf:0d:01:03:73, otherwise the lease can be handed to another device.
  # Required for podman PUBLISHED ports to be reachable from other hosts.
  #
  # Diagnosed 2026-08-16. Symptom: every NATIVE service answered over wg0 (ollama
  # 11434, adguard 3000, ntfy 2586, lab-api 8091) while BOTH container ports were
  # silently blocked (comfyui 8188, kokoro 8880) — no refusal, just a timeout.
  # Everything that looked like the cause was in fact correct: 8188 IS in
  # wg0.allowedTCPPorts, netavark's DNAT rules WERE present
  # (--dport 8188 -j DNAT --to-destination 10.88.0.5:8188), FORWARD policy WAS
  # ACCEPT, and the host itself could reach 10.88.0.5:8188 directly.
  #
  # Cause: DNAT rewrites the destination to a container address, so the packet is
  # no longer addressed to this host — it must be FORWARDED to the podman bridge,
  # and never reaches the INPUT chain the nixos-fw ACCEPT rule lives in. With
  # ip_forward=0 the kernel drops it silently. netavark sets this itself when it
  # creates a network, but that is a side effect which does not survive a reboot;
  # declaring it makes container reachability deterministic.
  #
  # NOTE: this does make the host capable of routing between its interfaces, and
  # FORWARD policy here is ACCEPT. That is the normal posture for a container host
  # and is unchanged from when podman set the flag itself, but if this box ever
  # sits between untrusted networks, tighten FORWARD rather than reverting this.
  # Set BOTH keys. They are aliases for the same kernel behaviour, and the generated
  # 60-nixos.conf was emitting them in conflict — `net.ipv4.conf.all.forwarding=0`
  # (line 12, from the NixOS networking default) against `net.ipv4.ip_forward=1`
  # (line 21). The runtime value came out 0. Rather than depend on which line
  # systemd-sysctl applies last, make them agree. mkForce is required because the
  # default is not an mkDefault.
  boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkForce true;
  boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = lib.mkForce true;

  networking.networkmanager.ensureProfiles.profiles.wired-static = {
    connection = {
      id = "wired-static";
      type = "ethernet";
      interface-name = "enp191s0";
      autoconnect = true;
      autoconnect-priority = 100;   # beat any auto-generated "Wired connection N"
    };
    ipv4 = {
      method = "manual";
      address1 = "192.168.10.50/24,192.168.10.254";
      dns = "192.168.10.254;";      # router, not this host's own AdGuard (bootstrap)
    };
    ipv6.method = "disabled";
  };

  ################################
  ## Headless disk unlock
  ################################
  # This host is headless, so the LUKS passphrase prompt made every reboot a
  # physical errand. TPM2 unseals both containers automatically; the passphrase
  # slot is kept as the last-resort fallback and is NOT removed.
  #
  # Enrol out-of-band (once per container, prompts for the current passphrase):
  #   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 \
  #     /dev/disk/by-uuid/3b9b7527-7e54-4e86-9c4f-17ed2b0ae357
  #   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 \
  #     /dev/disk/by-uuid/5b0f11a5-9c0e-4610-91b3-181249072eea
  #
  # PCRs 0+7 (firmware + Secure Boot state) deliberately exclude 4/8/9 — those
  # measure bootloader/kernel/initrd, so every nixos-rebuild would invalidate the
  # seal. A BIOS/firmware update still breaks it and needs re-enrolment.
  boot.initrd.luks.devices."cryptroot0".crypttabExtraOpts = [ "tpm2-device=auto" ];
  boot.initrd.luks.devices."cryptroot1".crypttabExtraOpts = [ "tpm2-device=auto" ];

  # Rescue path for exactly that case: when the seal no longer matches, boot falls
  # back to asking for the passphrase. Without a way in that means attaching a
  # monitor; with this, unlock remotely instead:
  #   ssh -p 2222 root@192.168.10.50   then: systemd-tty-ask-password-agent
  #
  # The initrd sshd is reachable on the LAN (initrd has no firewall) and only
  # during the unlock window. Its host key lives on the unencrypted ESP, so treat
  # it as compromised-by-physical-access — it authenticates the endpoint, it does
  # not grant access to data.
  boot.initrd.availableKernelModules = [ "r8169" ];  # wired NIC, needed in initrd
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;                                  # distinct from the real sshd
      authorizedKeys = lib.attrValues secrets.sshKeys;
      # Generate once on the host (string path keeps the private key out of the store):
      #   sudo mkdir -p /etc/secrets/initrd
      #   sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    };
  };

  # Static address in initrd so the rescue endpoint is always at a known IP
  # (NetworkManager's .50 static does not exist this early).
  boot.initrd.systemd.network.networks."10-wired" = {
    matchConfig.Name = "enp191s0";
    address = [ "192.168.10.50/24" ];
  };

  ################################
  ## Headless — no desktop environment
  ################################

  # Larger TTY font for direct-attach troubleshooting
  console.font = "ter-v24n";
  console.packages = [ pkgs.terminus_font ];

  ################################
  ## Remote access (extends shared ssh.nix)
  ################################
  services.openssh.settings.GatewayPorts = "no";

  # Mosh for roaming SSH (survives WiFi drops, laptop sleep)
  programs.mosh = {
    enable = true;
    openFirewall = false;
  };

  ################################
  ## Ollama — local LLM inference
  ################################
  services.ollama = {
    enable = true;
    # Unstable 0.24.0 ROCm — native gfx1151 support (stable 0.21.1 crashed during
    # compute on Strix Halo). Fallback ready: pkgs.unstable.ollama-vulkan.
    package = pkgs.unstable.ollama-rocm;
    # Static user (not DynamicUser) so the dedicated models dataset has stable
    # ownership and can be migrated to a future DAS pool.
    user = "ollama";
    group = "ollama";
    # Bind to WireGuard IP (firewall also restricts to wg0)
    host = "10.100.0.2";
    port = 11434;
    # AMD GPU acceleration (Radeon 8060S, RDNA 3.5, ROCm) comes from the package
    # itself — `acceleration` was removed in 26.05. pkgs.unstable.ollama-rocm above
    # already carries it; this line was redundant with it, not a second control.
    # Models on a dedicated ZFS dataset (rpool/storage/ollama, recordsize=1M,
    # compression=off) — zfs send/recv to a DAS pool later, same mountpoint.
    # Point at the dataset root (already exists + owned by ollama, ZFS-persisted),
    # so ollama creates blobs/manifests there — no subdir tmpfiles race.
    models = "/storage/ollama";
    # Shared backend: two players + Open WebUI + agents.
    environmentVariables = {
      OLLAMA_NUM_PARALLEL = "2";
      OLLAMA_KEEP_ALIVE = "30m";
      # Was 8192, because 0.24 defaults the 70B to a 256K context and with
      # NUM_PARALLEL=2 that KV cache exceeded RAM. That reasoning still holds — the
      # headroom is what changed: the GTT cap above now admits 80 GiB rather than
      # the 62.5 GiB amdgpu picked by default, so 32K x 2 parallel fits.
      #
      # 8192 is too small for retrieval or agent work: tool definitions and a
      # handful of retrieved passages exhaust it before the task starts. Raising
      # the floor here rather than per-request because every caller hit it.
      # Per-request num_ctx can still go higher for one-off long-context jobs.
      OLLAMA_CONTEXT_LENGTH = "32768";
      # Flash attention: faster attention + smaller KV cache on ROCm. Speeds up
      # generation and lets the warm model use less VRAM.
      OLLAMA_FLASH_ATTENTION = "1";
    };
  };

  # Own the models dataset for the static ollama user (ZFS persists this; the rule
  # is a safety net). The dataset is created out of band via `zfs create`.
  systemd.tmpfiles.rules = [
    "d /storage/ollama 0750 ollama ollama - -"
  ];

  ################################
  ## Jellyfin — media server
  ################################
  services.jellyfin = {
    enable = true;
    openFirewall = false; # Managed below
  };

  # VAAPI hardware transcode (Radeon 8060S)
  hardware.graphics.enable = true;

  ################################
  ## AdGuard Home — network DNS ad-blocking
  ################################
  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    # Bind web UI to WireGuard IP (firewall also restricts to wg0)
    host = "10.100.0.2";
    port = 3000;
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        upstream_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.google/dns-query"
        ];
        bootstrap_dns = [ "1.1.1.1" "8.8.8.8" ];
      };
      filtering.enabled = true;
    };
  };

  ################################
  ## NFS
  ################################
  services.nfs.server = {
    enable = true;
    exports = let
      secrets = import ../../secrets/network.nix;
    in ''
      /storage  ${secrets.wireguard.meshSubnet}(rw,sync,no_subtree_check,root_squash,crossmnt)
    '';
  };

  ################################
  ## Firewall
  ################################
  networking.firewall = {
    enable = true;
    logRefusedConnections = true;
    # LAN-accessible services (needed by phones, TVs, other LAN clients)
    allowedTCPPorts = [
      53     # AdGuard DNS
      8096   # Jellyfin
    ];
    allowedUDPPorts = [
      53     # AdGuard DNS
    ];
    # WireGuard-only services (admin/internal)
    # 22=SSH  111/2049=NFS  3000=AdGuard-UI  11434=Ollama  8080=Open-WebUI  8888=SearXNG  8000=ChromaDB
    interfaces."wg0".allowedTCPPorts = [ 22 111 2049 3000 11434 8080 8888 8000 ];
    interfaces."wg0".allowedUDPPorts = [ 111 2049 ];
    interfaces."wg0".allowedUDPPortRanges = [
      { from = 60000; to = 60010; }  # Mosh
    ];
  };

  # Disable LLMNR (unnecessary attack surface on headless server)
  services.resolved.settings.Resolve.LLMNR = "false";

  ################################
  ## Server packages
  ################################
  environment.systemPackages = with pkgs; [
    iotop
    tmux
    mosh

    # AI lab tooling
    python3
    uv
  ];

  ################################
  ## User groups + SSH access
  ################################
  # Additional passwordless sudo commands (extends shared sudo.nix)
  security.sudo.extraRules = lib.mkAfter [{
    users = [ "oat" ];
    commands = [
      { command = "/run/current-system/sw/bin/udevadm"; options = [ "NOPASSWD" ]; }
    ];
  }];
}
