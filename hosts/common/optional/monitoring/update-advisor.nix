# Weekly flake-update advisor (read-only).
#
# Runs ai-lab/update-advisor/update_advisor.py as oat: on a throwaway copy of the
# flake it runs `nix flake update`, diffs which direct inputs would bump, and asks
# qwen3 for a risk briefing tuned to this AMD ROCm + gaming lab. Writes a report
# and pings the ntfy hub when updates are available. Never touches the real flake
# or switches anything. Imported by hosts/server (always-on → the timer fires).

{ pkgs, net, ... }:

let
  advisor = pkgs.writeShellScriptBin "update-advisor" ''
    export PATH=/run/current-system/sw/bin:$PATH
    exec ${pkgs.python3}/bin/python ${../../../../ai-lab/update-advisor/update_advisor.py} "$@"
  '';
in
{
  environment.systemPackages = [ advisor ];   # also runnable on demand

  systemd.services.update-advisor = {
    description = "Flake-update advisor (preview + LLM risk briefing, read-only)";
    # Order after the network is up, but do NOT `wants` it: a timer-driven monitor
    # must never pull network-online.target into the boot transaction (with a
    # Persistent catch-up run that reorders boot). That anti-pattern wedged the
    # workstation WCN7850 WiFi — see docs/audit/postmortem-2026-08-wcn7850-wifi.md.
    after = [ "network-online.target" "ollama.service" ];
    serviceConfig = {
      # Light sandboxing: it runs `nix flake update` as oat, which writes ~/.cache/nix, so no
      # ProtectHome / ProtectSystem=strict / namespace or syscall filters here.
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "full";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      CapabilityBoundingSet = "";
      Type = "oneshot";
      User = "oat";
      StateDirectory = "update-advisor";
      TimeoutStartSec = "1200";   # `nix flake update` fetches inputs + the LLM call
      Environment = [
        "NIXOS_DIR=/etc/nixos"
        "OLLAMA_HOST_URL=http://${net.wireguard.meshIPs.server-nixos}:11434"
        "ADVISOR_MODEL=qwen3:30b-a3b"
        "ADVISOR_REPORT=/var/lib/update-advisor/latest.md"
        "NTFY_URL=http://${net.wireguard.meshIPs.server-nixos}:2586/lab-alerts"
      ];
      ExecStart = "${advisor}/bin/update-advisor";
    };
  };

  systemd.timers.update-advisor = {
    description = "Weekly flake-update advisor";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon 09:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };
}
