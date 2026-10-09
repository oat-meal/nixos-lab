# laptop-nixos — Audit & Host Notes

## Hardware

- **Model**: Framework Laptop 13
- **CPU**: AMD Ryzen (8-core)
- **GPU**: AMD Radeon integrated (card1)
- **Storage**: ZFS on LUKS2 (rpool: ROOT/nixos, home, nix, log, swap zvol)
- **Kernel**: `linux_6_12` (stable LTS)

## Host-Specific Configuration

- **Suspend**: Enabled (lid switch handling)
- **Power**: power-profiles-daemon, portable power module, hibernate support
- **GameMode**: 4-core pinning (4 reserved for system), GPU device = card1
- **WiFi**: Power saving enabled (battery optimization)
- **Backlight**: `amdgpu.abmlevel=0` to prevent GPU idle lockups
- **Fingerprint**: Reader support enabled
- **Framework tools**: ectool
- **SSH**: wg0-only, key-only, fail2ban (`openFirewall = false`, `ListenAddress = 10.100.0.3`)
- **Sudo**: password (60 min global cache); NOPASSWD only for `lab-fw-dump`, `lab-listeners`, `lab-podman-probe` (2026-10-09)

## Differences from Workstation

| Setting | Workstation | Laptop |
|---------|-------------|--------|
| Kernel | `linuxPackages_7_0` (pinned; 7.0.14) | `linux_6_12` LTS |
| Suspend | Disabled | Enabled |
| WiFi power save | Disabled | Enabled |
| CPU governor | Performance | Managed by power-profiles-daemon |
| GameMode cores | 12 | 4 |
| GameMode GPU | card0 (default) | card1 (integrated) |
| Power module | `performance.nix` | `portable.nix` + `hibernate.nix` |
| DisplayLink | No — `displaylink.nix` exists but is imported by no host | No |
| nix-ld | Yes | No |
| Flatpak | Yes | No |

## Authorized SSH Keys

- `<user>@workstation-nixos`
- `<user>@laptop-nixos`
- `<user>@server-nixos`

---

## Audit History

### 2026-04-06 — Remote Fix (from workstation audit)

**Remediated:**

| Issue | Resolution |
|-------|-----------|
| GameMode core_count string type | Changed `"4"` to int `4` |
| GPU device override added | `gpu_device = lib.mkForce 1` for card1 |

No full on-host audit performed yet. Schedule when next on laptop.

### 2026-06-02 — Reimage + Security Hardening

- Reimaged with ZFS on LUKS2 (migrated from Btrfs)
- Kernel hardening module added (sysctl, audit logging, persistent journal)
- ZFS auto-scrub and auto-snapshots enabled
- SSH enabled with fail2ban
- Workstation SSH key authorized

### 2026-06-03 — Network Hardening

- SSH restricted to WireGuard mesh (wg0-only, `openFirewall = false`)
- All host keys authorized (full mesh)
- Scoped passwordless sudo added
- sops-nix added for WireGuard private key management
- Syncthing active (claude-context, git-crypt-keys)

### 2026-06-03 — Full Configuration Audit

**Status**: Healthy after remediation

Changes applied via shared module extraction (see workstation audit for full list):
- SSH bound to WireGuard IP (`ListenAddress = 10.100.0.3`)
- SMART monitoring enabled (shared `zfs-maintenance.nix`)
- Host resolution switched to WireGuard IPs
- Duplicate packages removed (`librewolf`, `lm_sensors`, `catppuccin-cursors`, `wireless-regdb`)
- SSH, sudo, ZFS config deduplicated to shared modules

### 2026-06-04 — Full Audit

**Status**: Healthy

**Remediated:**

| Issue | Resolution |
|-------|-----------|
| sshd bind race during rebuild | Added systemd ordering: sshd after wireguard-wg0.service (shared ssh.nix) |
| Flake inputs 3 months old | Updated all inputs |

**Accepted (no action):**

| Issue | Rationale |
|-------|-----------|
| systemd 258.3 coredumps (logind, udevadm) | Pre-date update to 258.7. Monitor for recurrence. |
| PAM auth failures from 10.100.0.3 | SSH auth attempts during host key change. Transient. |

### 2026-08-10 — Kernel module autoload dead after every reboot

**Status**: Fixed. This host is where the bug was first diagnosed; server-nixos hit it
identically on 2026-08-16.

**Symptom**: after a **reboot** — never after a `nixos-rebuild switch` — on-demand module
autoloading was dead. `/boot` failed to mount (`unknown filesystem type 'vfat'`), the
firewall failed (`nft: Protocol not supported`), and the network stack was crippled: without
`af_packet`, `socket(AF_PACKET)` returns `EAFNOSUPPORT`, which breaks NetworkManager's DHCP
client and wpa_supplicant — i.e. **no WiFi and no DHCP**.

**Root cause**: with systemd-initrd, `systemd-sysctl.service` and
`systemd-modules-load.service` run inside the initrd and, being `Type=oneshot` +
`RemainAfterExit=yes`, their `active (exited)` state is serialized across `switch_root`.
systemd never re-runs them against the real `/etc`, so `/etc/sysctl.d` and
`/etc/modules-load.d` are silently never applied. Everything in `60-nixos.conf` stayed at its
kernel default — verified: `vm.swappiness` 60 not 1, `kernel.pid_max` 32768 not 4194304,
`rp_filter` 0 not 2, and `kernel.modprobe` still `/sbin/modprobe`, which does not exist on
NixOS. `nixos-rebuild switch` masked it by restarting both units as full root, which is why
it recurred only on reboot.

**Fix**: commits `ba84971`, `b7ecba3`, `fdce496` — set `kernel.modprobe` via sysctl,
force-load `vfat`/`nls_*`/`af_packet`, and add a `reapply-kernel-config` oneshot that
re-invokes both generators after `switch_root`, ordered before the consumers that were
failing. Originally inline in this host's config; **extracted to
`hosts/common/optional/hardware/kernel-module-autoload.nix` on 2026-08-16** and imported here
instead (`7cfe606`), after the server hit the same bug. Full write-up:
[../kernel-module-autoload.md](../kernel-module-autoload.md).

**Lesson**: two byte-identical generations behaving differently ⇒ boot ordering or hardware,
not config content. And a host can look completely healthy after a `switch` while still being
broken on its next boot — only a reboot proves this class of fix.
