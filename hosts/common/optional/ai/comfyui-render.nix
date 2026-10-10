# ComfyUI — workstation image-generation render node (podman, ROCm 7.2 / gfx1201, RX 9070 XT).
#
# A dedicated second ComfyUI on the workstation's discrete GPU, separate from the
# server's gfx1151 instance (../ai/comfyui.nix). This gives image generation a fast,
# dedicated GPU and takes it OFF the shared server GPU (so Ollama and image gen stop
# contending). Imported by hosts/workstation only. See docs/ai-lab.md for the wider
# image-generation capability and its consumers.
#
# Bound to LOOPBACK **and** wg0. On-box consumers (bench scripts, smoke test) address
# 127.0.0.1; the Open WebUI image-gen tool runs on the server and reaches this node at
# 10.100.0.1:8188 over the mesh. Both publish rules are needed — dropping the loopback
# one would break ai-lab/bench/*.sh and ai-lab/smoke-test, which hardcode 127.0.0.1.
#
# Data: the full ComfyUI tree (core + custom_nodes code + models) lives on the
# storage/comfyui dataset, rsynced from the server — see the deploy notes below.

{ pkgs, lib, net, ... }:

{
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # First start may build/load the ~18 GB image; default ~5 min is too short.
  systemd.services.podman-comfyui-render.serviceConfig.TimeoutStartSec = lib.mkForce "30min";

  # Restart-loop containment. oci-containers sets Restart=always, which is right for a
  # crash but catastrophic for an UNREMOVABLE container: on 2026-08-16 a worker wedged
  # in the KFD driver (see monitoring/gpu-wedge-sentinel.nix for the full chain), podman
  # rm -f could not kill it, every start failed 125, and systemd re-tried every 30s
  # indefinitely — each cycle re-running SIGTERM/SIGKILL and re-loading the image, adding
  # churn to an already starved GPU and burying the real error under rolling journal
  # spam. Give up after 3 failures in 10 min and stay failed, so the fault is a static,
  # inspectable state instead of a moving target.
  #
  # Does NOT prevent the wedge — only stops systemd from amplifying it.
  systemd.services.podman-comfyui-render.startLimitIntervalSec = 600;
  systemd.services.podman-comfyui-render.startLimitBurst = 3;
  systemd.services.podman-comfyui-render.serviceConfig.RestartSec = lib.mkForce "30s";

  virtualisation.oci-containers.containers.comfyui-render = {
    # Locally-derived gfx1201 image — see ai-lab/comfyui/Containerfile.gfx1201 for the
    # build command. localhost/ prefix = no registry pull.
    image = "localhost/comfyui-gfx1201-render:v2";
    ports = [
      "127.0.0.1:8188:8188"  # on-box consumers (bench, smoke test)
      "${net.wireguard.meshIPs.workstation-nixos}:8188:8188" # wg0 — the Open WebUI image-gen tool on the server
    ];
    volumes = [ "/storage/comfyui:/opt/ComfyUI" ]; # full ComfyUI tree (rsynced from server)

    # RDNA4 stability: ComfyUI sees the HIP/ROCm card as "cuda:0" (HIP impersonates
    # CUDA), so it auto-enables two Nvidia-only optimizations — async multi-stream
    # weight offloading and pinned host memory — which trigger a GPU coredump on
    # gfx1201 during the heavy tiled SD-upscale stage (UltimateSDUpscale re-diffusing
    # 1024x1024 tiles). Base render + FaceDetailer survive; the upscale faulted hard.
    # Disabling both makes the full hi-res/detail/upscale pipeline complete cleanly
    # (verified 2026-06-20: 86s end-to-end, no coredump). hipBLASLt/MIOpen env-var
    # workarounds did NOT help — the offload path is the real cause. We override the
    # entrypoint (the image WORKDIR is /opt/ComfyUI) to inject the two flags.
    #
    # --reserve-vram keeps 2 GiB of the 16 GiB card away from ComfyUI for the OS. This
    # GPU is not a headless accelerator — it also drives the desktop, so a workflow that
    # legitimately allocates every last byte freezes the compositor while behaving
    # perfectly correctly. That is the COMMON freeze, and this is its fix.
    #
    # Note it would NOT have prevented the 2026-08-16 driver wedge: a dead-but-unreaped
    # KFD context keeps whatever it had already allocated, reservation or not. Two
    # different failures — this bounds normal operation, the sentinel reports the bug.
    #
    # 2 GiB covers the desktop, not a game. Gaming on this box while a render runs still
    # wants the service stopped: systemctl stop podman-comfyui-render
    entrypoint = "python3";
    cmd = [ "main.py" "--listen" "0.0.0.0" "--port" "8188" "--disable-async-offload" "--disable-pinned-memory" "--reserve-vram" "2.0" ];

    environment = {
      # Pin to the discrete 9070 XT (gfx1201, ROCm device index 0); hides the 9950X
      # iGPU (gfx1036, index 1) so HIP never lands on the weak integrated GPU. Verified
      # index on this host 2026-06-16. No HSA_OVERRIDE — gfx1201 is native on ROCm 7.2.
      ROCR_VISIBLE_DEVICES = "0";
    };
    extraOptions = [
      "--device=/dev/kfd"
      "--device=/dev/dri"            # full DRI — passing only one render node breaks HIP topology enumeration
      # No --group-add: the yanwk/openSUSE base image has no 'video'/'render' group, so
      # podman's name lookup fails ("Unable to find group video"). The GPU device nodes
      # are world-rw (666), so the container needs no supplementary group to use them
      # (verified on-host: the GO/NO-GO stress ran with no group-add).
      "--security-opt=seccomp=unconfined"
      "--shm-size=8g"
    ];
  };

  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 8188 ];

  # Required for the PUBLISHED container port above to be reachable from other mesh
  # hosts. Opening 8188 on wg0 is necessary but NOT sufficient: podman/netavark DNATs
  # the packet to the container's bridge address, so it is no longer addressed to this
  # host and must be FORWARDED — it never reaches the INPUT chain where the nixos-fw
  # ACCEPT rule lives. With ip_forward=0 the kernel drops it silently: no refusal, just
  # a timeout. netavark sets the flag itself when it creates a network, but that is a
  # side effect which does not survive a reboot.
  #
  # Same failure diagnosed on the server 2026-08-16 — see the long-form postmortem in
  # hosts/server/default.nix ("Diagnosed 2026-08-16"). That fix was declared host-locally
  # rather than in a shared module, so it did not cover this host.
  #
  # Set BOTH keys — they are aliases for the same kernel behaviour, and the generated
  # 60-nixos.conf otherwise emits them in conflict (the NixOS networking default writes
  # net.ipv4.conf.all.forwarding=0). mkForce overrides that default.
  #
  # This makes the host capable of routing between its interfaces, and the FORWARD
  # policy is ACCEPT. Normal posture for a container host, but this box also runs
  # NordVPN and Tailscale — if it ever sits between untrusted networks, tighten FORWARD
  # rather than reverting this.
  boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkForce true;
  boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = lib.mkForce true;

  # Diagnostics for the discrete GPU (rocminfo/rocm-smi were absent on this host).
  environment.systemPackages = with pkgs; [ rocmPackages.rocminfo rocmPackages.rocm-smi ];

  # ComfyUI's rootful container uses the render group for /dev/dri/renderD128.
  users.users.oat.extraGroups = lib.mkAfter [ "render" ];
}
