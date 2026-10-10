# GPU wedge sentinel — detects an unrecoverable amdgpu/KFD compute hang.
#
# Failure this exists for (first seen 2026-08-16, workstation-nixos): a ComfyUI worker
# died mid-workflow inside the ROCm/KFD driver. Its main thread became a zombie but a
# second thread stuck in D state (uninterruptible sleep in the driver), so the process
# could never be reaped. Consequences, in order:
#
#   1. KFD kept attributing the dead process's VRAM allocation to it — 15.8 of 15.9 GiB
#      pinned by a process that no longer existed.
#   2. `kworker/*+kfd_restore_wq` spun in D state forever retrying queue evict/restore.
#   3. `podman rm -f` could not remove the container ("given PID did not die within
#      timeout"), so podman-comfyui-render restart-looped every 30s.
#   4. With ~0 free VRAM the compositor and any running game had nothing to allocate:
#      the desktop appeared completely frozen while the machine itself was healthy
#      (load 3.3, PSI ~0, SSH instant).
#   5. `systemctl reboot` then HUNG at "generating shutdown ramfs" — the kernel cannot
#      quiesce a task wedged in the driver. Recovery needed SysRq (Alt+SysRq+S, then B)
#      or the power button.
#
# This sentinel cannot FIX any of that — nothing in userspace can clear a D-state task,
# and SIGKILL is already spent by the time we see it. Its whole job is to convert a
# baffling "my machine froze, is the hardware dying?" into a push notification that
# names the cause and the remedy, so the recovery is a forced reboot done knowingly
# rather than a blind power-cycle.
#
# Detection is deliberately conservative — a kfd kworker in D for a moment is NORMAL
# under load. We alert only when BOTH signals hold across two samples 60s apart:
#   * a kfd kworker is in D state, AND
#   * the discrete GPU's VRAM is >95% used.
# A healthy busy render trips at most one of these, and never both for a full minute.
#
# Alerts to the lab ntfy hub on the server. Per postmortem action item #3 that means it
# cannot report a workstation wedge while the server is down — accepted here, since the
# symptom (frozen desktop) is already impossible to miss locally; the alert adds the
# diagnosis, not the discovery.

{ pkgs, net, ... }:

let
  sentinel = pkgs.writeShellScriptBin "gpu-wedge-sentinel" ''
    export PATH=/run/current-system/sw/bin:$PATH
    set -u

    NTFY_URL="''${NTFY_URL:-http://${net.wireguard.meshIPs.server-nixos}:2586/lab-alerts}"

    # Locate the discrete GPU by picking the DRM card with the most VRAM. Deliberately
    # not hardcoded to card1: the card numbering is not stable across kernels, and this
    # host also has a Granite Ridge iGPU whose tiny carveout never wins this comparison.
    card=""
    best=0
    for f in /sys/class/drm/card*/device/mem_info_vram_total; do
      [ -r "$f" ] || continue
      total=$(cat "$f" 2>/dev/null) || continue
      case "$total" in (*[!0-9]*|"") continue ;; esac
      if [ "$total" -gt "$best" ]; then
        best=$total
        card=$(dirname "$f")
      fi
    done
    [ -n "$card" ] || exit 0   # no discrete GPU on this host — nothing to watch

    # A kfd kworker parked in D state. Transient under load; only meaningful if it
    # persists AND VRAM is exhausted, which is why the caller samples twice.
    kfd_stuck() {
      ps -eo stat=,comm= | awk '$2 ~ /kfd/ && $1 ~ /^D/ { found = 1 } END { exit !found }'
    }

    vram_pct() {
      used=$(cat "$card/mem_info_vram_used" 2>/dev/null) || return 1
      total=$(cat "$card/mem_info_vram_total" 2>/dev/null) || return 1
      [ "$total" -gt 0 ] || return 1
      echo $(( used * 100 / total ))
    }

    wedged() {
      kfd_stuck || return 1
      pct=$(vram_pct) || return 1
      [ "$pct" -gt 95 ]
    }

    wedged || exit 0
    sleep 60
    wedged || exit 0

    pct=$(vram_pct)
    used_gib=$(( $(cat "$card/mem_info_vram_used") / 1073741824 ))
    total_gib=$(( $(cat "$card/mem_info_vram_total") / 1073741824 ))
    worker=$(ps -eo stat=,comm= | awk '$2 ~ /kfd/ && $1 ~ /^D/ { print $2; exit }')

    # Name the leaked context if it is still listed, so the alert points at a culprit
    # rather than just a symptom. Best-effort: rocm-smi may be absent or itself blocked.
    holder=$(timeout 10 rocm-smi --showpids 2>/dev/null \
      | awk '$1 ~ /^[0-9]+$/ { printf "%s(%s) ", $2, $1 }')
    [ -n "$holder" ] || holder="(rocm-smi unavailable or blocked)"

    body=$(printf '%s\n' \
      "GPU compute context is wedged in the amdgpu/KFD driver on $(hostname)." \
      "" \
      "  VRAM:      ''${used_gib}/''${total_gib} GiB (''${pct}%) pinned" \
      "  D-state:   $worker" \
      "  KFD procs: $holder" \
      "" \
      "The machine is NOT hung — only the GPU is. SSH still works; check with:" \
      "  ssh $(hostname) 'rocm-smi; ps -eo pid,stat,comm | grep kfd'" \
      "" \
      "Nothing in userspace can clear this: the holding task is in uninterruptible" \
      "sleep and SIGKILL has no effect. Expect 'systemctl reboot' to hang at" \
      "'generating shutdown ramfs' — recover with SysRq: Alt+SysRq+S, wait, then B.")

    exec curl -fsS --max-time 15 \
      -H "Title: GPU wedged on $(hostname) — forced reboot needed" \
      -H "Priority: urgent" \
      -H "Tags: warning,skull" \
      -d "$body" \
      "$NTFY_URL"
  '';
in
{
  environment.systemPackages = [ sentinel ];   # also runnable on demand

  systemd.services.gpu-wedge-sentinel = {
    description = "Detect an unrecoverable amdgpu/KFD compute wedge";
    # Deliberately NO network-online ordering at all — not `wants` (that pulled the
    # target into the boot transaction and caused the ath12k WiFi grab race: commit
    # 183f279, postmortem-2026-08-wcn7850-wifi.md), and not even `after`, which only
    # earns a NixOS lint warning here without buying anything. The timer's first run is
    # 5 min after boot, by which point the network is long up; if it somehow is not, the
    # cost is one skipped check on a 5-minute cycle.
    #
    # Same reasoning for no Persistent=true on the timer: replaying a missed wedge check
    # after a reboot is pointless, since the reboot is what clears the condition.
    serviceConfig = {
      Type = "oneshot";
      User = "oat";
      # Comfortably over the 60s internal re-sample; bounded so a blocked rocm-smi
      # cannot leave the unit running into the next trigger.
      TimeoutStartSec = "180";
      ExecStart = "${sentinel}/bin/gpu-wedge-sentinel";
    };
  };

  systemd.timers.gpu-wedge-sentinel = {
    description = "Periodic amdgpu/KFD wedge check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };
}
