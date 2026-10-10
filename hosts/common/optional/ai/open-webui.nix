# Open WebUI — web chat frontend for the local Ollama models.
# wg0-only; reachable from the workstation browser over the mesh.

{ net, ... }:

{
  services.open-webui = {
    enable = true;
    host = "${net.wireguard.meshIPs.server-nixos}"; # wg0
    port = 8080;
    openFirewall = false; # firewall handled centrally (wg0-only)
    environment = {
      # Talk to the local Ollama over wg0.
      OLLAMA_BASE_URL = "http://${net.wireguard.meshIPs.server-nixos}:11434";
      # Local RAG embeddings via Ollama (no HF downloads).
      RAG_EMBEDDING_ENGINE = "ollama";
      RAG_EMBEDDING_MODEL = "nomic-embed-text";
      # Auth on; admin account created — signup locked.
      WEBUI_AUTH = "True";
      ENABLE_SIGNUP = "False";
      # No telemetry / phone-home.
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
      HF_HUB_OFFLINE = "1";
      # No outbound at all: no community sharing, no update pings, no usage stats.
      ENABLE_COMMUNITY_SHARING = "False";
      ENABLE_VERSION_UPDATE_CHECK = "False";
      ENABLE_PUBLIC_ACTIVE_USERS_COUNT = "False";
    };
  };
}
