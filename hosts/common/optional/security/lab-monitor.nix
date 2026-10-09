# lab-monitor — the identity the server's unattended probes log in as.
#
# fleet-sentinel and the host-health MCP run as oat on server-nixos and ssh to the
# other hosts with a passphrase-free key, because nothing is there to type one. Until
# 2026-10-09 that key was oat's own and was authorized for oat everywhere, so any
# compromise of oat on the server (hy-motion, an MCP bug, a bad dependency) was a
# shell as oat on every host — and, under the old NOPASSWD rules, root on every host.
#
# Now the probes use a separate key (~oat/.ssh/lab_monitor on the server), authorized
# only here, only from the server's mesh address, with no pty or forwarding, for a
# system user whose single privilege is reading the journal. Everything the probes
# run is unprivileged: systemctl --failed/is-active, df, zpool/zfs list, journalctl.
# Imported by the hosts the server probes — workstation and laptop, not the server.

{ config, lib, pkgs, ... }:

let
  secrets = import ../../../../secrets/network.nix;
  serverIP = secrets.wireguard.meshIPs.server-nixos;
in
{
  users.groups.lab-monitor = { };

  users.users.lab-monitor = {
    isSystemUser = true;
    group = "lab-monitor";
    extraGroups = [ "systemd-journal" ];
    home = "/var/lib/lab-monitor";
    createHome = true;
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      ''restrict,from="${serverIP}" ${secrets.monitorKey}''
    ];
  };
}
