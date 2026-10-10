# sudo and polkit policy for oat — three tiers, decided 2026-10-09
#
#   1. No privilege at all. journalctl (systemd-journal group), systemctl status/show,
#      zpool status / zfs list, nixos-rebuild build, nix build. Most "sudo" use was habit.
#   2. Passwordless, bounded. The lab-* wrappers below take no free-form arguments, and
#      polkit lets oat start/stop/restart the units a host lists in
#      lab.restartableUnits — `systemctl restart <unit>` with no sudo at all.
#   3. Everything else needs the password. By default it is cached for 60 minutes across
#      every terminal (timestamp_type=global), shared with agents running as oat: after
#      you type it once, a Claude session can sudo for the rest of the hour. Hosts can
#      narrow this with lab.sudoCache — the server does (tty, 15 min): nobody works there
#      interactively, unattended jobs run as oat, and every deploy would otherwise open a
#      root window for all of them.
#
# What this replaced: NOPASSWD for nixos-rebuild, nix*, systemctl, git, podman, zfs,
# zpool, iptables/ip6tables/nft and ss (+ udevadm on the server). That list was called
# "scoped" and was root by construction — its own comments said so for nixos-rebuild,
# nix* and podman, and `nix*` also matched nix-shell/nix-env, and `sudo git` reaches a
# root shell through its pager. Any process running as oat had silent root on all three
# hosts. nixos-rebuild cannot come back here: /etc/nixos is oat-writable, so "may switch
# without a password" is "may become root without a password".
#
# The wrappers keep the diagnostic reach the old rules were added for (2026-08-16 the
# container-port investigation needed the live ruleset and listener owners; 2026-09-16
# the ComfyUI custom-node rounds needed "is module X in the image") without granting
# rule modification or arbitrary container execution.

{ config, lib, pkgs, ... }:

let
  wrappers = [
    (pkgs.writeShellApplication {
      name = "lab-fw-dump";
      runtimeInputs = [ pkgs.nftables pkgs.iptables ];
      text = ''
        echo "### nft list ruleset"; nft list ruleset
        echo "### iptables-save";    iptables-save
        echo "### ip6tables-save";   ip6tables-save
      '';
    })
    (pkgs.writeShellApplication {
      name = "lab-listeners";
      runtimeInputs = [ pkgs.iproute2 ];
      text = "ss -tulpnH";
    })
    (pkgs.writeShellApplication {
      name = "lab-podman-probe";
      runtimeInputs = [ pkgs.podman ];
      text = ''
        name='^[A-Za-z0-9_.-]+$'
        module='^[A-Za-z_][A-Za-z0-9_.]*$'
        usage() { echo "usage: lab-podman-probe ps | images | inspect C | logs C | has-py C MODULE" >&2; exit 2; }
        c="''${2:-}"; m="''${3:-}"
        case "''${1:-}" in
          ps)      podman ps -a ;;
          images)  podman image ls ;;
          inspect) [[ "$c" =~ $name ]] || usage; podman inspect "$c" ;;
          logs)    [[ "$c" =~ $name ]] || usage; podman logs --tail 200 "$c" ;;
          has-py)  [[ "$c" =~ $name && "$m" =~ $module ]] || usage
                   if podman exec "$c" python3 -c \
                        'import importlib.util, sys; sys.exit(importlib.util.find_spec(sys.argv[1]) is None)' "$m"
                   then echo "present: $m"
                   else echo "absent: $m"; exit 1
                   fi ;;
          *)       usage ;;
        esac
      '';
    })
  ];
in
{
  options.lab.sudoCache = {
    type = lib.mkOption {
      type = lib.types.enum [ "global" "tty" "ppid" ];
      default = "global";
      description = "sudo timestamp_type: share the password cache across terminals, or per terminal.";
    };
    minutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "sudo timestamp_timeout in minutes.";
    };
  };

  options.lab.restartableUnits = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Units oat may start, stop or restart via polkit without a password.";
  };

  config = {
    environment.systemPackages = wrappers;

    security.sudo.extraConfig = ''
      Defaults timestamp_type=${config.lab.sudoCache.type}
      Defaults timestamp_timeout=${toString config.lab.sudoCache.minutes}
    '';

    security.sudo.extraRules = [{
      users = [ "oat" ];
      commands = map (w: {
        command = "/run/current-system/sw/bin/${w.name}";
        options = [ "NOPASSWD" ];
      }) wrappers;
    }];

    # Restart, not edit: what a unit runs is fixed by its Nix definition, so restarting
    # one grants no privilege. Explicit list rather than "any unit" because some units
    # are reachable only to escalate or to take the host down (rescue/emergency,
    # templated instances whose argument reaches ExecStart).
    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        var units = ${builtins.toJSON config.lab.restartableUnits};
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "oat" &&
            units.indexOf(action.lookup("unit")) >= 0 &&
            ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
