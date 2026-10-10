# WireGuard mesh VPN — secure connectivity between lab hosts
#
# Setup — run once per host:
#   sudo mkdir -p /etc/wireguard
#   wg genkey | sudo tee /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
#   sudo chmod 600 /etc/wireguard/private.key
# Then add each host's public key to hosts/network.nix and redeploy all hosts.

{ config, pkgs, lib, net, ... }:

let
  hostname = config.networking.hostName;
  sopsEnabled = config.sops.secrets ? "wireguard/${hostname}";

  publicKeys = net.wireguard.publicKeys;
  meshIPs = net.wireguard.meshIPs;
  lanEndpoints = net.lanIPs;
  port = net.wireguard.port;

  myIP = meshIPs.${hostname};

  # Build peer list for all other hosts
  peers = lib.mapAttrsToList (name: pubkey: {
    publicKey = pubkey;
    allowedIPs = [ "${meshIPs.${name}}/32" ];
    endpoint = "${lanEndpoints.${name}}:${toString port}";
    persistentKeepalive = 25;
  }) (lib.filterAttrs (name: _: name != hostname) publicKeys);

in
{
  imports = [ ./mesh-zones.nix ];   # per-peer trust zones; inert until one is declared

  environment.systemPackages = with pkgs; [
    wireguard-tools
  ];

  networking.wireguard.interfaces.wg0 = {
    ips = [ "${myIP}/24" ];
    listenPort = port;
    privateKeyFile =
      if sopsEnabled
      then config.sops.secrets."wireguard/${hostname}".path
      else "/etc/wireguard/private.key";
    inherit peers;
  };

  networking.firewall.allowedUDPPorts = [ port ];

  # Loose reverse path filtering for WireGuard (strict rp_filter from hardening blocks handshakes)
  # Linux uses max(all, interface) so all must also be loosened
  boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = lib.mkForce 2;
  boot.kernel.sysctl."net.ipv4.conf.wg0.rp_filter" = lib.mkForce 2;
}
