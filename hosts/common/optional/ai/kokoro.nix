# Kokoro TTS — neural text-to-speech for narration (scene/voice narration, co-pilot use).
# Runs as the kokoro-fastapi CPU container (OpenAI-compatible /v1/audio/speech API). Kokoro is a
# small, fast model, so CPU inference on the Strix Halo is fine and leaves the iGPU for Ollama/ComfyUI.
# wg0-only, matching the rest of the lab.

{ lib, net, ... }:

{
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # First-run image pull is a couple of GB; the default ~5m start timeout is too short.
  systemd.services.podman-kokoro.serviceConfig.TimeoutStartSec = lib.mkForce "30min";

  virtualisation.oci-containers.containers.kokoro = {
    image = "ghcr.io/remsky/kokoro-fastapi-cpu:v0.5.0";
    ports = [ "${net.wireguard.meshIPs.server-nixos}:8880:8880" ]; # wg0 only
  };

  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 8880 ];
}
