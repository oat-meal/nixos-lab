# systemd sandboxing baseline for this repo's own services (not a module — a value).
#
#   serviceConfig = (import ../../sandbox.nix) // { …per-unit overrides… };
#
# Baseline measured against docs/audit/systemd-security-baseline.md (2026-10-10), where the
# repo's own units scored 8.2–9.2 ("EXPOSED"/"UNSAFE") against 1.4–1.8 for upstream ollama,
# jellyfin and open-webui. Each unit then loosens only what it is measured to need — e.g.
# fleet-sentinel needs /dev/zfs, hy-motion cannot take MemoryDenyWriteExecute (torch JIT).
# Re-score after any change:  systemd-analyze security --offline=true <unit file>
{
  NoNewPrivileges = true;
  PrivateTmp = true;
  PrivateDevices = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  ProtectClock = true;
  ProtectHostname = true;
  ProtectProc = "invisible";
  RestrictSUIDSGID = true;
  RestrictRealtime = true;
  RestrictNamespaces = true;
  LockPersonality = true;
  SystemCallArchitectures = "native";
  SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
  SystemCallErrorNumber = "EPERM";   # a denied call fails, it does not kill the service
  RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
  CapabilityBoundingSet = "";
  AmbientCapabilities = "";
  UMask = "0077";
}
