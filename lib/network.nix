# Lab network facts: username, LAN and WireGuard mesh addresses, public keys,
# Syncthing device IDs. The single source for every module, which receives it as the
# `net` argument (flake.nix specialArgs) instead of importing it.
#
# PLAINTEXT ON PURPOSE since 2026-10-09. It was secrets/network.nix under git-crypt,
# but nothing in it is secret — private addresses and PUBLIC keys, and the mesh IPs
# were already in plain text in ~45 other public files. The encryption cost real
# things: no CI could evaluate the flake, and the key had to be synced to every host.
# Real secrets (WireGuard private keys) are sops-encrypted in secrets/secrets.yaml.
# Nothing that would be dangerous to publish belongs in this file.
{
  # Primary username
  user = "oat";

  # LAN subnet
  lanSubnet = "192.168.10.0/24";

  # Per-host LAN IPs
  lanIPs = {
    workstation-nixos = "192.168.10.92";
    server-nixos = "192.168.10.50";
    laptop-nixos = "192.168.10.90";
  };

  # WireGuard mesh
  wireguard = {
    port = 51821;
    meshSubnet = "10.100.0.0/24";
    meshIPs = {
      workstation-nixos = "10.100.0.1";
      server-nixos = "10.100.0.2";
      laptop-nixos = "10.100.0.3";
    };
    publicKeys = {
      workstation-nixos = "/aXijLWxpFHALoGNKxx6Xfxrq8/yp5QFHvq71FrKWUs=";
      server-nixos = "SKdV5k3Z0j/rKCVCCgFY85yEZP2BLjiYRC5THzYF6lA=";
      laptop-nixos = "OHBcYHcmMLHnv5FsUzWbCR3bK/IJkQCJr7XIILyNfxw=";
    };
  };

  # Syncthing device IDs
  syncthing = {
    workstation-nixos = "TGRALSF-ONMIB6S-PYNGFGZ-FMXOPYU-3UBBRBM-MG6CTOI-Y7IM6KX-DTQIZQ3";
    laptop-nixos = "YDRQEFN-ULKGQGA-C7ZVRP4-IEXLZR6-BWG7YFC-4HTAXY3-FRGDC3E-IVYPDQU";
    server-nixos = "HGBUVOU-CM2A2DB-GPZ7F5D-CTKF7PD-PVVBX5O-H2FV3QB-2JKHT7X-OKFLHQ2";
  };

  # SSH public keys
  sshKeys = {
    workstation-nixos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICp+d/UJ6mLg/U9Id7rTo7JvQp5sw0zPfcEHZRM8k/Pg oat@workstation-nixos";
    laptop-nixos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGGiOSgzvm0kw7IlujuDp4JPKaBbmb9hL5sIjsGBQ8pQ oat@laptop-nixos";
    server-nixos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA03C0ZiMk1FczpA0WKZErN+ykVWg1YujwMAEczNmjeq oat@server-nixos";
  };

  # Public key of the server's unattended probes (fleet-sentinel, host-health MCP).
  # Private half: ~oat/.ssh/lab_monitor on server-nixos only. Authorized solely for
  # the lab-monitor user, from the server's mesh IP (security/lab-monitor.nix).
  monitorKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILO6GOJZEQUJ84vMpGFH7N2vOoZDqRRXVsFm4ZGqBVLH lab-monitor@server-nixos";
}
