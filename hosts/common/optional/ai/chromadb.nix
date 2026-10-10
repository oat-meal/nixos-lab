# ChromaDB — vector store for RAG / persistent memory (Phase 3).
# wg0-only. Data on the systemd StateDirectory (/var/lib/chromadb, rpool) — the
# store is small; models (the big data) get the dedicated /storage dataset.

{ net, ... }:

{
  services.chromadb = {
    enable = true;
    host = "${net.wireguard.meshIPs.server-nixos}"; # wg0
    port = 8000;
    openFirewall = false; # firewall handled centrally (wg0-only)
  };
}
