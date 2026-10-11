# The removable media disk (hosts/common/optional/storage/media-disk.nix) in one VM.
#
# Run:  nix build .#checks.x86_64-linux.media-disk -L      (needs KVM)
#
# The production disk is unlocked by TPM2 or a typed passphrase; the VM has neither, so
# the test uses a keyfile for the boots that should unlock, and the real `none` key field
# (prompt) for the switch that must not hang. Proves:
#   absent disk  -> boot reaches `running`, nothing failed, nothing imported
#   present disk -> unlocked and imported at boot, data readable
#   closing the container exports the pool first; reopening it by hand imports again
#   deploying the module with no usable key does not block the switch on the prompt
{ pkgs }:

let
  uuid = "11111111-2222-4333-8444-555555555555";
in
pkgs.testers.runNixOSTest {
  name = "media-disk";

  nodes.server = { lib, pkgs, ... }: {
    imports = [ ../hosts/common/optional/storage/media-disk.nix ];
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    networking.hostId = "5e4e0021";
    environment.systemPackages = [ pkgs.cryptsetup ];   # the test formats the disk
    virtualisation.emptyDiskImages = [ 1024 ];          # /dev/vdb, blank on first boot
    lab.mediaDisk = {
      enable = true;
      inherit uuid;
      keyFile = "/root/media.key";
      tpm2 = false;
      # Long on purpose: boot must NOT wait this out (that is what nofail buys).
      deviceTimeout = "60s";
      snapshot."media/library" = [ "frequent" "hourly" "daily" ];
    };
    # As on the server: /srv/media is exported whether or not the disk is there.
    services.nfs.server = {
      enable = true;
      exports = "/srv/media 127.0.0.1(rw,sync,no_subtree_check,no_root_squash)\n";
    };
    specialisation.off.configuration.lab.mediaDisk.enable = lib.mkForce false;
    specialisation.prompt.configuration.lab.mediaDisk = {
      keyFile = lib.mkForce "none";
      timeout = lib.mkForce "20s";
    };
  };

  testScript = ''
    import time
    checks = 0
    def ok(msg):
        global checks
        checks += 1
        print(f"PASS  {msg}")
    def sysstate():
        return server.succeed("systemctl is-system-running --wait || true").strip()
    def imported():
        return server.succeed("zpool list -H media >/dev/null 2>&1 && echo yes || echo no").strip() == "yes"

    # Boot 1: the UUID exists on no disk (vdb is blank). Boot must not wait on it.
    server.wait_for_unit("multi-user.target")
    mu = int(server.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value multi-user.target")) / 1e6
    assert mu < 40, f"multi-user.target took {mu:.0f}s: boot waited on the absent disk"
    st = sysstate()
    failed = server.succeed("systemctl --failed --no-legend --plain")
    assert st == "running" and failed.strip() == "", (st, failed)
    assert not imported()
    assert server.succeed("systemctl is-active nfs-server.service").strip() == "active"
    ok(f"absent disk: multi-user at {mu:.0f}s (device timeout 60s), then running, 0 failed, nfs-server up, nothing imported")

    # Make the disk: LUKS (fixed UUID, keyfile) + pool media + media/library at /srv/media.
    server.succeed(
        "head -c 64 /dev/urandom > /root/media.key && chmod 600 /root/media.key",
        "cryptsetup luksFormat --batch-mode --uuid ${uuid} --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/vdb /root/media.key",
        "cryptsetup open --key-file /root/media.key /dev/vdb media",
        "zpool create -O mountpoint=none media /dev/mapper/media",
        "zfs create -o mountpoint=/srv/media media/library",
        "echo canary-7c1 > /srv/media/canary",
        "zpool export media && cryptsetup close media",
    )

    # Boot 2: present -> unlocked by crypttab, imported by lab-media-import, mounted.
    server.shutdown(); server.start()
    server.wait_for_unit("lab-media-import.service")
    assert server.succeed("cat /srv/media/canary").strip() == "canary-7c1"
    st = sysstate()
    assert st == "running", st
    props = server.succeed("zfs get -H -o property,value all media/library | grep auto-snapshot | sort")
    for want in ["com.sun:auto-snapshot\ttrue", ":daily\ttrue", ":hourly\ttrue", ":frequent\ttrue", ":weekly\tfalse", ":monthly\tfalse"]:
        assert want in props, (want, props)
    server.succeed("mkdir -p /mnt/nfs && mount -t nfs 127.0.0.1:/srv/media /mnt/nfs")
    assert server.succeed("cat /mnt/nfs/canary").strip() == "canary-7c1", "NFS shows the empty directory, not the pool"
    server.succeed("umount /mnt/nfs")
    ok("present disk: unlocked and imported at boot, snapshot tiers set, data readable over NFS")

    # Closing the container exports the pool first (bindsTo + reverse ordering).
    server.succeed("systemctl stop systemd-cryptsetup@media.service")
    assert not imported()
    server.fail("test -e /dev/mapper/media")
    assert server.succeed("systemctl show -p ActiveState --value lab-media-import.service").strip() == "inactive"
    journal = server.succeed("journalctl --no-pager -o cat -b")
    assert "Failed to deactivate" not in journal, "close failed with the pool still imported"
    ok("close: NFS export withdrawn, pool exported, container closed, import unit stopped")

    # Reopen by hand -> imported again (the documented manual-unlock path).
    server.succeed("systemctl start systemd-cryptsetup@media.service")
    server.wait_for_unit("lab-media-import.service")
    assert server.succeed("cat /srv/media/canary").strip() == "canary-7c1"
    server.succeed("mount -t nfs 127.0.0.1:/srv/media /mnt/nfs")
    assert server.succeed("cat /mnt/nfs/canary").strip() == "canary-7c1", "NFS export not re-published"
    server.succeed("umount /mnt/nfs")
    ok("reopen by hand: imports again and NFS serves it again")

    # Deploy with no usable key (production before TPM enrolment): from a config without
    # the module to one with `none`. The switch must not wait on the 20s prompt. (Measured:
    # switch-to-configuration never starts the generated unlock unit; boot or a hand start does.)
    off = server.succeed("readlink -f /run/current-system/specialisation/off").strip()
    prompt = server.succeed("readlink -f /run/current-system/specialisation/prompt").strip()
    server.succeed(f"{off}/bin/switch-to-configuration test")
    server.execute("zpool export media; cryptsetup close media")   # either may already be done
    assert not imported()
    t0 = time.monotonic()
    server.succeed(f"{prompt}/bin/switch-to-configuration test")
    took = time.monotonic() - t0
    assert took < 15, f"switch took {took:.0f}s: it waited on the passphrase prompt"
    time.sleep(25)                                       # past the prompt timeout
    jobs = server.succeed("systemctl list-jobs --no-legend").strip()
    assert jobs == "", jobs
    assert not imported()
    ok(f"keyless deploy: switch does not attempt the unlock ({took:.0f}s), no job waiting, nothing imported")

    print(f"MEDIA-DISK: {checks}/5 checks passed")
    assert checks == 5, checks
  '';
}
