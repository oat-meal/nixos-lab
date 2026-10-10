# Security policy, proven in VMs against the REAL modules (not stand-ins):
#   networking/wireguard.nix (+ mesh-zones.nix), networking/ssh.nix, security/sudo.nix,
#   security/lab-monitor.nix, core/users.nix
#
# Run:  nix build .#checks.x86_64-linux.security-policy -L      (needs KVM)
#
# Four VMs on one LAN: workstation, server and laptop form a real WireGuard mesh from the
# modules; `stranger` sits on the same LAN outside it. Keys are test-only fixtures
# (tests/fixtures/README.md). The `net` passed in mirrors hosts/network.nix's shape with
# test addresses. Each negative assertion is paired with a positive control so a failure
# is attributable — a refused login must be "permission denied", not a timeout.
{ pkgs }:

let
  lib = pkgs.lib;
  fx = ./fixtures;
  read = f: lib.removeSuffix "\n" (builtins.readFile (fx + "/${f}"));
  hosts = [ "workstation-nixos" "server-nixos" "laptop-nixos" ];

  # Test-driver LAN addresses are assigned in sorted node-name order:
  # laptop-nixos .1, server-nixos .2, stranger .3, workstation-nixos .4 (asserted below).
  net = {
    user = "oat";
    lanSubnet = "192.168.1.0/24";
    lanIPs = { laptop-nixos = "192.168.1.1"; server-nixos = "192.168.1.2"; workstation-nixos = "192.168.1.4"; };
    wireguard = {
      port = 51821;
      meshSubnet = "10.100.0.0/24";
      meshIPs = { workstation-nixos = "10.100.0.1"; server-nixos = "10.100.0.2"; laptop-nixos = "10.100.0.3"; };
      publicKeys = lib.genAttrs hosts (h: read "wg-${h}.pub");
    };
    syncthing = { };
    sshKeys = lib.genAttrs hosts (h: read "oat-${h}.pub");
    monitorKey = read "lab_monitor.pub";
  };

  # wireguard.nix asks `config.sops.secrets ? ...`; without sops it reads
  # /etc/wireguard/private.key. This stub only declares the option it inspects.
  sopsStub = { lib, ... }: {
    options.sops.secrets = lib.mkOption { type = lib.types.attrs; default = { }; };
  };

  meshNode = host: extra: { ... }: {
    imports = [
      sopsStub
      ../hosts/common/core/users.nix
      ../hosts/common/optional/networking/wireguard.nix
      ../hosts/common/optional/networking/ssh.nix
      ../hosts/common/optional/security/sudo.nix
      extra
    ];
    networking.hostName = host;
    environment.etc."wireguard/private.key" = { source = fx + "/wg-${host}.key"; mode = "0400"; };
  };
in
pkgs.testers.runNixOSTest {
  name = "security-policy";
  node.specialArgs = { inherit net; };

  nodes = {
    workstation-nixos = meshNode "workstation-nixos" {
      imports = [ ../hosts/common/optional/security/lab-monitor.nix ];
      lab.restartableUnits = [ "sshd.service" ];
    };
    laptop-nixos = meshNode "laptop-nixos" {
      imports = [ ../hosts/common/optional/security/lab-monitor.nix ];
    };
    server-nixos = meshNode "server-nixos" {
      lab.sudoCache = { type = "tty"; minutes = 15; };   # as hosts/server/default.nix
      # Trust zone: the laptop may open ssh only. A wg0 service on 8099 is the probe.
      lab.meshZones.laptop-nixos = { tcp = [ 22 ]; };
      networking.firewall.interfaces."wg0".allowedTCPPorts = [ 8099 ];
      systemd.services.zone-probe = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 10.100.0.2";
      };
    };
    stranger = { ... }: { };
  };

  testScript = ''
    W, S, L, X = workstation_nixos, server_nixos, laptop_nixos, stranger
    O = "-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
    checks = 0
    def ok(msg):
        global checks
        checks += 1
        print(f"PASS  {msg}")

    start_all()
    for m in (W, S, L, X):
        m.wait_for_unit("multi-user.target")

    # Sanity: the test LAN matches the addresses the fake net assumes.
    for m, ip in ((L, "192.168.1.1"), (S, "192.168.1.2"), (X, "192.168.1.3"), (W, "192.168.1.4")):
        m.succeed(f"ip -4 -br addr show eth1 | grep -q '{ip}/'")
    ok("LAN addresses as assumed")

    # The mesh comes up from the real wireguard.nix.
    for m in (W, S, L):
        m.wait_for_unit("wireguard-wg0.service")
    W.wait_until_succeeds("ping -c1 -W1 10.100.0.2", timeout=90)
    W.wait_until_succeeds("ping -c1 -W1 10.100.0.3", timeout=90)
    ok("WireGuard mesh up: workstation reaches server and laptop")

    # Keys into place (test fixtures): each host's oat key; the monitor key on the server
    # (its real home) AND on the laptop (to prove from= refuses it there).
    for m, h in ((W, "workstation-nixos"), (S, "server-nixos"), (L, "laptop-nixos")):
        m.succeed(f"install -d -o oat -m700 /home/oat/.ssh && install -o oat -m600 ${fx}/oat-{h} /home/oat/.ssh/id_ed25519")
    for m in (S, L):
        m.succeed("install -o oat -m600 ${fx}/lab_monitor /home/oat/.ssh/lab_monitor")

    # sshd listens on the mesh address only.
    W.wait_for_unit("sshd.service")
    listen = W.succeed("ss -tlnH '( sport = :22 )' | awk '{print $4}'").split()
    assert listen == ["10.100.0.1:22"], f"sshd listens on {listen}"
    ok("sshd bound to 10.100.0.1:22 only")

    # A LAN stranger cannot reach sshd. Control: it can reach the host at all.
    X.succeed("ping -c1 -W2 192.168.1.4")
    X.fail("timeout 5 bash -c '</dev/tcp/192.168.1.4/22'")
    ok("LAN stranger: host reachable, port 22 not")

    # oat's authorized keys: the laptop's key works (control), the server's is refused.
    L.succeed(f"su - oat -c 'ssh {O} oat@10.100.0.1 true'")
    out = S.fail(f"su - oat -c 'ssh {O} oat@10.100.0.1 true' 2>&1")
    assert "permission denied" in out.lower(), out
    ok("oat@workstation: laptop key accepted, server key refused (permission denied)")

    # lab-monitor: works from the server, no wheel, journal readable, no sudo.
    r = S.succeed(f"su - oat -c 'ssh {O} -i ~/.ssh/lab_monitor lab-monitor@10.100.0.1 \"id -un; id -nG; journalctl -n1 -q --no-pager >/dev/null && echo journal-ok; sudo -n true 2>/dev/null && echo SUDO-ALLOWED || echo sudo-refused\"'")
    assert "lab-monitor" in r and "wheel" not in r, r
    assert "journal-ok" in r and "sudo-refused" in r and "SUDO-ALLOWED" not in r, r
    ok("lab-monitor from server: logs in, not wheel, reads journal, sudo refused")

    # from= restriction: the SAME key from the laptop's mesh address is refused.
    out = L.fail(f"su - oat -c 'ssh {O} -i ~/.ssh/lab_monitor lab-monitor@10.100.0.1 true' 2>&1")
    assert "permission denied" in out.lower(), out
    ok("lab-monitor key from laptop (not 10.100.0.2): permission denied")

    # sudo policy (workstation): exactly the three lab-* wrappers are passwordless.
    listing = W.succeed("su - oat -c 'sudo -n -l' 2>&1")
    nopw = [p.strip() for line in listing.splitlines() if "NOPASSWD:" in line
            for p in line.split("NOPASSWD:", 1)[1].split(",")]
    assert sorted(n.rsplit("/", 1)[-1] for n in nopw) == ["lab-fw-dump", "lab-listeners", "lab-podman-probe"], nopw
    W.fail("su - oat -c 'sudo -n true'")
    W.succeed("su - oat -c 'sudo -n lab-listeners' | grep -q ':22'")
    ok("sudo: only 3 lab-* wrappers passwordless; lab-listeners runs; anything else needs the password")

    # polkit: a listed unit restarts without sudo; an unlisted one is refused.
    W.succeed("su - oat -c 'systemctl --no-ask-password restart sshd.service'")
    out = W.fail("su - oat -c 'systemctl --no-ask-password start systemd-tmpfiles-clean.service' 2>&1")
    assert "access denied" in out.lower() or "authentication required" in out.lower(), out
    ok("polkit: listed unit restarted by oat; unlisted unit refused")

    # Per-host sudo cache (lab.sudoCache): workstation default, server per-tty 15 min.
    W.succeed("grep -q 'timestamp_type=global' /etc/sudoers && grep -q 'timestamp_timeout=60' /etc/sudoers")
    S.succeed("grep -q 'timestamp_type=tty' /etc/sudoers && grep -q 'timestamp_timeout=15' /etc/sudoers")
    ok("sudo cache: workstation global/60, server tty/15")

    # Mesh trust zone on the server. Control first: the workstation (no zone) opens 8099.
    tcp = lambda ip, port: f"timeout 5 bash -c '</dev/tcp/{ip}/{port}'"
    S.wait_for_open_port(8099, "10.100.0.2")
    W.succeed(tcp("10.100.0.2", 8099))
    L.fail(tcp("10.100.0.2", 8099))
    S.wait_until_succeeds("journalctl -k --no-pager | grep -q 'lab-zone laptop-nixos refused'", timeout=10)
    ok("zone: workstation opens server:8099; laptop refused (logged)")

    # What the zone must NOT break: its allowlisted port, ping, and the server's own
    # connections to the laptop (replies are not NEW). And a firewall reload keeps it.
    L.succeed(tcp("10.100.0.2", 22))
    L.succeed("ping -c1 -W2 10.100.0.2")
    S.succeed(tcp("10.100.0.3", 22))
    S.succeed("systemctl reload firewall")
    L.fail(tcp("10.100.0.2", 8099))
    assert S.succeed("iptables -S nixos-fw | grep -c lab-zone-laptop-nixos").strip() == "1"
    ok("zone: laptop ssh + ping ok; server -> laptop unaffected; survives reload (1 jump rule)")

    print(f"SECURITY-POLICY: {checks}/12 checks passed")
    assert checks == 12, checks
  '';
}
