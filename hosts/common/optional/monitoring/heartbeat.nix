# Off-host dead-man switch for the server.
#
# Every alert in this lab is published to ntfy ON the server, so a server that is down,
# hung or off the mesh cannot say so: the channel dies with the thing it reports on
# (postmortem 2026-08-wcn7850-wifi, action item #3). This module inverts it:
#
#   publisher (server):  POSTs to the `lab-heartbeat` topic every 5 minutes.
#   watcher (workstation): every 5 minutes asks ntfy for heartbeats newer than maxAge.
#     ok          — at least one arrived
#     missing     — ntfy answered, nothing arrived (timers stopped, publisher broken, clock)
#     unreachable — ntfy did not answer (server down, wg0 down, ntfy down)
#   On a CHANGE of state it alerts locally — a desktop notification on the watcher's own
#   session bus — and never through the server. One alert per transition, plus recovery.
#
# The watcher checks the consumer path: the same ntfy URL the desktop bridge subscribes
# to, and a message the server actually sent, rather than pinging an address.
#
# Proven by checks.heartbeat (tests/heartbeat.nix): ok -> missing -> ok -> unreachable,
# one alert per transition, none while a state persists.

{ config, lib, pkgs, net, ... }:

let
  cfg = config.lab.heartbeat;
  inherit (lib) mkOption mkEnableOption mkIf mkMerge types;
  sandbox = import ../../sandbox.nix;

  notify = pkgs.writeShellScript "lab-heartbeat-notify" ''
    # $1 = state, $2 = body. Root-free: runs as the watcher user, who owns the session bus.
    bus=/run/user/$(id -u)/bus
    [ -S "$bus" ] || { echo "no session bus at $bus; alert logged only"; exit 0; }
    urgency=critical; [ "$1" = ok ] && urgency=normal
    DBUS_SESSION_BUS_ADDRESS=unix:path=$bus \
      ${pkgs.libnotify}/bin/notify-send -u "$urgency" -a lab-heartbeat "Server heartbeat: $1" "$2"
  '';
in
{
  options.lab.heartbeat = {
    url = mkOption {
      type = types.str;
      default = "http://${net.wireguard.meshIPs.server-nixos}:2586/lab-heartbeat";
      description = "ntfy topic URL for heartbeats.";
    };
    publish.enable = mkEnableOption "publishing a heartbeat to ntfy every 5 minutes";
    watch = {
      enable = mkEnableOption "alerting locally when the server's heartbeat stops";
      user = mkOption {
        type = types.str;
        default = net.user;
        description = "Runs the check and receives the desktop notification.";
      };
      maxAge = mkOption {
        type = types.str;
        default = "15m";
        description = "Newest heartbeat older than this = missing (3 publish intervals).";
      };
      alertCommand = mkOption {
        type = types.str;
        default = "${notify}";
        description = "Called as `<cmd> <state> <body>` on every state change.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.publish.enable {
      systemd.services.lab-heartbeat = {
        description = "Publish a heartbeat to ntfy";
        after = [ "ntfy-sh.service" ];
        path = [ pkgs.curl pkgs.coreutils pkgs.systemd ];
        script = ''
          state=$(systemctl is-system-running || true)
          curl -fsS -m 15 -H "Title: heartbeat" -H "Priority: min" \
            -d "$(cat /proc/sys/kernel/hostname) $state up=$(cut -d' ' -f1 /proc/uptime)s" ${lib.escapeShellArg cfg.url}
        '';
        serviceConfig = sandbox // { Type = "oneshot"; DynamicUser = true; };
      };
      systemd.timers.lab-heartbeat = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
      };
    })

    (mkIf cfg.watch.enable {
      systemd.services.lab-heartbeat-watch = {
        description = "Alert locally when the server heartbeat stops";
        path = [ pkgs.curl pkgs.coreutils pkgs.gnugrep ];
        script = ''
          dir=$STATE_DIRECTORY
          if body=$(curl -fsS -m 15 ${lib.escapeShellArg cfg.url}"/json?poll=1&since=${cfg.watch.maxAge}"); then
            if printf '%s' "$body" | grep -q '"event":"message"'; then now=ok; else now=missing; fi
          else
            now=unreachable
          fi
          prev=$(cat "$dir/state" 2>/dev/null || echo ok)
          echo "heartbeat: $now (was $prev)"
          [ "$now" = "$prev" ] && exit 0
          echo "$now" > "$dir/state"
          case "$now" in
            ok)          msg="Heartbeats are arriving again." ;;
            missing)     msg="ntfy answers but no heartbeat in ${cfg.watch.maxAge}: server timers or publisher stopped. ssh server-nixos 'systemctl status lab-heartbeat.timer'" ;;
            unreachable) msg="ntfy on the server does not answer: server down, hung, or wg0 down. Try: ping ${net.lanIPs.server-nixos}; ssh server-nixos" ;;
          esac
          ${cfg.watch.alertCommand} "$now" "$msg"
        '';
        serviceConfig = sandbox // {
          Type = "oneshot";
          User = cfg.watch.user;
          StateDirectory = "lab-heartbeat-watch";
          # The desktop notification connects to /run/user/<uid>/bus, which ProtectHome hides.
          ProtectHome = false;
        };
      };
      systemd.timers.lab-heartbeat-watch = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "10min"; OnUnitActiveSec = "5min"; };
      };
    })
  ];
}
