# Off-host kernel log: netconsole from a sender to the server's journal.
#
# 2026-10-13: the workstation froze between 15:11 and 15:14 with userspace stalled
# (ping answered, sshd never sent its banner) and the journal simply STOPS at 15:11:02.
# Whatever the kernel said about it — hung tasks, OOM, amdgpu — never reached the disk,
# because journald was one of the stalled tasks. A local log cannot record the failure
# that stops local logging. netconsole sends printk straight from the kernel as UDP via
# netpoll, with no userspace and no filesystem in the path.
#
#   sender:   a configfs netconsole target on the LAN interface, pointed at the server.
#   receiver: socat on the server, one journal line per message, identifier `netconsole`.
#             Read with:  journalctl -t netconsole -S -1h
#
# ⚠️ LAN interface, not wg0. netconsole needs a netpoll-capable device and WireGuard is
# not one; it also must not depend on a userspace-driven tunnel staying up.
#
# ⚠️ netconsole is a CONSOLE: it only carries messages below console_loglevel. The
# workstation boots with consoleLogLevel = 1 (quiet tuigreet/unlock screen), at which
# only KERN_EMERG passes, so the sender raises it to `level` AFTER boot. Stage 1 stays
# quiet; the VT behind the session gets the same messages, which is the cost. At 4,
# KERN_ERR and above pass: hung tasks, RCU stalls, soft lockups, oopses, amdgpu ring
# timeouts. NOT the kernel OOM-killer report (KERN_WARNING, needs 5) — but SysRq output
# (W, M) is forced to every console regardless of level, so a frozen box can still be
# made to talk. Measured noise at 4: ~2000 lines/boot, nearly all `kauditd hold queue
# overflow` (see audit rules).
#
# No wants=network-online.target (boot-ordering grab race, see stack-smoke-test notes):
# the sender orders after it only, and retries until the interface has its address.

{ config, lib, pkgs, net, ... }:

let
  cfg = config.lab.netconsole;
  inherit (lib) mkOption mkEnableOption mkIf mkMerge types;
  sandbox = import ../../sandbox.nix;
  hostname = config.networking.hostName;
in
{
  options.lab.netconsole = {
    port = mkOption {
      type = types.port;
      default = 6666;
      description = "UDP port the receiver listens on.";
    };
    send = {
      enable = mkEnableOption "sending kernel messages to the server with netconsole";
      interface = mkOption {
        type = types.str;
        example = "enp17s0";
        description = "LAN interface to send from (must support netpoll: not wg0).";
      };
      target = mkOption {
        type = types.str;
        default = net.lanIPs.server-nixos;
        description = "Receiver's LAN IP. Must be on-link: netconsole does not route.";
      };
      level = mkOption {
        type = types.ints.between 1 8;
        default = 4;
        description = "console_loglevel set after boot; messages below it are sent.";
      };
    };
    receive = {
      enable = mkEnableOption "receiving netconsole messages into the journal";
      interface = mkOption {
        type = types.str;
        example = "enp191s0";
        description = "LAN interface to open the port on.";
      };
      sender = mkOption {
        type = types.str;
        default = net.lanIPs.workstation-nixos;
        description = "The one source IP accepted (messages carry no hostname, so one sender per port).";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.send.enable {
      boot.kernelModules = [ "netconsole" ];

      systemd.services.lab-netconsole = {
        description = "Send kernel messages to ${cfg.send.target} (netconsole)";
        after = [ "network-online.target" "sys-kernel-config.mount" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.iproute2 pkgs.iputils pkgs.gawk pkgs.coreutils pkgs.kmod ];
        script = ''
          set -eu
          modprobe netconsole
          dev=${cfg.send.interface}
          src=$(ip -4 -o addr show dev "$dev" | awk '{split($4,a,"/"); print a[1]; exit}')
          [ -n "$src" ] || { echo "$dev has no IPv4 address yet"; exit 1; }
          # netpoll sends raw frames, so it needs the receiver's MAC. Resolve it now;
          # fall back to broadcast (still delivered on-link) rather than send nothing.
          ping -c1 -W2 -I "$dev" ${cfg.send.target} >/dev/null 2>&1 || true
          mac=$(ip neigh show ${cfg.send.target} dev "$dev" | awk '/lladdr/ {print $3; exit}')
          [ -n "$mac" ] || { echo "no neighbour entry for ${cfg.send.target}; using broadcast"; mac=ff:ff:ff:ff:ff:ff; }

          t=/sys/kernel/config/netconsole/lab
          [ -d "$t" ] && echo 0 > "$t/enabled" || mkdir "$t"
          echo "$dev"                   > "$t/dev_name"
          echo "$src"                   > "$t/local_ip"
          echo ${cfg.send.target}       > "$t/remote_ip"
          echo ${toString cfg.port}     > "$t/remote_port"
          echo "$mac"                   > "$t/remote_mac"
          echo 1                        > "$t/enabled"

          read -r _ def min boot < /proc/sys/kernel/printk
          echo "${toString cfg.send.level} $def $min $boot" > /proc/sys/kernel/printk
          echo "netconsole: $dev $src -> ${cfg.send.target}:${toString cfg.port} ($mac), console_loglevel=${toString cfg.send.level}"
          echo "<${toString (cfg.send.level - 1)}>netconsole: ${hostname} sending to ${cfg.send.target}" > /dev/kmsg
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 30;
        };
      };
    })

    (mkIf cfg.receive.enable {
      networking.firewall.interfaces.${cfg.receive.interface}.allowedUDPPorts = [ cfg.port ];

      systemd.services.lab-netconsole-receive = {
        description = "Receive netconsole kernel messages into the journal";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = sandbox // {
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.socat}/bin/socat -u"
            "UDP-RECV:${toString cfg.port},range=${cfg.receive.sender}/32"
            "STDOUT"
          ];
          DynamicUser = true;
          SyslogIdentifier = "netconsole";
          Restart = "always";
          RestartSec = 5;
        };
      };
    })
  ];
}
