# A removable LUKS + ZFS disk, unlocked and imported AFTER boot, never by it.
#
# For the 20 TB USB `media` disk on the server. The stock path (boot.initrd.luks +
# boot.zfs.extraPools) is wrong for a disk that can be locked, unplugged or slow:
# extraPools' import polls for 60s with no ordering on the unlock, and its failure lands
# on zfs-import.target, which the other pools hang off. Here instead:
#
#   /etc/crypttab (stage 2, nofail)   systemd-cryptsetup@<name>: TPM2 first, then the
#                                     passphrase prompt for `timeout`; a missing device is
#                                     given up on after deviceTimeout. Boot never waits.
#   lab-<pool>-import                 wanted by that unlock unit and bound to it: imports
#                                     the pool whenever the container opens (at boot or by
#                                     hand later), exports it before the container closes.
#                                     NFS: re-publishes exports on import; on close withdraws
#                                     them and, if nfsd still pins the pool, restarts
#                                     nfs-server (other exports' clients just retry).
#
# Unlock by hand (first time, or after the TPM seal breaks), from a terminal:
#   sudo systemctl restart systemd-cryptsetup@<name>.service   # prompts; then imports
# Enrol the TPM once the container is known good (passphrase slot stays as fallback):
#   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-uuid/<uuid>
#
# Proven by checks.media-disk (tests/media-disk.nix).

{ config, lib, pkgs, ... }:

let
  cfg = config.lab.mediaDisk;
  inherit (lib) mkOption mkEnableOption mkIf types;
  unlockUnit = "systemd-cryptsetup@${cfg.name}.service";
  zpool = "${config.boot.zfs.package}/bin/zpool";
  zfs = "${config.boot.zfs.package}/bin/zfs";
  exportfs = "${pkgs.nfs-utils}/bin/exportfs";
in
{
  options.lab.mediaDisk = {
    enable = mkEnableOption "a removable LUKS+ZFS disk unlocked and imported after boot";
    uuid = mkOption { type = types.str; description = "UUID of the LUKS partition."; };
    name = mkOption { type = types.str; default = "media"; description = "dm-crypt mapping name."; };
    pool = mkOption { type = types.str; default = "media"; description = "ZFS pool on the container."; };
    keyFile = mkOption {
      type = types.str;
      default = "none";
      description = "crypttab key field: `none` = TPM2 token, else passphrase prompt.";
    };
    tpm2 = mkOption { type = types.bool; default = true; };
    timeout = mkOption {
      type = types.str;
      default = "5min";
      description = "How long the passphrase prompt waits before the unlock unit fails.";
    };
    snapshot = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      example = { "media/library" = [ "frequent" "hourly" "daily" ]; };
      description = ''
        Datasets to opt into services.zfs.autoSnapshot, with the tiers to keep. Set on every
        import, so the opt-in lives here and not as a hand-set property. Tiers not listed are
        turned off for that dataset.
      '';
    };
    deviceTimeout = mkOption {
      type = types.str;
      default = "30s";
      description = "How long to wait for the disk to appear before giving up on it.";
    };
  };

  config = mkIf cfg.enable {
    environment.etc.crypttab.text =
      let
        opts = lib.concatStringsSep "," (
          [ "nofail" "x-systemd.device-timeout=${cfg.deviceTimeout}" "timeout=${cfg.timeout}" ]
          ++ lib.optional cfg.tpm2 "tpm2-device=auto"
        );
      in
      "${cfg.name} UUID=${cfg.uuid} ${cfg.keyFile} ${opts}\n";

    systemd.services."lab-${cfg.pool}-import" = {
      description = "Import ZFS pool ${cfg.pool} from the unlocked ${cfg.name} container";
      wantedBy = [ unlockUnit ];
      bindsTo = [ unlockUnit ];
      after = [ unlockUnit "systemd-modules-load.service" ];
      unitConfig.DefaultDependencies = false;
      before = [ "shutdown.target" ];
      conflicts = [ "shutdown.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Exported before the container closes (stop runs in reverse `after` order). An NFS
        # export of a dataset keeps the pool busy, so those are withdrawn first; the
        # import re-publishes them (exportfs -ra) the next time the container opens.
        ExecStop = pkgs.writeShellScript "lab-${cfg.pool}-export" ''
          ${zpool} list -H ${cfg.pool} >/dev/null 2>&1 || { echo "${cfg.pool}: not imported"; exit 0; }
          if [ -x ${exportfs} ]; then
            mps=$(${zfs} list -H -o mountpoint -r ${cfg.pool} | grep '^/')
            ${exportfs} -s 2>/dev/null | while read -r path client; do
              printf '%s\n' "$mps" | grep -qxF "$path" || continue
              echo "unexporting $path for ''${client%%(*}"
              ${exportfs} -u "''${client%%(*}:$path"
            done
            ${exportfs} -f
          fi
          for _ in 1 2 3; do
            ${zpool} export ${cfg.pool} 2>/dev/null && exit 0
            sleep 1
          done
          # Measured in checks.media-disk: once a dataset has been served over NFS, nfsd keeps
          # it busy after unexport + flush, for 30s+ (not a lease that runs out). Restarting
          # nfs-server drops it; hard-mounted clients of the other exports just retry.
          # Skipped during shutdown, where nfs-server is being stopped anyway.
          if ${pkgs.systemd}/bin/systemctl -q is-active nfs-server.service \
             && [ "$(${pkgs.systemd}/bin/systemctl is-system-running)" != stopping ]; then
            echo "${cfg.pool} still busy: restarting nfs-server to release it"
            # ignore-dependencies: a normal restart pulls in cryptsetup.target, whose start
            # job cancels the stop of this very container.
            ${pkgs.systemd}/bin/systemctl restart --job-mode=ignore-dependencies nfs-server.service
          fi
          ${zpool} export ${cfg.pool}
        '';
      };
      script = ''
        if ${zpool} list -H ${cfg.pool} >/dev/null 2>&1; then
          echo "${cfg.pool}: already imported"
        else
          ${zpool} import -d /dev/mapper/${cfg.name} ${cfg.pool}
        fi
        ${zpool} list -H -o name,health,size,alloc ${cfg.pool}
        # Re-publish NFS exports withdrawn at the last close (no-op without an NFS server).
        if ${pkgs.systemd}/bin/systemctl -q is-active nfs-server.service; then ${exportfs} -ra; fi
        ${lib.concatStrings (lib.mapAttrsToList (ds: tiers: ''
          ${zfs} set com.sun:auto-snapshot=true ${lib.concatMapStrings (t:
            " com.sun:auto-snapshot:${t}=${lib.boolToString (lib.elem t tiers)}"
          ) [ "frequent" "hourly" "daily" "weekly" "monthly" ]} ${ds}
        '') cfg.snapshot)}
      '';
    };
  };
}
