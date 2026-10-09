# SSH server — WireGuard mesh only
# Hardened sshd with fail2ban, bound to WireGuard IP

{ config, lib, ... }:

let
  secrets = import ../../../../secrets/network.nix;
  hostname = config.networking.hostName;
  wgIP = secrets.wireguard.meshIPs.${hostname};
in
{
  services.openssh = {
    enable = true;
    openFirewall = false;
    listenAddresses = [{ addr = wgIP; port = 22; }];
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      X11Forwarding = false;
      MaxAuthTries = 3;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
      AllowTcpForwarding = false;
    };
  };

  # Wait for WireGuard before binding (sshd listens on wg0 IP)
  systemd.services.sshd = {
    after = [ "wireguard-wg0.service" ];
    wants = [ "wireguard-wg0.service" ];
  };

  # SSH only over WireGuard mesh
  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 22 ];

  # Authorize the hosts a person works FROM. The server's key is deliberately absent:
  # it is used unattended, so it cannot carry a passphrase, and its probes now log in
  # as lab-monitor instead (security/lab-monitor.nix). ssh from the server to another
  # host as oat no longer works, by design.
  users.users.oat.openssh.authorizedKeys.keys =
    lib.attrValues (removeAttrs secrets.sshKeys [ "server-nixos" ]);

  # Rate-limit SSH brute force
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment.enable = true;
    # Never ban trusted WireGuard mesh peers — sshd only listens on wg0, so a
    # banned mesh host (e.g. from rapid/automated SSH) locks itself out of all
    # services. The mesh is already encrypted and key-authenticated.
    ignoreIP = [ "10.100.0.0/24" ];
  };
}
