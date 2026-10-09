# Kernel and system hardening
# Sysctl parameters, audit logging, and systemd journal persistence

{ lib, ... }:

{
  # Kernel hardening
  boot.kernel.sysctl = {
    # Hide kernel pointers from unprivileged users
    "kernel.kptr_restrict" = 2;

    # Restrict dmesg access to root
    "kernel.dmesg_restrict" = 1;

    # Disable unprivileged eBPF
    "kernel.unprivileged_bpf_disabled" = 1;

    # Restrict ptrace to admin only (scope 2; CAP_SYS_PTRACE required).
    # Workstation overrides to scope 1 (descendants-only) so EasyAntiCheat works.
    "kernel.yama.ptrace_scope" = 2;

    # Magic SysRq: 152 = 128 (reboot) + 16 (sync) + 8 (debug dumps).
    #
    # NOT hardening — a deliberate, documented reduction. The default here was 16
    # (sync only), set by systemd's 50-default.conf and never overridden, which
    # means SysRq+B, +W, +M and +T all silently did NOTHING on all three hosts.
    #
    # Cost of leaving it at 16, measured twice:
    #   2026-08-21  a wedged workstation could only be recovered by holding the
    #               power button; no way to capture why.
    #   2026-09-03  workstation froze at 21:10:23 with the kernel alive (ICMP and
    #               TCP handshakes fine) and every userspace process stalled. No
    #               OOM, no hung_task, no pool error — the journal simply stops.
    #               +W (blocked tasks) and +M (memory) are exactly the probes that
    #               would have named it, and both were no-ops. Root cause is still
    #               unknown because of this.
    #
    # Risk accepted: SysRq requires physical console access, which is already the
    # trust boundary on all three of these machines.
    "kernel.sysrq" = 152;

    # Network hardening
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
  };

  # Persistent journal with size limits
  services.journald.extraConfig = ''
    Storage=persistent
    Compress=yes
    SystemMaxUse=500M
    RuntimeMaxUse=100M
  '';

  # Audit logging
  security.audit.enable = true;

  # Raise the backlog from the 1024 default. When it fills, the kernel drops
  # records — audit_lost=29976703 on 2026-08-20, and audit_lost=4464545 with
  # "kauditd hold queue overflow" repeating in the final seconds before the
  # 2026-09-03 workstation freeze, where the flood crowded the real cause out of
  # the journal against SystemMaxUse=500M and it was never recorded.
  #
  # This reduces loss; it does NOT reduce the record RATE. The source is the
  # access_denied pair below firing on Steam's CGamepadAPITask and Proton's
  # dxvk-submit polling /sys/kernel/debug (root-owned 0700) in a tight loop.
  # Check whether this was enough: `journalctl -k | grep audit_lost | tail -1`.
  security.audit.backlogLimit = 8192;

  security.audit.rules = [
    # Log privilege escalation
    "-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k privilege_escalation"
    # Log unauthorized access attempts
    "-a always,exit -F arch=b64 -S open,openat -F exit=-EACCES -k access_denied"
    "-a always,exit -F arch=b64 -S open,openat -F exit=-EPERM -k access_denied"
  ];
}
