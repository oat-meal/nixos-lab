# host-health MCP server (declarative)
# Read-only system health tools for Claude Code, served over stdio via `ssh` on wg0.
# Replaces the old imperative ~/.config/mcp/host-health (uv + .venv).

{ pkgs, net, ... }:

let
  # Python env with just the MCP SDK (provides mcp.server.fastmcp). No venv needed.
  pyEnv = pkgs.python3.withPackages (ps: [ ps.mcp ]);

  # Wrapper Claude Code invokes as `ssh server-nixos host-health-mcp`.
  # PATH covers zfs/zpool/systemctl/journalctl/ollama in a minimal ssh session;
  # OLLAMA_HOST points the `ollama` CLI at the wg0-bound server instance.
  host-health-mcp = pkgs.writeShellScriptBin "host-health-mcp" ''
    export PATH=/run/current-system/sw/bin:$PATH
    export OLLAMA_HOST=${net.wireguard.meshIPs.server-nixos}:11434
    exec ${pyEnv}/bin/python ${../../../../ai-lab/mcp/host-health/server.py} "$@"
  '';
in
{
  # Journal read access for the health/fleet tools is granted fleet-wide via the
  # systemd-journal group in hosts/common/core/users.nix.
  environment.systemPackages = [ host-health-mcp ];
}
