# ntfy — self-hosted notification hub for the lab (wg0-only, no public relay).
#
# The lab's private push channel: Claude Code session hooks, the fleet-sentinel,
# and backup checks POST to the `lab-alerts` topic here; the desktops subscribe
# and bridge each message into Noctalia via notify-send (see the mango autostart
# in home/common/optional/desktop/mango/home.nix). Imported by hosts/server.
#
# Publish:   curl -H "Title: ..." -H "Priority: high" -d "body" http://10.100.0.2:2586/lab-alerts
# Web UI:    http://10.100.0.2:2586  (over wg0)

{ net, ... }:

let
  host = "${net.wireguard.meshIPs.server-nixos}";       # wg0 mesh IP
  port = 2586;
in
{
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "http://${host}:${toString port}";
      listen-http = "${host}:${toString port}";   # wg0-bound only
      behind-proxy = false;
      # Cache messages so a subscriber that was briefly offline still receives them.
      cache-file = "/var/lib/ntfy-sh/cache.db";
      cache-duration = "24h";
      # Trusted mesh — no auth layer (wg0 is the gate, like the other lab services).
      auth-default-access = "read-write";
    };
  };

  # wg0-only exposure (matches Ollama/AdGuard/etc.).
  networking.firewall.interfaces."wg0".allowedTCPPorts = [ port ];
}
