# AI-lab OpenAPI tool server — exposes the lab tools (quorum / RAG / research) as
# OpenAPI endpoints so Open WebUI's tool-calling (and any OpenAPI client) can call
# them. wg0-only, unprivileged (DynamicUser). The host-health tools stay in the
# Claude Code MCP — they need system privileges, these three are just network calls.

{ pkgs, net, ... }:

let
  pyEnv = pkgs.python3.withPackages (ps: with ps; [ fastapi uvicorn ]);
  apiDir = ../../../../ai-lab/api;
in
{
  systemd.services.lab-api = {
    description = "AI Lab OpenAPI tool server (quorum/rag/research)";
    after = [ "network.target" "wireguard-wg0.service" ];
    wants = [ "wireguard-wg0.service" ];
    wantedBy = [ "multi-user.target" ];
    # Interpreter + script paths for the stdlib-only lab CLIs (no extra deps).
    environment = {
      LAB_PY = "${pkgs.python3}/bin/python3";
      QUORUM_PY = "${../../../../ai-lab/quorum/quorum.py}";
      RAG_PY = "${../../../../ai-lab/rag/rag.py}";
      RESEARCH_PY = "${../../../../ai-lab/research/research.py}";
    };
    serviceConfig = {
      DynamicUser = true;
      ExecStart = "${pyEnv}/bin/python -m uvicorn server:app --host ${net.wireguard.meshIPs.server-nixos} --port 8091 --app-dir ${apiDir}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # wg0 only (merges with the other wg0 port lists)
  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 8091 ];
}
