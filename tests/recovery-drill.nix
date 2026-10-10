# Recovery drill, layer 1: prove the BACKUP DESIGN restores, headless, in two VMs.
#
# Run:  nix build .#checks.x86_64-linux.recovery-drill -L      (needs KVM; ~minutes)
#
# Models the design recommended on 2026-10-09 for real off-host backups:
#   - PULL replication: the backup host runs syncoid and pulls from the server, so
#     the server holds no credential for its own backups — a compromised server
#     cannot reach or delete them.
#   - Least privilege on the source: a dedicated `syncoid` user with `zfs allow`
#     send,hold only. It replicates existing (sanoid-style) snapshots with
#     --no-sync-snap, so it never needs snapshot/destroy rights on the server.
#
# The drill: write data (incl. a git repo) → checksum manifest → replicate →
# destroy the server's pool → restore from the backup → every file's checksum
# matches and `git fsck` passes. Plus the two security properties above, asserted.
# What it cannot prove: real hardware, real data volume, restore time at 20 TB.
{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "recovery-drill";

  nodes =
    let
      common = hostId: { pkgs, ... }: {
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.forceImportRoot = false;          # test VMs have no ZFS root
        networking.hostId = hostId;
        virtualisation.emptyDiskImages = [ 1024 ];   # /dev/vdb, the data pool's disk
        services.openssh.enable = true;
        services.openssh.settings.PermitRootLogin = "prohibit-password";
        environment.systemPackages = with pkgs; [ sanoid git mbuffer lzop pv ];
      };
    in
    {
      server = { ... }: {
        imports = [ (common "5e4e0001") ];
        users.users.syncoid = { isNormalUser = true; };   # send-only identity
      };
      backup = { ... }: {
        imports = [ (common "5e4e0002") ];
      };
    };

  testScript = ''
    start_all()
    server.wait_for_unit("multi-user.target")
    backup.wait_for_unit("multi-user.target")

    server.succeed("zpool create -O mountpoint=none tank /dev/vdb")
    server.succeed("zfs create -o mountpoint=/srv/data tank/data")
    backup.succeed("zpool create -O mountpoint=none vault /dev/vdb")

    # The backup host's key: authorized for the send-only user (replication) and for
    # root (the operator's restore path). The server gets no key for the backup host.
    backup.succeed("mkdir -p /root/.ssh && ssh-keygen -q -t ed25519 -N ''' -f /root/.ssh/id_ed25519")
    pub = backup.succeed("cat /root/.ssh/id_ed25519.pub").strip()
    server.succeed(
        "install -d -o syncoid -m 700 /home/syncoid/.ssh && "
        f"echo '{pub}' > /home/syncoid/.ssh/authorized_keys && chown syncoid /home/syncoid/.ssh/authorized_keys && "
        f"install -d -m 700 /root/.ssh && echo '{pub}' > /root/.ssh/authorized_keys"
    )
    server.succeed("zfs allow -u syncoid send,hold tank/data")

    # Data: random blobs plus a real git repository.
    server.succeed(
        "cd /srv/data && head -c 16M /dev/urandom > blob1 && head -c 4M /dev/urandom > blob2 && "
        "git init -q repo && echo hello > repo/f && "
        "git -C repo -c user.name=t -c user.email=t@t add f && "
        "git -C repo -c user.name=t -c user.email=t@t commit -qm init"
    )
    manifest = server.succeed("cd /srv/data && find . -type f -print0 | sort -z | xargs -0 sha256sum")
    files = len(manifest.strip().splitlines())
    assert files > 5, f"manifest too small to mean anything: {files} files"

    # A sanoid-style snapshot exists on the source; syncoid replicates it, creating none.
    server.succeed("zfs snapshot tank/data@autosnap_drill_1")
    backup.succeed("ssh -o StrictHostKeyChecking=accept-new syncoid@server true")
    backup.succeed("syncoid --no-privilege-elevation --no-sync-snap syncoid@server:tank/data vault/server-data")
    backup.succeed("zfs list -t snapshot vault/server-data@autosnap_drill_1")

    # Security property 1: the send-only user cannot destroy on the server.
    # Control first: the same user CAN use zfs (send) — so a failing destroy is
    # about permission, not a missing PATH or a broken `su`.
    server.succeed("su syncoid -c 'zfs send -nv tank/data@autosnap_drill_1'")
    out = server.fail("su syncoid -c 'zfs destroy tank/data@autosnap_drill_1' 2>&1")
    assert "permission denied" in out.lower(), f"destroy failed for the wrong reason: {out!r}"
    # Security property 2: the server holds no credential that reaches the backup host.
    # "Permission denied" = sshd answered and no key works (not a timeout or refusal).
    out = server.fail("ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@backup true 2>&1")
    assert "permission denied" in out.lower(), f"ssh failed for the wrong reason: {out!r}"

    # Disaster: the server's pool is gone.
    server.succeed("zpool destroy tank && wipefs -a /dev/vdb")
    server.succeed("zpool create -O mountpoint=none tank /dev/vdb")

    # Restore (operator path): newest backup snapshot, full stream, into the new pool.
    snap = backup.succeed("zfs list -H -t snapshot -o name -s creation vault/server-data | tail -1").strip()
    backup.succeed(f"zfs send -R {snap} | ssh -o StrictHostKeyChecking=accept-new root@server zfs receive -F tank/data")
    server.succeed("zfs set mountpoint=/srv/data tank/data && zfs mount -a")

    after = server.succeed("cd /srv/data && find . -type f -print0 | sort -z | xargs -0 sha256sum")
    assert after == manifest, "restored files differ from the pre-disaster manifest"
    server.succeed("git -C /srv/data/repo fsck --full")
    print(f"RECOVERY-DRILL: {files} files restored, all checksums match, git fsck ok, "
          "send-only user cannot destroy, server cannot reach backup")
  '';
}
