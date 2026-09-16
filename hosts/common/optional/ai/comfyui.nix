# ComfyUI — image generation service (podman, ROCm/gfx1151).
# wg0-only. ComfyUI isn't in nixpkgs and PyTorch+ROCm on gfx1151 is impractical to
# package natively, so it runs as a pinned community container off AMD's rocm/pytorch
# base. Data (models/outputs) lives on the /storage/comfyui dataset.

{ lib, ... }:

{
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # The image is ~11 GB; give the first-run pull/build room (default ~5m is too short).
  systemd.services.podman-comfyui.serviceConfig.TimeoutStartSec = lib.mkForce "30min";

  virtualisation.oci-containers.containers.comfyui = {
    # Locally-derived image: upstream ignatberesnev/comfyui-gfx1151:v0.2 + the
    # detailer/upscaler custom-node Python deps baked into its venv, and as of
    # v0.2-4 the EchoMimicV3 talking-avatar node's deps too. Built out-of-band
    # (rootful podman) — see ai-lab/comfyui/Containerfile for the build command. The
    # localhost/ prefix keeps podman from trying to pull it from a registry.
    #
    # ⚠️ THE TAG MUST BE BUMPED WHEN THE Containerfile CHANGES, and this is the
    # only thing that makes the service pick a rebuild up: oci-containers recreates
    # the container from the image on every restart, so anything pip-installed into
    # a running one is discarded. A Containerfile edit with the tag left alone
    # rebuilds an image nothing refers to.
    image = "localhost/comfyui-gfx1151-impact:v0.2-6";
    ports = [ "10.100.0.2:8188:8188" ]; # wg0 only
    volumes = [ "/storage/comfyui:/opt/ComfyUI" ]; # models, output, custom nodes persist here
    environment = {
    };
    extraOptions = [
      "--device=/dev/kfd"
      "--device=/dev/dri"
      "--group-add=video"
      "--group-add=render"
      "--shm-size=8g"
    ];
  };

  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 8188 ];
}
