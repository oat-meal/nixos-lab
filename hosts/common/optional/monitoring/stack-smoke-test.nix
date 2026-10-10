# AMD ROCm stack smoke test (daily canary).
#
# Runs ai-lab/smoke-test/smoke_test.py as oat on the workstation: a 1-token Ollama
# generation (gfx1151) + a tiny ComfyUI image gen (gfx1201). Alerts the lab ntfy
# hub if either fails — catches the documented fragility (a flake update breaking
# ollama-rocm or the RDNA4 ComfyUI image) before you hit it. Imported by the
# workstation (it can reach Ollama over wg0 + ComfyUI on loopback).

{ pkgs, net, ... }:

let
  smoke = pkgs.writeShellScriptBin "stack-smoke-test" ''
    export PATH=/run/current-system/sw/bin:$PATH
    exec ${pkgs.python3}/bin/python ${../../../../ai-lab/smoke-test/smoke_test.py} "$@"
  '';
in
{
  environment.systemPackages = [ smoke ];   # also runnable on demand

  systemd.services.stack-smoke-test = {
    description = "AMD ROCm stack smoke test (ollama + ComfyUI)";
    # Order after the network is up, but do NOT `wants` it. This unit's Persistent
    # timer + wants=network-online.target is what pulled the target into the boot
    # transaction on workstation-nixos, so NetworkManager engaged wlp16s0 at T+1s and
    # lost the race against ath12k firmware init — wedging WiFi for days (root cause
    # bisected in docs/audit/postmortem-2026-08-wcn7850-wifi.md; commit 183f279
    # disabled this module, 769f86b fixed the same pattern in fleet-sentinel and
    # update-advisor but missed this one, the original culprit). `after` alone still
    # orders the run correctly; network-online is reached by the network stack anyway.
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "oat";
      TimeoutStartSec = "300";
      Environment = [
        "OLLAMA_HOST_URL=http://${net.wireguard.meshIPs.server-nixos}:11434"
        "COMFY_URL=http://127.0.0.1:8188"
        "SMOKE_MODEL=qwen2.5:7b"
        "NTFY_URL=http://${net.wireguard.meshIPs.server-nixos}:2586/lab-alerts"
      ];
      ExecStart = "${smoke}/bin/stack-smoke-test";
    };
  };

  systemd.timers.stack-smoke-test = {
    description = "Daily AMD ROCm stack smoke test";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 08:15:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
