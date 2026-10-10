# Search relevance sentinel — asserts the lab's SearXNG actually searches.
#
# Runs ai-lab/sentinel/search-sentinel.py against 10.100.0.2:8888 twice a day.
# READ-ONLY: it issues search queries and inspects the answers, nothing else.
# Imported by hosts/server only (that is where SearXNG runs).
#
# ⚠️ WHY A LIVENESS CHECK WAS NOT ENOUGH, which is the entire reason this file
# exists. On 2026-08-31 SearXNG was up, answering in 0.8 s, HTTP 200, JSON API
# exactly as configured — and returning Social Security pages for a query about
# an African tree genus. The dashboard's `siteMonitor` on port 8888 was green
# throughout and would be green today against a service that had stopped
# searching entirely. See docs/searxng-engines-degraded.md.
#
# The check is RELEVANCE: ask for a rare binomial, require it to appear in the
# results. A `200 OK` over content nobody inspected is not a verdict.

{ pkgs, net, ... }:

let
  sentinel = pkgs.writeShellScriptBin "search-sentinel" ''
    export PATH=/run/current-system/sw/bin:$PATH
    exec ${pkgs.python3}/bin/python ${../../../../ai-lab/sentinel/search-sentinel.py} "$@"
  '';
in
{
  # Also available as a manual command: `search-sentinel`.
  # Negative-control it with `SEARCH_ENGINES=bing search-sentinel`, which must
  # exit 1 — a monitor that has never been seen to fail is not a monitor.
  environment.systemPackages = [ sentinel ];

  systemd.services.search-sentinel = {
    description = "SearXNG relevance sentinel (queries + asserts, read-only)";
    # `after` without `wants`, matching fleet-sentinel.nix: a timer-driven
    # monitor must never pull network-online.target into the boot transaction.
    # Doing so on the workstation raced the WCN7850 firmware init and wedged the
    # card — docs/audit/postmortem-2026-08-wcn7850-wifi.md.
    after = [ "network-online.target" "uwsgi.service" ];
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;          # needs no state, no keys, no filesystem
      TimeoutStartSec = "300";      # four engines x 45 s, with headroom
      Environment = [
        "SEARCH_URL=http://${net.wireguard.meshIPs.server-nixos}:8888/search"
        # Quorum, not unanimity. `wikipedia` returned 2 results on one run and 0
        # on the next, minutes apart, for the same query — its engine matches
        # near-exact article titles and it rate-limits. Requiring all four would
        # have flapped on night one, and a muted monitor looks like coverage
        # while providing none. An engine returning IRRELEVANT results still
        # fails the run on its own, at any quorum — see the script.
        "SEARCH_MIN_ENGINES=2"
        "NTFY_URL=http://${net.wireguard.meshIPs.server-nixos}:2586/lab-alerts"
      ];
      ExecStart = "${sentinel}/bin/search-sentinel";
    };
  };

  systemd.timers.search-sentinel = {
    description = "SearXNG relevance check, twice daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Twice a day rather than nightly: engine reputation and upstream DOM
      # changes are the failure mode, and both arrive without warning. Offset
      # from fleet-sentinel's 07:30 so the two do not report together.
      #
      # ⚠️ THE COMMA GOES INSIDE THE HOUR FIELD, NOT BETWEEN WHOLE TIMES. This
      # shipped as "*-*-* 08:15,20:15:00" and systemd rejected it outright:
      # `Failed to parse calendar specification` then `Timer unit lacks value
      # setting. Refusing.` The timer never armed — `list-timers` showed 0
      # timers for a unit that had been deployed and enabled.
      #
      # ⚠️ AND `systemctl is-enabled` SAID `enabled` THROUGHOUT, while `Loaded:`
      # read `bad-setting`. That is the third false green in this one change
      # set, after uwsgi reporting `active` while serving 500s and bing
      # returning 200s over filler. is-enabled reports the symlink, not whether
      # the unit parses.
      #
      # Validated with `systemd-analyze calendar` before committing this time,
      # which is the cheap check that would have caught it:
      #   *-*-* 08:15,20:15:00 -> Failed to parse: Invalid argument
      #   *-*-* 08,20:15:00    -> Next elapse: Tue 2026-09-01 08:15:00 MDT
      OnCalendar = "*-*-* 08,20:15:00";
      Persistent = true;
      RandomizedDelaySec = "10m";   # do not hammer the APIs on a fixed schedule
    };
  };
}
