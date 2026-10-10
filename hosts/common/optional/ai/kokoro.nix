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
    # v0.5.0, pinned by digest (2026-10-10): a tag can be moved to different content; a
    # digest cannot. This is the index the tag resolved to then — already the running image.
    image = "ghcr.io/remsky/kokoro-fastapi-cpu@sha256:bcf38f9bf7f040b0465dd4352eb0fa0b2db42d4bd91eba16acef0b40e5c57905";
    ports = [ "${net.wireguard.meshIPs.server-nixos}:8880:8880" ]; # wg0 only
  };

  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 8880 ];
}
