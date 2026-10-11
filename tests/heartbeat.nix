# The off-host dead-man switch (hosts/common/optional/monitoring/heartbeat.nix), in two VMs.
#
# Run:  nix build .#checks.x86_64-linux.heartbeat -L      (needs KVM)
#
# `server` runs ntfy and the publisher; `watcher` runs the watch unit as the real user with
# an alert command that records each call. Walks ok -> missing -> ok -> unreachable and
# requires exactly one alert per transition, none while a state persists, and none for a
# single bad run (a bad state alerts only when two consecutive runs agree). The publisher
# and watcher run as their real sandboxed units, and must end Result=success.
{ pkgs }:

let
  net = import ../hosts/network.nix;
  # Test-driver LAN addresses, sorted node-name order: server .1, watcher .2.
  serverIP = "192.168.1.1";
  url = "http://${serverIP}:2586/lab-heartbeat";
  common = {
    imports = [ ../hosts/common/optional/monitoring/heartbeat.nix ];
    _module.args.net = net;
    lab.heartbeat.url = url;
  };
  record = pkgs.writeShellScript "record-alert" ''echo "$1" >> "$STATE_DIRECTORY/alerts"'';
in
pkgs.testers.runNixOSTest {
  name = "heartbeat";

  nodes = {
    server = {
      imports = [ common ];
      services.ntfy-sh = {
        enable = true;
        settings = {
          base-url = "http://${serverIP}:2586";
          listen-http = ":2586";
          cache-file = "/var/lib/ntfy-sh/cache.db";
          cache-duration = "24h";
        };
      };
      networking.firewall.allowedTCPPorts = [ 2586 ];
      lab.heartbeat.publish.enable = true;
    };
    watcher = {
      imports = [ common ];
      users.users.${net.user} = { isNormalUser = true; };
      lab.heartbeat.watch = {
        enable = true;
        maxAge = "1m";          # short so the test can age a heartbeat out
        alertCommand = "${record}";
      };
      # The test starts the watcher several times a second; the 5-minute timer never does.
      systemd.services.lab-heartbeat-watch.unitConfig.StartLimitIntervalSec = 0;
    };
  };

  testScript = ''
    import time
    S, W = server, watcher
    checks = 0
    def ok(msg):
        global checks
        checks += 1
        print(f"PASS  {msg}")
    def run(m, unit):
        m.succeed(f"systemctl start {unit}")
        res = m.succeed(f"systemctl show -p Result --value {unit}").strip()
        if res != "success":
            print(m.succeed(f"journalctl -u {unit} --no-pager -o cat | tail -20"))
        assert res == "success", f"{unit} ended with Result={res}"
    def state():
        return W.succeed("cat /var/lib/lab-heartbeat-watch/state 2>/dev/null || echo ok").strip()
    def alerts():
        return W.succeed("cat /var/lib/lab-heartbeat-watch/alerts 2>/dev/null || true").split()

    start_all()
    S.wait_for_unit("ntfy-sh.service"); S.wait_for_open_port(2586)
    W.wait_for_unit("multi-user.target")
    # The timers would publish/check on their own schedule; the test drives every run.
    S.succeed("systemctl stop lab-heartbeat.timer"); W.succeed("systemctl stop lab-heartbeat-watch.timer")

    # Publisher: sandboxed, DynamicUser, and the message is really in ntfy.
    run(S, "lab-heartbeat.service")
    body = W.succeed("curl -fsS '${url}/json?poll=1&since=5m'")
    assert '"event":"message"' in body and "server" in body, body
    ok("publisher: sandboxed unit succeeds; heartbeat readable from the watcher")

    # Watcher runs as the real user. Fresh heartbeat -> ok, no alert (first state is ok).
    run(W, "lab-heartbeat-watch.service")
    assert W.succeed("systemctl show -p User --value lab-heartbeat-watch.service").strip() == "${net.user}"
    assert alerts() == [], alerts()
    ok("watch: runs as ${net.user}; fresh heartbeat -> no alert")

    def last_log():
        inv = W.succeed("systemctl show -p InvocationID --value lab-heartbeat-watch.service").strip()
        return W.succeed(f"journalctl --no-pager -o cat _SYSTEMD_INVOCATION_ID={inv}")

    # Blip: one bad run, then good again -> no alert at all. The 2026-10-10 false alarm.
    time.sleep(70)
    run(W, "lab-heartbeat-watch.service")
    log = last_log()
    assert "unconfirmed" in log and "ntfy: http=200" in log, log
    assert state() == "ok" and alerts() == [], (state(), alerts())
    run(S, "lab-heartbeat.service")
    run(W, "lab-heartbeat-watch.service")
    assert state() == "ok" and alerts() == [], (state(), alerts())
    ok("blip: a single missing run is logged with ntfy's answer and does not alert")

    # Age the heartbeat out (maxAge 1m). Two runs agree on missing -> one alert.
    time.sleep(70)
    run(W, "lab-heartbeat-watch.service")
    assert alerts() == [], alerts()
    run(W, "lab-heartbeat-watch.service")
    assert state() == "missing" and alerts() == ["missing"], (state(), alerts())
    run(W, "lab-heartbeat-watch.service")
    assert alerts() == ["missing"], alerts()
    ok("missing: alerts once two runs agree, none while it persists")

    # Publisher back -> ok, recovery alert.
    run(S, "lab-heartbeat.service")
    run(W, "lab-heartbeat-watch.service")
    assert state() == "ok" and alerts() == ["missing", "ok"], (state(), alerts())
    ok("recovery: heartbeat again -> ok, one recovery alert")

    # Server's ntfy gone -> unreachable. Control: it answered a moment ago (above).
    S.succeed("systemctl stop ntfy-sh.service")
    run(W, "lab-heartbeat-watch.service")
    log = last_log()
    assert "ntfy: http=000 bytes=0" in log and alerts() == ["missing", "ok"], (log, alerts())
    run(W, "lab-heartbeat-watch.service")
    assert state() == "unreachable" and alerts() == ["missing", "ok", "unreachable"], (state(), alerts())
    ok("unreachable: ntfy down -> one alert after two runs, delivered without the server")

    print(f"HEARTBEAT: {checks}/6 checks passed")
    assert checks == 6, checks
  '';
}
