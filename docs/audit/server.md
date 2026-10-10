# server-nixos — Audit & Host Notes

## Hardware

- **Model**: Framework Server (5U rack)
- **CPU**: AMD Ryzen AI Max+ 395, 128GB unified RAM
- **GPU**: AMD Radeon 8060S (RDNA 3.5, integrated)
- **Storage**: ZFS on LUKS2 (rpool: 2x 1TB NVMe mirror), /storage dataset on rpool
- **Network**: **Wired only.** Ethernet is **5GbE Realtek RTL8126** (`10ec:8126`, driver `r8169`,
  PCI `bf:00.0`, MAC `9c:bf:0d:01:03:73`) — VERIFIED 2026-08-16 via `lspci -nnk`. Interface
  `enp191s0`, static **192.168.10.50/24** via the declarative `wired-static` NM profile.
  Negotiated link: **2500 Mb/s, full duplex** (verified 2026-08-16) — as predicted, the 5GbE
  NIC settles at 2.5G on the current copper path. Read it without root via
  `cat /sys/class/net/enp191s0/speed`; `ethtool` was missing from this host until 2026-08-16
  and is now in core packages.
  WiFi (MediaTek MT7925, `mt7925e`) is **blacklisted**; see "Wired-only" below.
- **Kernel**: `pkgs.linuxPackages_6_18` (6.18 LTS; 6.18.44 on 2026-10-09). The 2026-08-16 pin was
  `linuxPackages_7_0`, now EOL — ZFS follows only the LTS lines. Do **not** use
  `zfs.latestCompatibleLinuxPackages`: it is deprecated and now resolves to the nixpkgs
  *default* kernel, not the newest ZFS-compatible one, inverting the guarantee it was chosen
  for. It silently built 6.12.93 for a host running 7.0.10 — a major downgrade on next reboot,
  caught only by inspecting the built initrd. 7.1 still breaks ZFS 2.3.7.

## Wired-only networking (2026-08-16)

WiFi held a DHCP lease alongside the wired NIC, leaving the host dual-homed with **two default
routes to the same gateway**. That makes wg0 source-address selection ambiguous and invites
asymmetric routing. `mt7925e` is now blacklisted (`boot.blacklistedKernelModules`) rather than
left as an unmanaged interface that could be re-enabled by accident.

The wg0 endpoint (`hosts/network.nix` → `lanIPs.server-nixos`) tracks the **wired** address.
It previously pointed at the WiFi address, and the earlier `.50` static was a hand-made NM
profile that did not survive a reboot — NM fell back to an auto-generated DHCP profile and the
mesh then only converged in whichever direction the server happened to initiate. The profile is
now declared via `networking.networkmanager.ensureProfiles`.

~~**Open item (router-side):** `192.168.10.50` must sit outside the DHCP pool, or be reserved
for `9c:bf:0d:01:03:73`.~~ **DONE 2026-08-16** (reserved at the router — see Pending validation #2).
(2026-10-09: box found on DHCP .93 — NM auto-default profile won the race; fixed in config with
`no-auto-default` (90e5e70); deployed and switched live to .50 the same day.)

## Headless disk unlock (2026-08-16)

LUKS passphrase entry made every reboot a physical errand on a headless box. Both containers
(`cryptroot0`, `cryptroot1`) now carry a **TPM2 token bound to PCRs 0+7**; the passphrase slot is
**retained**, not removed. PCRs 4/8/9 are deliberately excluded — they measure
bootloader/kernel/initrd, so every `nixos-rebuild` would invalidate the seal. A **BIOS/firmware
update will still break it** and require re-enrolling with `systemd-cryptenroll`.

Rescue path for exactly that case: initrd runs sshd on **:2222** at a static `.50`
(`ssh -p 2222 root@192.168.10.50`, then `systemd-tty-ask-password-agent`). Its host key lives on
the unencrypted ESP, so treat it as compromised-by-physical-access — it authenticates the
endpoint, it does not grant access to data. **Verified working on the 2026-08-16 reboot** (booted
unattended, no console); the rescue path itself remains untested until a boot actually needs it.

FIDO2/YubiKey unlock is **not** appropriate here — it requires a physical touch, which is
incompatible with unattended boot.

## Pending validation
1. ~~Negotiated link speed~~ — **DONE 2026-08-16**: 2500 Mb/s full duplex.
2. ~~Reserve `.50` at the router~~ — **DONE 2026-08-16** (oat). The wired static is now protected
   against a competing DHCP lease.
3. Plan: server → CRS310-8G+2S+IN **2.5G copper** port. Already negotiating 2.5G today, so the
   switch migration should be a no-change for throughput. DAS is direct-attached — no switch
   port needed (see vault Storage-Migration).

## Networking / switch plan
- **Switch (ordered):** MikroTik **CRS310-8G+2S+IN** — 8× 2.5G RJ45 + 2× SFP+ (10G), fanless,
  RouterOS (export config → git). Office switch, uplinked to the router via a 200ft Cat6A run
  through the crawlspace (in conduit, off the ground). All hosts on plain 2.5G copper ports.
- **5GbE note:** both server and workstation are (likely) 5GbE RTL8126; on 2.5G copper they
  negotiate 2.5G — plenty for these workloads (models load once + stay GPU-resident; DAS-NFS
  rarely saturates 2.5G). 5GBASE-T isn't a switch tier — full 5G needs a 10GBASE-T port.
- **UPGRADE PATH (only if 2.5G becomes limiting):** add a MikroTik **CRS304-4XG-IN** (~$199,
  4× 10GBASE-T, fanless, does 1/2.5/5/10G) as a 10G "fast lane." Put workstation + server
  (+ DAS host) on its 10G-copper ports → full 5G between them; uplink the CRS304 to the CRS310
  via **SFP+ DAC cable** (10G). Keeps everything MikroTik + fanless; spend the extra only when
  a concrete WS↔server transfer need appears. (Single-box 8-port fanless 5G copper doesn't exist
  in MikroTik's line — CRS312 is 8×10G-RJ45 but rackmount + active fan.)

## Host-Specific Configuration

- **Role**: Headless home server
- **Remote access**: SSH and Mosh (wg0-only, key-only, no root)
- **Sudo**: password (60 min global cache); NOPASSWD only for `lab-fw-dump`, `lab-listeners`, `lab-podman-probe` (2026-10-09; the udevadm rule had no consumer and was dropped)
- **Services**: Ollama (ROCm GPU), Jellyfin, AdGuard Home, NFS server, plus the AI-lab stack (see docs/ai-lab.md)
- **AdGuard Home**: as of 2026-10-09 its query log shows no queries since 2026-08-16 — LAN clients and the
  server resolve via the router; it is not in the resolution path. Its admin API has no login (wg0-only).
- **NFS**: Exports `/storage` to WireGuard subnet (root_squash)
- **ZFS ARC**: 32GB
- **ZFS maintenance**: Monthly scrub, auto-snapshots (frequent/hourly/daily/weekly/monthly)
- **Security**: Fail2ban, SSH hardened (MaxAuthTries=3, no X11/TCP forwarding), kernel hardening, audit logging, SMART monitoring

## Services & Ports

| Service | Port | Protocol | Interface |
|---------|------|----------|-----------|
| SSH | 22 | TCP | wg0 only |
| Mosh | 60000-60010 | UDP | wg0 only |
| NFS | 111, 2049 | TCP/UDP | wg0 only |
| AdGuard DNS | 53 | TCP/UDP | all (LAN) |
| ntfy | 2586 | TCP | wg0 only |
| AdGuard Home Web UI | 3000 | TCP | wg0 only |
| ChromaDB | 8000 | TCP | wg0 only |
| Open WebUI | 8080 | TCP | wg0 only |
| Lab dashboard | 8085 | TCP | wg0 only |
| lab-api | 8091 | TCP | wg0 only |
| Jellyfin | 8096 | TCP | wg0 only (from the 2026-10-09 deploy; was all — setup wizard never completed) |
| ComfyUI | 8188 | TCP | wg0 only |
| HY-Motion | 8190 | TCP | wg0 only |
| Kokoro TTS | 8880 | TCP | wg0 only |
| SearXNG | 8888 | TCP | wg0 only |
| Ollama API | 11434 | TCP | wg0 only |
| Syncthing | 22000 | TCP/UDP | all (LAN) |
| Syncthing discovery | 21027 | UDP | all (LAN) |
| WireGuard | 51821 | UDP | all (LAN) |

## Authorized SSH Keys

- `<user>@workstation-nixos`
- `<user>@laptop-nixos`

The server's own `<user>` key is authorized nowhere; server-side probes reach other hosts as
`lab-monitor`.

---

## Audit History

### 2026-06-02 — Initial Deployment

- Deployed via USB thumb drive from workstation
- Issues encountered during deploy: see deployment-issues notes
- NFS server enabled, SSH key-based access confirmed from workstation and laptop

### 2026-06-02 — Security Hardening

- SSH hardened: MaxAuthTries=3, ClientAliveInterval, no X11/TCP forwarding
- Passwordless sudo scoped to management commands only
- Kernel hardening module added (sysctl, audit logging, persistent journal)
- ZFS auto-scrub and auto-snapshots enabled
- SMART disk monitoring enabled
- Fail2ban added for SSH brute force protection
- NFS switched to root_squash

### 2026-06-03 — Network Hardening

- SSH and Mosh restricted to WireGuard mesh (wg0-only, `openFirewall = false`)
- NFS export moved from LAN subnet to WireGuard subnet
- NFS firewall ports moved to wg0 interface
- Home Assistant container removed (not in use)
- sops-nix added for WireGuard private key management
- Full SSH mesh established (all host keys authorized)

### 2026-06-03 — Full Configuration Audit

**Status**: Healthy after remediation

**Remediated:**

| Issue | Resolution |
|-------|-----------|
| SSH bound to 0.0.0.0 | Added `ListenAddress = 10.100.0.2` (WireGuard IP only) |
| Ollama/AdGuard web UI open globally | Moved to wg0-only firewall (DNS + Jellyfin stay global) |
| No `logRefusedConnections` | Enabled |
| LLMNR enabled | Disabled (unnecessary attack surface) |
| Podman enabled with no containers | Removed Podman, podman group, podman sudo rule |
| Commented-out Samba block | Removed |
| SSH/sudo/ZFS config duplicated | Extracted to shared modules |
| SMART/smartmontools/lm_sensors/htop duplicated | Consolidated to shared modules and core packages |
| Host resolution used DHCP LAN IPs | Switched to WireGuard mesh IPs |

### 2026-06-04 — Full Audit

**Status**: Healthy

**Remediated:**

| Issue | Resolution |
|-------|-----------|
| Ollama bound to 0.0.0.0 | Bound to WireGuard IP 10.100.0.2 (defense-in-depth with firewall) |
| AdGuard web UI bound to 0.0.0.0 | Bound to WireGuard IP 10.100.0.2:3000 |
| sshd bind race during rebuild | Added systemd ordering: sshd after wireguard-wg0.service |
| Flake inputs 3 months old | Updated all inputs |

**Accepted (no action):**

| Issue | Rationale |
|-------|-----------|
| PAM auth failures from LAN IPs (<lan-subnet>) | SSH correctly rejected — not listening on LAN |
| `PAM user mismatch` during rebuild | Stale SSH session, transient |
| WireGuard `REPLACE-WITH-*-PUBLIC-KEY` errors | Historical, from pre-git-crypt-unlock rebuilds |

### 2026-08-16 — Server return: unlock, networking, kernel, module autoload

**Status**: Healthy. Verified against a real cold boot — unattended TPM2 unlock, `.50` via
`wired-static`, single default route, zero failed units.

**Remediated:**

| Issue | Resolution |
|-------|-----------|
| Passphrase prompt on every reboot (headless) | TPM2 enrolled on both containers, PCRs 0+7; passphrase slot kept |
| No way in if the TPM seal breaks | initrd sshd on :2222 at a static `.50` |
| Dual-homed — two default routes (WiFi + wired) | `mt7925e` blacklisted; wired-only |
| wg0 endpoint pointed at the WiFi address | `lanIPs.server-nixos` → `192.168.10.50` (wired) |
| `.50` static was a hand-made NM profile, lost on reboot | Declared via `ensureProfiles` |
| `lanIPs.workstation-nixos` stale (`.71`, actual `.92`) | Corrected — the server could not originate handshakes toward it |
| Kernel silently downgrading 7.0.10 → 6.12.93 | Pinned `pkgs.linuxPackages_7_0`; dropped the deprecated ZFS attr |
| `/boot`, firewall, NFS, podman failing after every reboot | systemd-initrd module-autoload bug — see `docs/kernel-module-autoload.md` |

**Root cause of the cascade:** `/proc/sys/kernel/modprobe` was still the compiled-in
`/sbin/modprobe`, which does not exist on NixOS, so every kernel-initiated autoload failed
silently. `nixos-rebuild switch` masked it by re-running the generators as root, so it recurred
only on reboot. Same bug laptop-nixos hit on 2026-08-10; that fix was host-scoped and has since
been extracted to `hosts/common/optional/hardware/kernel-module-autoload.nix`.

**Open (external):** reserve `.50` at the router, or move it outside the DHCP pool.
