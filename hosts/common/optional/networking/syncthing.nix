# Syncthing — continuous file sync across lab hosts
# Syncs ~/.claude/ for shared Claude context across all machines
#
# After first deployment, get device IDs with:
#   syncthing cli show system | grep myID
# Then update hosts/network.nix and redeploy.

{ config, lib, net, ... }:

let
  hostname = config.networking.hostName;
  devices = net.syncthing;

  # All hosts except this one
  otherHosts = lib.filterAttrs (name: _: name != hostname) devices;

  # The server only RECEIVES. ~/.claude holds settings.json, whose hooks run shell
  # commands on every host that starts Claude Code; the server runs network services
  # and is the most exposed host, so a compromise there must not be able to plant a
  # hook that the workstation and laptop then execute. Changes made on the server
  # (its own sessions' memory) stay local and show as "locally changed".
  folderType = if hostname == "server-nixos" then "receiveonly" else "sendreceive";
in
{
  services.syncthing = {
    enable = true;
    user = net.user;
    group = "users";
    dataDir = "/home/${net.user}";
    configDir = "/home/${net.user}/.config/syncthing";
    openDefaultPorts = true;

    overrideDevices = true;
    overrideFolders = true;

    settings = {
      devices = lib.mapAttrs (_name: id: {
        inherit id;
      }) otherHosts;

      folders = {
        "claude-context" = {
          path = "/home/${net.user}/.claude";
          type = folderType;
          devices = lib.attrNames otherHosts;
          versioning = {
            type = "simple";
            params.keep = "5";
          };
          ignorePerms = false;
        };
        # NOTE: the AI-lab Obsidian docs moved OFF Syncthing to an on-prem git
        # remote (server:/storage/git/ai-lab-vault.git) for version history +
        # merge-based conflict handling. Do not re-add it here (Syncthing + git
        # on the same folder fight). See Obsidian [[Decisions]].
      };

      options = {
        urAccepted = -1; # Disable usage reporting
        localAnnounceEnabled = true; # LAN discovery
        globalAnnounceEnabled = false; # LAN only
        relaysEnabled = false; # No relay servers
      };
    };
  };
}
