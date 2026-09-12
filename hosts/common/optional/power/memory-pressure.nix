# Memory-pressure resilience — added 2026-09-11 after a Valheim leak (36.6 GiB
# resident + 4.4 GiB swapped, on a 60 GiB host) stalled the whole desktop for
# ~10 minutes. Browser, Steam and Discord were casualties, not causes.
#
# Two INDEPENDENT failures, both measured during the incident. Either one alone
# would have been survivable.
#
#   1. systemd-oomd was running and monitoring NOTHING.
#      Every slice read ManagedOOMSwap=auto, and `oomctl` reported empty
#      "Swap Monitored CGroups" and "Memory Pressure Monitored CGroups" lists.
#      It would never have killed anything at any pressure level, so tuning
#      thresholds would have accomplished nothing — cgroups must be ENROLLED.
#      ⚠️ `systemctl is-active systemd-oomd` said "active" throughout. That is
#      the supervisor reporting on itself; `oomctl` is the direct signal.
#
#   2. Core dumps turned a ~2-minute memory shortage into a ~10-minute stall.
#      ProcessSizeMax defaults to 32G on 64-bit, so crashing desktop apps were
#      dumped in full. To produce a dump the kernel faults the process's entire
#      address space back in from swap:
#          vfs_coredump -> elf_core_dump -> dump_user_range -> get_dump_page
#              -> handle_mm_fault -> do_swap_page -> __folio_lock_or_retry
#      Tasks blocked >122s on folio_wait_bit_common AFTER the leaking process
#      was already dead, at ~14 MB/s of sustained writeback. Compressed dumps on
#      disk are small (18.6 MB for steamwebhelper) and hide this entirely — the
#      cost is paid in fault-in, not in bytes stored.
#
# ⚠️ ProcessSizeMax makes systemd-coredump bail early; it does NOT stop the
# kernel generating the stream, so it truncates the cost rather than removing
# it. Storage=none + ProcessSizeMax=0 is the full-disable path, not taken here
# because dumps from ordinary-sized crashes are still worth keeping.
#
# NOT fixed here, because it does not live in nix: rpool/swap carried a
# snapshot (@pre-26.05-migration-20260821-1218, 5.76 GiB) which pinned its
# blocks and made every swap write copy-on-write instead of an in-place
# overwrite. Swap-device properties are set out of band:
#     zfs set primarycache=metadata secondarycache=none rpool/swap
#     zfs set com.sun:auto-snapshot=false rpool/swap
# The auto-snapshot opt-out matters because storage/zfs-maintenance.nix enables
# services.zfs.autoSnapshot repo-wide; it is inert only while no dataset
# carries com.sun:auto-snapshot=true.

{ ... }:

{
  # Enroll user slices so oomd can actually act on a runaway process before it
  # takes the desktop with it. Verify with `oomctl`, not `systemctl is-active`.
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;

    # ⚠️ Enrollment alone would NOT have caught the incident above, and this is
    # the whole reason the swap knobs below exist. enableUserSlices watches
    # MEMORY pressure (kill at 80%), but memory PSI peaked at 0.58 during the
    # stall while IO PSI sat at 94 — the kernel accounted almost all of it as
    # IO. Swap was the only default signal that tracked the actual failure, and
    # it reached 88.6%, just under the 90% stock limit. So: lower the swap limit
    # to 80% AND enroll user.slice for swap, which enableUserSlices does not do.
    settings.OOM.SwapUsedLimit = "80%";
  };

  # 80% of this host's 14 GiB of swap is already a pathological state; nothing
  # healthy here swaps that hard (vm.swappiness is 1).
  systemd.slices."user".sliceConfig.ManagedOOMSwap = "kill";

  # Anything above this is a runaway whose dump nobody will read, and whose
  # generation stalls every other task on the machine.
  systemd.coredump.settings.Coredump = {
    ProcessSizeMax = "2G";
    ExternalSizeMax = "2G";
  };
}
