# Per-peer trust zones on wg0. Imported by wireguard.nix; inert until a zone is declared.
#
# NONE IS DECLARED, BY DECISION (oat, 2026-10-10): the laptop is a second place to do the
# same work, so every mesh device reaches every wg0 service. Kept for if that changes.
#
# Every port opened with networking.firewall.interfaces."wg0" is open to EVERY mesh peer.
# The trade-off accepted with that: a stolen or compromised laptop reaches Ollama, ChromaDB,
# NFS and the rest exactly as the workstation does. A zone narrows what one peer may OPEN
# on this host:
#
#   lab.meshZones.laptop-nixos = { tcp = [ 22 2586 ]; udp = [ "60000:60010" ]; };
#
# Semantics:
#   - Only NEW connections from that peer's mesh address are filtered. Replies to
#     connections this host opens (lab-monitor probes, backup pulls) are unaffected.
#   - A zone can only narrow: an allowed port still has to be open on wg0 the usual way.
#   - ICMP stays allowed, so ping keeps working as a reachability check.
#   - A peer with no zone is unrestricted: the behaviour before this module.
#
# Self-contained chains (lab-zone-<peer>), never referencing the nixos-fw-* chains: the
# firewall's own start script deletes and recreates those, and a reference from here
# would make that delete fail and the firewall refuse to start.
#
# Proven by checks.security-policy.

{ config, lib, net, ... }:

let
  inherit (lib) mkOption types concatMapStrings concatStrings mapAttrsToList escapeShellArg;
  zones = lib.filterAttrs (n: _: n != config.networking.hostName) config.lab.meshZones;
  chain = peer: "lab-zone-${peer}";
  ipt = "iptables -w";

  start = peer: z: let src = net.wireguard.meshIPs.${peer}; c = chain peer; in ''
    ${ipt} -N ${c} 2>/dev/null || ${ipt} -F ${c}
    ${ipt} -A ${c} -p icmp -j RETURN
    ${concatMapStrings (p: "${ipt} -A ${c} -p tcp --dport ${escapeShellArg (toString p)} -j RETURN\n") z.tcp}
    ${concatMapStrings (p: "${ipt} -A ${c} -p udp --dport ${escapeShellArg (toString p)} -j RETURN\n") z.udp}
    ${ipt} -A ${c} -m limit --limit 6/min -j LOG --log-prefix "lab-zone ${peer} refused: "
    ${ipt} -A ${c} -j DROP
    ${ipt} -I nixos-fw 1 -i wg0 -s ${src} -m conntrack --ctstate NEW -j ${c}
  '';
  stop = peer: _: let src = net.wireguard.meshIPs.${peer}; c = chain peer; in ''
    ${ipt} -D nixos-fw -i wg0 -s ${src} -m conntrack --ctstate NEW -j ${c} 2>/dev/null || true
    ${ipt} -F ${c} 2>/dev/null || true
    ${ipt} -X ${c} 2>/dev/null || true
  '';
in
{
  options.lab.meshZones = mkOption {
    type = types.attrsOf (types.submodule {
      options = {
        tcp = mkOption { type = types.listOf types.port; default = [ ]; };
        udp = mkOption {
          type = types.listOf (types.either types.port types.str);
          default = [ ];
          description = "Ports, or \"from:to\" ranges.";
        };
      };
    });
    default = { };
    description = "Per-peer allowlists for NEW connections arriving on wg0, keyed by host name.";
  };

  config = lib.mkIf (zones != { }) {
    assertions = mapAttrsToList (peer: _: {
      assertion = net.wireguard.meshIPs ? ${peer};
      message = "lab.meshZones.${peer}: not a mesh host in hosts/network.nix";
    }) zones;
    networking.firewall.extraCommands = concatStrings (mapAttrsToList start zones);
    networking.firewall.extraStopCommands = concatStrings (mapAttrsToList stop zones);
  };
}
