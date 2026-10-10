# Fleet Health Sentinel — nightly LLM triage of wg0 fleet health.
#
# Runs ai-lab/sentinel/sentinel.py as oat on the server: collects a health
# snapshot from all three hosts over wg0, has the local qwen3 MoE triage it
# against docs/audit/known-states.md, and writes a severity-ranked report to
# /var/lib/fleet-sentinel/latest.md (plus a journal summary; optional ntfy push).
# READ-ONLY — it never changes any host. Imported by hosts/server only.

{ pkgs, net, ... }:

let
  # Stdlib only — no extra Python deps.
  sentinel = pkgs.writeShellScriptBin "fleet-sentinel" ''
    export PATH=/run/current-system/sw/bin:$PATH
    exec ${pkgs.python3}/bin/python ${../../../../ai-lab/sentinel/sentinel.py} "$@"
  '';
in
{
  # Also available as a manual command: `fleet-sentinel`.
  environment.systemPackages = [ sentinel ];

  systemd.services.fleet-sentinel = {
    description = "Fleet health sentinel (collect + LLM triage, read-only)";
    # Order after the network is up, but do NOT `wants` it: a timer-driven monitor
    # must never pull network-online.target into the boot transaction (with a
    # Persistent catch-up run that reorders boot). Doing so on the workstation
    # raced the WCN7850 WiFi firmware init and wedged the card — see
    # docs/audit/postmortem-2026-08-wcn7850-wifi.md. `after` alone still orders
    # the daily run correctly (network-online is reached by the network stack).
    after = [ "network-online.target" "ollama.service" ];
    path = [ pkgs.openssh ];              # ssh to workstation/laptop over wg0
    serviceConfig = (import ../../sandbox.nix) // {
      # Needs: ~oat/.ssh (lab_monitor key, known_hosts), /dev/zfs for its local probe.
      ProtectHome = "read-only";
      ReadWritePaths = [ "/home/oat/.ssh" ];
      PrivateDevices = false;
      DevicePolicy = "closed";
      DeviceAllow = [ "/dev/zfs rw" ];
      Type = "oneshot";
      User = "oat";                       # uses oat's ssh keys + systemd-journal group
      StateDirectory = "fleet-sentinel";  # /var/lib/fleet-sentinel (oat-owned)
      TimeoutStartSec = "300";            # model load + triage headroom
      Environment = [
        "OLLAMA_HOST_URL=http://${net.wireguard.meshIPs.server-nixos}:11434"
        # Left as-is. qwen3:30b-a3b ignores `think: false` in general, but this
        # call passes `format: ENRICH_SCHEMA`, and schema-constrained decoding
        # stops it running on — measured 2026-08-25: 70 tokens, done=stop, 5.5s.
        # A swap to qwen2.5:7b would be faster (2.0s) and far smaller to load,
        # but that is a robustness preference, not a fix, and should be decided
        # on its own merits rather than smuggled in as one.
        "SENTINEL_MODEL=qwen3:30b-a3b"
        "KNOWN_STATES=/etc/nixos/docs/audit/known-states.md"
        "SENTINEL_REPORT=/var/lib/fleet-sentinel/latest.md"
        "NTFY_URL=http://${net.wireguard.meshIPs.server-nixos}:2586/lab-alerts"   # self-hosted ntfy (wg0)
      ];
      ExecStart = "${sentinel}/bin/fleet-sentinel";
    };
  };

  systemd.timers.fleet-sentinel = {
    description = "Nightly fleet health sentinel";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 07:30:00";
      Persistent = true;                  # run on boot if a scheduled run was missed
      RandomizedDelaySec = "5m";
    };
  };
}
