# workstation-nixos — Audit & Host Notes

## Hardware

- **CPU**: AMD Ryzen 9950X (Zen 5, 16-core, 32-thread)
- **GPU**: AMD Radeon RX 9070 XT (RDNA 4, Navi 48)
- **RAM**: 64GB DDR5
- **Storage**: ZFS on LUKS2 (rpool: ROOT/nixos, home, nix, log, swap zvol) + storage pool (2x NVMe LUKS2)
- **Network**: WiFi 7 (Qualcomm WCN785x, ath12k) + 5GbE Ethernet (RTL8126)
- **Kernel**: `pkgs.linuxPackages_6_18` (6.18 LTS; 6.18.44 on 2026-10-09). The 7.0 line is EOL
  and ZFS follows only LTS lines. *(History: 7.0.x was pinned until the 26.05 migration; the
  7.0.10 hold was lifted 2026-08-03 (`0bc7e1b`) once the WiFi failure was traced to boot
  ordering rather than the kernel. See Known Issues.)*

## Host-Specific Configuration

- **Suspend**: Disabled (Zen 5 hardware issue)
- **Power**: Always-on, performance governor, all power saving disabled
- **GameMode**: 12-core pinning (4 reserved for system)
- **SSH**: wg0-only, key-only, fail2ban (`openFirewall = false`, `ListenAddress = 10.100.0.1`)
- **Sudo**: password (60 min global cache); NOPASSWD only for `lab-fw-dump`, `lab-listeners`, `lab-podman-probe` (2026-10-09)
- **NFS mount**: `/mnt/server` via WireGuard (10.100.0.2)
- **DisplayLink**: not active — `displaylink.nix` (EVDI) is kept but imported by no host; `videoDrivers` is `modesetting` + `fbdev`
- **nix-ld**: Enabled for Fightcade, AppImages
- **Flatpak**: Enabled (Fightcade)

## Known Issues / Deferred Updates (monthly-review checks)

- **WCN7850 WiFi firmware-init grab race — CONFIRMED ROOT CAUSE** (resolved 2026-08-03).
  The `ath12k_wifi7_pci` netdev (`wlp16s0`) appears **~13-29 s before** the WCN7850
  firmware finishes init. If NetworkManager/wpa_supplicant grab the interface during
  that window, it fails (`wpa_supplicant couldn't grab this interface`, a D-Bus/nl80211
  error) and the card **wedges** — NM's 10 s retries never recover it. Whether the grab
  races the firmware is decided purely by **boot ordering**.
  - **Trigger identified by bisection (gen 50 works / gen 51 fails, byte-identical
    kernel+initrd+driver+firmware):** the `stack-smoke-test` monitoring unit declared
    `wants = network-online.target` + `Persistent = true` timer, which pulled
    `network-online.target` into early boot, brought NetworkManager up immediately, and
    made it engage `wlp16s0` at T+1 s — losing the race. Without it, NM starts ~13 s
    later (firmware ready) and connects.
  - **FIX (this host):** dropped both monitoring imports (`stack-smoke-test.nix`,
    `post-rebuild-verify.nix`) — they alerted to the offline server's ntfy hub and
    provided ~no value. WiFi now reliably comes up.
  - **DEAD ENDS (don't retry):** `qrtr`/`qrtr_mhi` kernelModules + softdep — no effect;
    `wifi-ath12k-recovery` service — only handles "interface missing", not this
    "present-but-dead" case; NM `unmanaged` + hand-to-nm handover — prevented the race
    but NM then wouldn't auto-connect (would need an explicit `nmcli device connect`).
  - **RE-HARDENING (optional, if ever wanted):** keep monitoring off, OR re-add it
    without `network-online.target`/`Persistent`; the durable fix is `unmanaged` +
    handover **with** an explicit `nmcli device connect wlp16s0` after set-managed.
  - **STATUS 2026-08-16 — monitoring PARKED, not blocked.** The `wants=network-online.target`
    was removed from `stack-smoke-test.nix`, so the anti-pattern is gone and both modules
    are technically safe to re-enable (`post-rebuild-verify.nix` never had it). They stay
    off by choice pending a whole-lab observability review — see the import block in
    `hosts/workstation/default.nix` and postmortem action items #6 and #8. Note the
    anti-pattern survived here for two weeks after `769f86b` "fixed" it elsewhere,
    because that commit did not grep the repo for the pattern.

- **Kernel 7.0.14 / nixpkgs 2026-06-30 update — DONE, WiFi confirmed working** (2026-08-03).
  The earlier "7.0.14 breaks WiFi (`-517`)" was a **misdiagnosis** — that boot had the
  stack-smoke-test monitoring present, so the real cause was the boot-ordering grab race
  above, not the kernel. Re-tested the full flake update **with monitoring removed**:
  kernel 7.0.14 boots WiFi cleanly (associates, gets IP, no `-517`/grab errors). The
  7.0.10 hold is **lifted**; `flake.lock` advanced to nixpkgs `b6018f8` (mango still held —
  it needs a wlroots newer than stable ships). Lesson: never conclude "kernel regression"
  while another boot-ordering change is in flight — isolate variables first.

## Filesystem

| Mount | ZFS Dataset | Pool |
|-------|-------------|------|
| `/` | `rpool/ROOT/nixos` | rpool (NVMe, LUKS2) |
| `/home` | `rpool/home` | rpool |
| `/nix` | `rpool/nix` | rpool |
| `/var/log` | `rpool/log` | rpool |
| swap | `rpool/swap` (zvol) | rpool |
| `/storage` | `storage/data` | storage (2x NVMe, LUKS2) |
| `/storage/comfyui` | `storage/comfyui` | storage |
| `/storage/media` | `storage/media` | storage |
| `/storage/steam` | `storage/steam` | storage |

## Peripherals

- Xbox Wireless Controllers
- PS5 DualSense, PS4 DualShock
- Meta Quest 3 (USB)
- ASUS ROG devices
- Shure MV7+ (USB audio)
- FiiO K7 (USB DAC)
- Elgato Prompter (DisplayLink — not functional: no host imports `displaylink.nix`)

## Troubleshooting

### Steam won't launch
```bash
journalctl --user -b --no-pager | grep -i steam
rm -f ~/.steam/steam.pid
steam
```

### Graphics issues
```bash
vulkaninfo --summary | head -30
glxinfo | grep "direct rendering"
```

### WiFi (ath12k)
```bash
ip link show
lsmod | grep ath
cat /sys/class/net/wl*/device/power/control
```

WiFi shutdown cleanup service exists for ath12k driver issues (`systemd.services.wifi-shutdown-cleanup`).

---

## Audit History

### 2026-04-06 — Full Configuration Audit

**Status**: Healthy after remediation

**Remediated:**

| Issue | Resolution | Files Changed |
|-------|-----------|---------------|
| Hardcoded home path in steam.nix | Use `config.users.users.<user>.home` | `gaming/steam.nix` |
| No garbage collection | Added weekly GC, 30-day retention | `core/nix.nix` |
| Timezone mismatch (UTC vs Denver) | System timezone → America/Denver | `core/locale.nix` |
| Unstable overlay defined 3 times | Kept flake.nix only | Deleted `overlays/`, `modules/unstable-packages.nix` |
| Logrotate disabled | Re-enabled | `hosts/workstation/default.nix` |
| Duplicate Wayland session vars | Removed from graphics.nix | `gaming/graphics.nix` |
| GPG agent configured twice | System-level only | `home/<user>/default.nix`, `yubikey/default.nix` |
| Redundant `iwlwifi.power_scheme` | Removed | `hosts/workstation/default.nix` |
| GameMode core_count string type | Changed to int `12` | `hosts/workstation/default.nix` |
| Duplicate theme files | Consolidated to common | `home/<user>/default.nix` |
| Custom Steam desktop entry | Removed (use upstream) | `gaming/steam.nix` |
| Legacy `modules/` directory | Deleted, migrated imports | Multiple |
| Browser stack (Firefox, Brave) | Consolidated to Zen Browser | Multiple |
| Claude Code on stable | Moved to unstable | `desktop/apps.nix` |
| Wallpaper fails silently | Power-aware wallpaper script | `niri/home.nix` |
| 1,440 old generations | `nix-collect-garbage --delete-older-than 30d` | Manual |

**Follow-up (same session):**

| Issue | Resolution |
|-------|-----------|
| mpvpaper startup race | Added to niri system packages |
| Duplicate packages (wl-clipboard, htop, ripgrep) | Removed from user-packages |
| wireguard-tools in 3 modules | Kept in nordvpn.nix only |
| Waybar VPN script sudo spam | Replaced `wg show` with `ip link show` |
| Broken steam.desktop symlink | Deleted |
| 5 `.hm_bak` files | Deleted |
| Stale Brave .desktop file | Deleted |

**Accepted (no action):**

| Issue | Rationale |
|-------|-----------|
| Steam split-lock warnings | Upstream Valve bug |
| Unpinned niri-flake | flake.lock pins it |
| `linuxPackages_latest` | RDNA 4 requires it |
| dbus/gnome-keyring warnings | Cosmetic |

### 2026-06-02 — Reimage + Security Hardening

- Reimaged with ZFS on LUKS2 (migrated from Btrfs)
- Kernel hardening module added (sysctl, audit logging, persistent journal)
- ZFS auto-scrub and auto-snapshots enabled
- WiFi driver corrected: removed iwlwifi, fixed ath11k → ath12k
- udev rule to hide ZFS members from Thunar sidebar
- NFS automount to server at /mnt/server
- Steam library added on /storage/steam (ZFS dataset)
- Steam dedicated server firewall ports disabled

### 2026-06-03 — Network Hardening

- SSH server added (wg0-only, `openFirewall = false`, fail2ban)
- All host keys authorized (full mesh)
- Scoped passwordless sudo added
- NFS mount changed from LAN hostname to WireGuard IP (10.100.0.2)
- sops-nix added for WireGuard private key management
- Syncthing active (claude-context, git-crypt-keys) — git-crypt-keys folder removed 2026-10-09

### 2026-06-03 — Full Configuration Audit

**Status**: Healthy after remediation

**Remediated:**

| Issue | Resolution |
|-------|-----------|
| SSH/sudo/ZFS config duplicated across hosts | Extracted shared modules: `ssh.nix`, `sudo.nix`, `zfs-maintenance.nix` |
| SSH bound to 0.0.0.0 (defense-in-depth) | Added `ListenAddress = 10.100.0.1` (WireGuard IP only) |
| No SMART monitoring | Added to shared `zfs-maintenance.nix` |
| `/etc/hosts` used DHCP LAN IPs | Switched to WireGuard mesh IPs for host resolution |
| `librewolf` still installed | Removed (consolidated to Zen Browser) |
| Duplicate `catppuccin-cursors` in apps.nix | Removed (provided by theme.nix) |
| Duplicate `wireless-regdb` in framework.nix | Removed (provided by wifi.nix) |
| `lm_sensors` in user-packages and server | Moved to core packages (all hosts) |
| Logrotate only on workstation | Moved to shared `zfs-maintenance.nix` (all hosts) |

**Accepted (no action):**

| Issue | Rationale |
|-------|-----------|
| `nix*`/`git`/`systemctl` sudo wildcards | Effectively full root, acceptable for single-user lab |
| `hostId` not in host config | Already in `hardware-configuration.nix` (installer-generated) |

### 2026-06-04 — Full Audit

**Status**: Healthy

**Remediated:**

| Issue | Resolution |
|-------|-----------|
| sshd bind race during rebuild | Added `systemd.services.sshd.after/wants = wireguard-wg0.service` in shared ssh.nix |
| Ollama bound to 0.0.0.0 (server) | Bound to WireGuard IP 10.100.0.2 |
| AdGuard web UI bound to 0.0.0.0 (server) | Bound to WireGuard IP 10.100.0.2:3000 |
| Deploy script lacks pre-flight | Added `nix eval` validation before deployment |
| Flake inputs 3 months old | Updated all inputs (nixpkgs May 26, HM May 23, niri Jun 1, zen Jun 3, sops-nix May 5) |

**Accepted (no action):**

| Issue | Rationale |
|-------|-----------|
| USB enumeration errors (port 5-2.2) | Likely physical (flaky device/cable). Monitor. |
| `sm-notify: Failed to open directory sm.bak` | NFS statd cosmetic, no functional impact |
| `Failed to fork off sandboxing environment` | Transient systemd generator issue during rebuild |
| WireGuard `REPLACE-WITH-*-PUBLIC-KEY` errors | Historical, from pre-git-crypt-unlock rebuilds |
