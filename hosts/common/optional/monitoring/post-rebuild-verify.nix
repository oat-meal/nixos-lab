# Post-rebuild / post-boot health verifier (read-only).
#
# After each activation (nixos-rebuild switch, or boot), schedule a transient
# check ~90s later that looks for failed systemd units and, if any, pushes an
# alert to the lab ntfy hub. Catches regressions from ANY rebuild regardless of
# how it was triggered — e.g. the case where a container silently failed to start
# after a switch. `systemctl --failed` lists only genuinely-failed units, so
# slow-starting services (ComfyUI) that are still "activating" are not flagged.
#
# Imported by every host.

{ pkgs, net, ... }:

let
  ntfy = "http://${net.wireguard.meshIPs.server-nixos}:2586/lab-alerts";
  check = pkgs.writeShellScript "post-rebuild-health-check" ''
    export PATH=/run/current-system/sw/bin:$PATH
    failed=$(systemctl --failed --no-legend --no-pager --plain | awk '{print $1}' | tr '\n' ' ')
    if [ -n "$failed" ]; then
      ${pkgs.curl}/bin/curl -s --max-time 5 \
        -H "Title: Post-rebuild regression on $(hostname)" \
        -H "Priority: high" -H "Tags: warning" \
        -d "Failed units ~90s after activation: $failed" "${ntfy}" >/dev/null 2>&1 || true
    fi
  '';
in
{
  # Runs during every activation; schedules the check as a transient timer so it
  # fires after services have had time to settle (auto-named unit → no conflict
  # if a prior check is still pending).
  system.activationScripts.postRebuildVerify = ''
    ${pkgs.systemd}/bin/systemd-run --quiet --on-active=90s \
      --description="Post-rebuild health check" ${check} 2>/dev/null || true
  '';
}
