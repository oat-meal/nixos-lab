# The backup MODULE (hosts/common/optional/storage/backup.nix), end to end in two VMs.
#
# Run:  nix build .#checks.x86_64-linux.backup -L      (needs KVM)
#
# `source` is a lab.backup.source host; `archive` is a lab.backup.target host that pulls
# from it over ssh AND backs up one of its own datasets locally. Proves, with the real
# services (sanoid.service, syncoid-*.service, lab-backup-*):
#   snapshots taken by sanoid with the declared tiers; remote and local pulls land under
#   the parent; --use-hold holds on both sides; archive pruning drops hourlies and keeps
#   dailies; parent is readonly + unmounted + quota'd; zfs-send can send but not destroy;
#   its key is refused from any address but the archive's; the source holds no
#   credential for the archive; and a destroyed source pool restores byte-for-byte.
# Every negative is paired with a positive control.
{ pkgs }:

let
  lib = pkgs.lib;
  fx = ./fixtures;
  read = f: lib.removeSuffix "\n" (builtins.readFile (fx + "/${f}"));
  # Test-driver LAN addresses, sorted node-name order: archive .1, source .2.
  archiveIP = "192.168.1.1";
  sourceIP = "192.168.1.2";

  zfsNode = hostId: extra: { pkgs, ... }: {
    imports = [ ../hosts/common/optional/storage/backup.nix extra ];
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    networking.hostId = hostId;
    virtualisation.emptyDiskImages = [ 1024 ];          # /dev/vdb
    services.openssh.enable = true;
    services.openssh.settings.PermitRootLogin = "prohibit-password";
    environment.systemPackages = with pkgs; [ git sanoid ];
  };
in
pkgs.testers.runNixOSTest {
  name = "backup";

  nodes = {
    source = zfsNode "5e4e0011" {
      lab.backup.source = {
        enable = true;
        datasets = [ "tank/data" ];
        targetAddress = archiveIP;
        targetKey = read "backup_target.pub";
      };
      services.sanoid.extraArgs = [ "--verbose" ];   # test-only: decisions in the journal
      # Pinned host key, so the archive's strict known_hosts check is what gets tested.
      services.openssh.hostKeys = [ { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; } ];
      environment.etc."ssh/ssh_host_ed25519_key" = { source = fx + "/source_host"; mode = "0600"; };
      environment.etc."ssh/ssh_host_ed25519_key.pub" = { source = fx + "/source_host.pub"; mode = "0644"; };
      # Operator restore path for the drill only: the archive's root may write back.
      users.users.root.openssh.authorizedKeys.keys = [ (read "restore_root.pub") ];
    };
    archive = zfsNode "5e4e0012" {
      lab.backup.target = {
        enable = true;
        parent = "vault/backups";
        quota = "800M";
        pulls = {
          src = { host = sourceIP; dataset = "tank/data"; hostKey = read "source_host.pub"; };
          self = { host = null; dataset = "vault/local"; };     # local pull, no ssh
        };
      };
    };
  };

  testScript = ''
    S, A = source, archive
    checks = 0
    def ok(msg):
        global checks
        checks += 1
        print(f"PASS  {msg}")
    def run(m, unit):
        # sanoid.service is not Type=oneshot: `systemctl start` returns while it still runs.
        # Start, wait until the unit has EXITED, then require Result=success.
        m.succeed(f"systemctl start {unit}")
        m.wait_until_fails(f"systemctl is-active --quiet {unit}", timeout=120)
        res = m.succeed(f"systemctl show -p Result --value {unit}").strip()
        if res != "success":
            print(m.succeed(f"journalctl -u {unit} --no-pager -o cat | tail -30"))
        assert res == "success", f"{unit} ended with Result={res}"
    def snaps(m, ds):
        return m.succeed(f"zfs list -H -t snapshot -o name -s creation {ds} 2>/dev/null || true").split()

    start_all()
    S.wait_for_unit("multi-user.target"); A.wait_for_unit("multi-user.target")

    # Pools exist before the module's oneshots matter (on real hosts they exist at boot).
    S.succeed("zpool create -O mountpoint=none tank /dev/vdb && zfs create -o mountpoint=/srv/data tank/data")
    A.succeed("zpool create -O mountpoint=none vault /dev/vdb && zfs create -o mountpoint=/srv/local vault/local")
    S.succeed("systemctl restart lab-backup-source.service")
    A.succeed("systemctl restart lab-backup-target.service")

    # Keys: the archive's syncoid key (pull) and root key (restore drill only).
    A.succeed("install -d -o syncoid -m700 /var/lib/syncoid && install -o syncoid -m600 ${fx}/backup_target /var/lib/syncoid/id_ed25519")
    A.succeed("install -d -m700 /root/.ssh && install -m600 ${fx}/restore_root /root/.ssh/id_ed25519")

    # Source: delegation + opt-out applied from config.
    perms = S.succeed("zfs allow tank/data")
    assert "zfs-send" in perms and "send" in perms and "hold" in perms and "release" in perms, perms
    assert "destroy" not in perms, perms
    assert S.succeed("zfs get -H -o value com.sun:auto-snapshot tank/data").strip() == "false"
    ok("source: zfs-send has send,hold,release (no destroy); auto-snapshot opted out")

    # Archive parent: readonly, unmounted, quota.
    props = A.succeed("zfs get -H -o value readonly,mountpoint,canmount,quota vault/backups").split()
    assert props == ["on", "none", "off", "800M"], props
    ok("archive parent: readonly, unmounted, quota 800M")

    # Data, a git repo, and a checksum manifest.
    S.succeed(
        "cd /srv/data && head -c 8M /dev/urandom > blob && git init -q repo && echo hi > repo/f && "
        "git -C repo -c user.name=t -c user.email=t@t add f && git -C repo -c user.name=t -c user.email=t@t commit -qm init"
    )
    A.succeed("head -c 2M /dev/urandom > /srv/local/note")
    manifest = S.succeed("cd /srv/data && find . -type f -print0 | sort -z | xargs -0 sha256sum")
    files = len(manifest.strip().splitlines())
    assert files > 5, files

    # sanoid takes the declared tiers on the source (and on the archive's local dataset? no —
    # that one is a pull SOURCE only via syncoid; give it a snapshot to replicate).
    # Older sanoid-named hourlies, so the archive's pruning has real work (a pass over one
    # held snapshot would prove nothing). sanoid reads the timestamp from the name.
    for h in ("01", "02", "03"):
        S.succeed(f"zfs snapshot tank/data@autosnap_2026-10-09_{h}:00:00_hourly")
    run(S, "sanoid.service")
    s_snaps = snaps(S, "tank/data")
    kinds = {k for k in ("hourly", "daily", "monthly") if any(f"_{k}" in n for n in s_snaps)}
    if kinds != {"hourly", "daily", "monthly"}:
        # Diagnostic kept on purpose: an empty list says nothing about WHY.
        print(S.succeed("journalctl -u sanoid.service --no-pager -o cat | tail -25"))
        print(S.succeed("zfs allow tank/data; zfs list -t all -o name,creation"))
        print(S.succeed("d=$(systemctl cat sanoid.service | grep -oE -- '--configdir [^ ]+' | cut -d' ' -f2); "
                        "ls -la /var/cache/sanoid 2>&1; sanoid --configdir $d --cron --verbose --readonly 2>&1 | tail -20"))
    assert kinds == {"hourly", "daily", "monthly"}, s_snaps
    A.succeed("zfs snapshot vault/local@autosnap_2026-01-01_00:00:00_daily")
    ok(f"sanoid on source: hourly, daily, monthly snapshots ({len(s_snaps)})")

    # Pull: both syncoid jobs run as the real services.
    run(A, "syncoid-src.service")
    run(A, "syncoid-self.service")
    got = snaps(A, "vault/backups/src")
    assert any("_daily" in n for n in got) and any("_monthly" in n for n in got), got
    assert snaps(A, "vault/backups/self"), "local pull landed nothing"
    ok(f"pulls: remote -> vault/backups/src ({len(got)} snapshots), local -> vault/backups/self")

    # --use-hold: newest replicated snapshot held on source and archive.
    assert "syncoid" in S.succeed(f"zfs holds {s_snaps[-1]}"), "no hold on source"
    assert "syncoid" in A.succeed(f"zfs holds {got[-1]}"), "no hold on archive"
    ok("--use-hold: newest replicated snapshot held on both sides")

    # Archive pruning (hourly=0): hourlies go, dailies stay. The held newest may survive.
    run(A, "sanoid.service")
    after = snaps(A, "vault/backups/src")
    hourly_before = sum("_hourly" in n for n in got)
    hourly_left = [n for n in after if "_hourly" in n]
    assert hourly_before >= 3, f"pruning test needs real work, got {hourly_before} hourlies: {got}"
    assert len(hourly_left) <= 1 and any("_daily" in n for n in after), after
    ok(f"archive pruning: hourly {hourly_before} -> {len(hourly_left)} (held newest may stay), dailies kept")

    # Least privilege. Control: zfs-send CAN send.
    S.succeed(f"su -s /bin/sh zfs-send -c 'zfs send -nv {s_snaps[0]}'")
    out = S.fail(f"su -s /bin/sh zfs-send -c 'zfs destroy {s_snaps[0]}' 2>&1")
    assert "permission denied" in out.lower(), out
    ok("zfs-send: send works, destroy -> permission denied")

    # from=: the archive's key, used from the source's own address, is refused.
    S.succeed("install -m600 ${fx}/backup_target /root/stolen_key")
    out = S.fail("ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /root/stolen_key zfs-send@127.0.0.1 true 2>&1")
    assert "permission denied" in out.lower(), out
    ok("archive key from any address but the archive: permission denied")

    # The source holds no credential for the archive. Control: sshd there answers.
    S.succeed("timeout 5 bash -c '</dev/tcp/${archiveIP}/22'")
    out = S.fail("ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${archiveIP} true 2>&1")
    assert "permission denied" in out.lower(), out
    ok("source -> archive: sshd reachable, no credential (permission denied)")

    # Disaster and restore (operator path), then verify byte-for-byte.
    S.succeed("zpool destroy tank && wipefs -a /dev/vdb && zpool create -O mountpoint=none tank /dev/vdb")
    newest = snaps(A, "vault/backups/src")[-1]
    A.succeed(f"zfs send -R {newest} | ssh -o StrictHostKeyChecking=no root@${sourceIP} zfs receive -F tank/data")
    S.succeed("zfs set mountpoint=/srv/data tank/data && zfs set readonly=off tank/data && zfs mount -a")
    restored = S.succeed("cd /srv/data && find . -type f -print0 | sort -z | xargs -0 sha256sum")
    assert restored == manifest, "restored files differ from the pre-disaster manifest"
    S.succeed("git -C /srv/data/repo fsck --full")
    ok(f"restore: {files} files byte-identical, git fsck ok")

    print(f"BACKUP-MODULE: {checks}/10 checks passed")
    assert checks == 10, checks
  '';
}
