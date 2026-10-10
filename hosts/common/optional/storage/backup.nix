# Off-pool backups: sanoid snapshots on each SOURCE, syncoid PULL into an archive TARGET.
#
# The design proven by checks.recovery-drill and, for this module itself, checks.backup:
#   - PULL: the target runs syncoid and logs in to each source, so a source holds no
#     credential for its own backups — a compromised source cannot reach or delete them.
#   - Least privilege on the source: user `zfs-send`, `zfs allow` send,hold,release on the
#     listed datasets only — never destroy. Its key is accepted only from the target's
#     address (`restrict,from=`).
#   - --use-hold keeps the newest replicated snapshot on both sides until the next good
#     run, so an incremental base survives a source being away for days (the laptop).
#   - Retention: sources keep 24 hourly / 3 daily / 1 monthly locally; the archive keeps
#     30 daily / 24 monthly. (This NixOS sanoid module has no weekly tier.)
#   - The archive parent has a quota (backups can never fill what shares the pool) and is
#     readonly + unmounted (nothing writes to a backup by accident; `zfs receive` still can).
#
# Opt-ins are declared HERE: listed datasets also get com.sun:auto-snapshot=false, so the
# older zfs-auto-snapshot path (hand-set properties) does not snapshot them twice.

{ config, options, lib, pkgs, ... }:

let
  cfg = config.lab.backup;
  hk = cfg.source.hostKeys;
  # Datasets the source offers: the listed ones plus, opted in, the host-key copy.
  sourceDatasets = cfg.source.datasets ++ lib.optional hk.enable hk.dataset;
  inherit (lib) mkOption mkEnableOption mkIf mkMerge types;
  zfs = config.boot.zfs.package;
in
{
  options.lab.backup = {
    source = {
      enable = mkEnableOption "this host as a backup source (sanoid + send-only user)";
      datasets = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Datasets sanoid snapshots and the target may pull.";
      };
      targetAddress = mkOption {
        type = types.str;
        description = "Address the target connects from; zfs-send's key is accepted only from it.";
      };
      targetKey = mkOption {
        type = types.str;
        description = "Public key of the target's syncoid user.";
      };
      # A rebuilt host gets new SSH host keys unless the old ones come back, and a new key
      # means a sops re-key plus new pins everywhere (docs/bare-metal-rebuild.md step 4).
      # Restoring the old key makes that step a copy. Off by default because it puts this
      # host's private keys on the archive: whoever holds root on the archive host (or its
      # syncoid key) can then impersonate this host over ssh. sops is no worse off — any
      # one host key already decrypts all of secrets/secrets.yaml.
      hostKeys = {
        enable = mkEnableOption "copying /etc/ssh host keys (and the initrd key) into a backed-up dataset";
        dataset = mkOption {
          type = types.str;
          default = "rpool/lab-hostkeys";
          description = "Dataset created for the copy; added to the pulled datasets.";
        };
        mountpoint = mkOption {
          type = types.str;
          default = "/var/lib/lab-hostkeys";
        };
      };
    };

    target = {
      enable = mkEnableOption "this host as the backup archive (syncoid pull + sanoid prune)";
      parent = mkOption {
        type = types.str;
        example = "media/backups";
        description = "Dataset every pull lands under; created readonly, unmounted, with a quota.";
      };
      quota = mkOption {
        type = types.str;
        default = "2T";
        description = "Quota on the parent, so backups can never fill the pool they share.";
      };
      sshKey = mkOption {
        type = types.str;
        default = "/var/lib/syncoid/id_ed25519";
        description = "Private key syncoid logs in to sources with (created once, not in git).";
      };
      pulls = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            host = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Source address; null = a dataset on this host (local pull, no ssh).";
            };
            dataset = mkOption { type = types.str; };
            hostKey = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Source's ssh host public key, pinned in known_hosts (required for remote pulls).";
            };
          };
        });
        default = { };
        description = "One syncoid job per entry; lands in <parent>/<name>.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.source.enable {
      users.groups.zfs-send = { };
      users.users.zfs-send = {
        isSystemUser = true;
        group = "zfs-send";
        home = "/var/lib/zfs-send";
        createHome = true;
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [
          ''restrict,from="${cfg.source.targetAddress}" ${cfg.source.targetKey}''
        ];
      };

      # zfs allow and the auto-snapshot opt-out are runtime dataset state; applied from
      # config at boot and on every switch, so they cannot drift.
      systemd.services.lab-backup-source = {
        description = "Backup source: delegate send,hold,release; opt out of zfs-auto-snapshot";
        wantedBy = [ "multi-user.target" ];
        after = [ "zfs.target" ];
        restartTriggers = [ (builtins.toJSON sourceDatasets) ];
        path = [ zfs pkgs.util-linux pkgs.diffutils ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        # Host keys: copied only when they differ, so an unchanged key adds nothing to the
        # snapshots. Root-only; zfs send carries the modes to the archive.
        script = lib.optionalString hk.enable ''
          ds=${lib.escapeShellArg hk.dataset}; mp=${lib.escapeShellArg hk.mountpoint}
          zfs list -H "$ds" >/dev/null 2>&1 || zfs create -o mountpoint="$mp" "$ds"
          mountpoint -q "$mp" || zfs mount "$ds"
          chown root:root "$mp"; chmod 0700 "$mp"
          copy() { cmp -s "$1" "$2" 2>/dev/null || install -D -p -m "$3" "$1" "$2"; }
          for k in /etc/ssh/ssh_host_*_key; do
            [ -f "$k" ] || continue
            copy "$k" "$mp/ssh/''${k##*/}" 0600
            [ -f "$k.pub" ] && copy "$k.pub" "$mp/ssh/''${k##*/}.pub" 0644
          done
          [ -f /etc/secrets/initrd/ssh_host_ed25519_key ] && \
            copy /etc/secrets/initrd/ssh_host_ed25519_key "$mp/initrd/ssh_host_ed25519_key" 0600
        '' + lib.concatMapStrings (ds: ''
          zfs allow -u zfs-send send,hold,release ${lib.escapeShellArg ds}
          zfs set com.sun:auto-snapshot=false ${lib.escapeShellArg ds}
        '') sourceDatasets;
      };

      services.sanoid = {
        enable = true;
        templates.lab-source = {
          hourly = 24; daily = 3; monthly = 1; yearly = 0;
          autosnap = true; autoprune = true;
        };
        datasets = lib.genAttrs sourceDatasets (_: { useTemplate = [ "lab-source" ]; });
      };
    })

    (mkIf cfg.target.enable {
      # Remote pulls connect with strict host-key checking against keys pinned here — no
      # trust-on-first-use. Found by checks.backup: without it, syncoid's first connection
      # fails "Host key verification failed", on the real server exactly as in the VM.
      assertions = lib.mapAttrsToList (n: p: {
        assertion = p.host == null || p.hostKey != null;
        message = "lab.backup.target.pulls.${n}: a remote pull needs hostKey (the source's ssh host public key).";
      }) cfg.target.pulls;
      programs.ssh.knownHosts = lib.mapAttrs' (n: p: lib.nameValuePair "backup-source-${n}" {
        hostNames = [ p.host ];
        publicKey = p.hostKey;
      }) (lib.filterAttrs (_: p: p.host != null) cfg.target.pulls);

      systemd.services.lab-backup-target = {
        description = "Backup target: parent dataset readonly, unmounted, with a quota";
        wantedBy = [ "multi-user.target" ];
        after = [ "zfs.target" ];
        before = map (n: "syncoid-${n}.service") (lib.attrNames cfg.target.pulls);
        restartTriggers = [ cfg.target.parent cfg.target.quota ];
        path = [ zfs ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          p=${lib.escapeShellArg cfg.target.parent}
          zfs list -H "$p" >/dev/null 2>&1 || zfs create -p -o mountpoint=none -o canmount=off "$p"
          zfs set readonly=on "$p"
          zfs set quota=${lib.escapeShellArg cfg.target.quota} "$p"
        '';
      };

      services.syncoid = {
        enable = true;
        sshKey = cfg.target.sshKey;
        commands = lib.mapAttrs (name: p: {
          source = if p.host == null then p.dataset else "zfs-send@${p.host}:${p.dataset}";
          target = "${cfg.target.parent}/${name}";
          extraArgs = [ "--no-sync-snap" "--use-hold" ]
            ++ lib.optionals (p.host != null) [ "--no-privilege-elevation" "--sshoption=StrictHostKeyChecking=yes" ];
          # Local pulls only: the module's default grant on the SOURCE includes snapshot,
          # destroy and mount. --no-sync-snap needs none of them — same rule as zfs-send.
          localSourceAllow = [ "send" "hold" "release" ];
          # --use-hold also holds on the TARGET; the module's default target grant has no
          # hold/release, and syncoid then logs "cannot hold: permission denied" and carries
          # on — the guarantee silently gone. Found by checks.backup.
          localTargetAllow = options.services.syncoid.localTargetAllow.default ++ [ "hold" "release" ];
        }) cfg.target.pulls;
      };

      services.sanoid = {
        enable = true;
        templates.lab-archive = {
          hourly = 0; daily = 30; monthly = 24; yearly = 0;
          autosnap = false; autoprune = true;
        };
        datasets.${cfg.target.parent} = {
          useTemplate = [ "lab-archive" ];
          recursive = true;
          process_children_only = true;
        };
      };
    })
  ];
}
