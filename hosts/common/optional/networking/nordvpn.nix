{ config, pkgs, lib, ... }:

{
  ################################
  ## NordVPN via wgnord (WireGuard)
  ################################

  # Enable WireGuard kernel module
  networking.wireguard.enable = true;

  # DNS resolution for VPN
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "false";  # Some VPNs have issues with DNSSEC
  };

  # VPN firewall rules (base firewall in networking/firewall.nix)
  networking.firewall = {
    allowedUDPPorts = [ 51820 ];
    trustedInterfaces = [ "wgnord" ];
  };

  # Network namespace for VPN isolation (optional but recommended)
  networking.networkmanager.unmanaged = [ "wgnord" ];

  # Ensure /etc/wireguard directory exists for wgnord configs
  systemd.tmpfiles.rules = [
    "d /etc/wireguard 0700 root root -"
  ];

  # Ensure WireGuard tools are available
  environment.systemPackages = with pkgs; [
    wgnord
    wireguard-tools
    openresolv
  ];

  # Helper scripts for VPN management
  environment.etc."nordvpn-helper.sh" = {
    text = ''
      #!/usr/bin/env bash
      # NordVPN helper script for wgnord

      case "$1" in
        connect)
          if [ -z "$2" ]; then
            echo "Usage: nordvpn-helper connect <country>"
            echo "Example: nordvpn-helper connect us"
            exit 1
          fi
          sudo wgnord connect "$2"
          ;;
        disconnect)
          sudo wgnord disconnect
          ;;
        status)
          sudo wg show wgnord 2>/dev/null || echo "Not connected"
          ;;
        *)
          echo "NordVPN Helper Script"
          echo "Usage: nordvpn-helper {connect|disconnect|status}"
          echo ""
          echo "Commands:"
          echo "  connect <country>  - Connect to NordVPN server in specified country"
          echo "  disconnect         - Disconnect from NordVPN"
          echo "  status            - Show current connection status"
          echo ""
          echo "Examples:"
          echo "  nordvpn-helper connect us"
          echo "  nordvpn-helper connect uk"
          echo "  nordvpn-helper disconnect"
          ;;
      esac
    '';
    mode = "0755";
  };

  # Add helper to PATH
  environment.shellAliases = {
    nordvpn = "/etc/nordvpn-helper.sh";
  };

  ################################
  ## VPN Kill Switch (Optional)
  ################################
  # Uncomment to prevent all traffic when VPN is disconnected
  # networking.firewall.extraCommands = ''
  #   # Block all traffic except VPN
  #   iptables -A OUTPUT -o wgnord -j ACCEPT
  #   iptables -A OUTPUT -o lo -j ACCEPT
  #   iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT  # Local network
  #   iptables -A OUTPUT -p udp --dport 51820 -j ACCEPT  # WireGuard
  #   iptables -A OUTPUT -p udp --dport 53 -j ACCEPT  # DNS
  #   iptables -A OUTPUT -j REJECT
  # '';
}
