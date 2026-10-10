# homepage-dashboard — single landing page for the lab tools.
# One wg0 URL (http://10.100.0.2:8085) that links to every service and live-pings each
# for up/down status. wg0-only: bound behind the firewall like the other lab services
# (homepage listens on 0.0.0.0:8085, but the port is opened ONLY on wg0).

{ net, ... }:

let
  host = "${net.wireguard.meshIPs.server-nixos}"; # server mesh IP (wg0)
  wsHost = "${net.wireguard.meshIPs.workstation-nixos}"; # workstation mesh IP (wg0) — the gfx1201 ComfyUI render node
  port = 8085; # 8085 free; in use: 8080 OWUI, 8091 lab-api, 8188 ComfyUI, 8888 SearXNG
  url = p: "http://${host}:${toString p}";
  wsUrl = p: "http://${wsHost}:${toString p}";
in
{
  services.homepage-dashboard = {
    enable = true;
    listenPort = port;
    openFirewall = false; # firewall is opened on wg0 only, below

    # homepage rejects requests whose Host header isn't allow-listed (v0.9+); permit the
    # ways the page is actually reached over the mesh.
    allowedHosts = "${host}:${toString port},server-nixos:${toString port},localhost:${toString port}";

    settings = {
      title = "AI Lab";
      headerStyle = "boxed";
      theme = "dark";
      color = "slate";
      layout = {
        "AI Tools" = { style = "row"; columns = 4; };
        "Infrastructure" = { style = "row"; columns = 5; };
      };
    };

    # Each entry links out and self-monitors (siteMonitor) so the dot shows live up/down.
    services = [
      {
        "AI Tools" = [
          { "Open WebUI" = { href = url 8080; siteMonitor = url 8080; description = "Chat · RAG · image gen"; icon = "open-webui.png"; }; }
          # Primary image-gen node: the workstation's RX 9070 XT (gfx1201). siteMonitor
          # pings it over wg0, so this tile doubles as a live check of the published
          # container port + forwarding path (see ai/comfyui-render.nix).
          { "ComfyUI (workstation)" = { href = wsUrl 8188; siteMonitor = wsUrl 8188; description = "Image generation · gfx1201"; icon = "comfyui.png"; }; }
          # Fallback instance on the server's gfx1151, shared with Ollama.
          { "ComfyUI (server)" = { href = url 8188; siteMonitor = url 8188; description = "Image generation · gfx1151 fallback"; icon = "comfyui.png"; }; }
          { "SearXNG" = { href = url 8888; siteMonitor = url 8888; description = "Meta search"; icon = "searxng.png"; }; }
        ];
      }
      {
        "Infrastructure" = [
          { "AdGuard Home" = { href = url 3000; siteMonitor = url 3000; description = "DNS · ad-blocking"; icon = "adguard-home.png"; }; }
          { "Jellyfin" = { href = url 8096; siteMonitor = url 8096; description = "Media server"; icon = "jellyfin.png"; }; }
          { "ChromaDB" = { href = url 8000; siteMonitor = url 8000; description = "Vector DB (RAG)"; icon = "mdi-database"; }; }
          { "Lab API" = { href = "${url 8091}/docs"; siteMonitor = "${url 8091}/openapi.json"; description = "quorum · rag · research"; icon = "mdi-api"; }; }
          { "Ollama" = { href = url 11434; siteMonitor = url 11434; description = "LLM inference"; icon = "ollama.png"; }; }
        ];
      }
    ];

    widgets = [
      { resources = { label = "server"; cpu = true; memory = true; disk = "/storage"; }; }
      { search = { provider = "custom"; url = "${url 8888}/search?q="; target = "_blank"; }; }
    ];
  };

  # Bind only after WireGuard is up, and open the port on wg0 alone (mesh-only access).
  systemd.services.homepage-dashboard = {
    after = [ "wireguard-wg0.service" ];
    wants = [ "wireguard-wg0.service" ];
  };
  networking.firewall.interfaces."wg0".allowedTCPPorts = [ port ];
}
