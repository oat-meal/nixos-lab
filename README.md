# NixOS Lab

Multi-host NixOS infrastructure managed as a single Nix Flake. Declarative configurations for a personal computing environment with full-disk encryption (LUKS2 + ZFS) across all hosts.

## Conventions

Angle-bracket tokens in the docs are placeholders — replace them with your own values:

| Placeholder | Meaning |
|-------------|---------|
| `<user>` | Your login username (the repo and `/home` are owned by it, not root) |
| `<server-lan-ip>`, `<laptop-lan-ip>` | Your hosts' LAN addresses |
| `<lan-subnet>` | Your LAN subnet (e.g. `192.0.2.0/24`) |

Placeholders keep the docs readable for any lab. This lab's real values are in
`hosts/network.nix`, which is plaintext and public by design: addresses and public keys
are not secrets here (private keys are in sops).

Host names (`workstation-nixos`, `laptop-nixos`, `server-nixos`) are examples — rename them for your own machines. WireGuard mesh addresses (`10.100.0.x`) are shown as-is; substitute your own mesh range.

> New to NixOS? See [docs/nixos-primer.md](docs/nixos-primer.md)
>
> Curious what the self-hosted AI stack runs and how fast? See [docs/ai-lab.md](docs/ai-lab.md) — models, measured benchmarks, and hardware notes.

## Hosts

| Host | Hardware | Storage | Status |
|------|----------|---------|--------|
| `workstation-nixos` | Ryzen 9950X, 64GB RAM, AMD GPU | ZFS on LUKS2 | Active |
| `laptop-nixos` | Framework 13, Ryzen, 32GB RAM | ZFS on LUKS2 | Active |
| `server-nixos` | Ryzen AI Max+ 395, 128GB RAM, AMD iGPU | ZFS on LUKS2 | Active |

## Storage Architecture

All hosts share the same base layout:

- **LUKS2** full-disk encryption with argon2id PBKDF
- **ZFS** pools on LUKS containers (`rpool` for OS; data on a separate `storage` pool on the workstation and on the `rpool/storage` dataset on the server)
- **ZFS datasets**: `rpool/ROOT/nixos`, `rpool/home`, `rpool/nix`, `rpool/log`
- **Swap**: ZFS zvol `rpool/swap` on the workstation (8G) and laptop (32G, hibernate); none on the server
- **YubiKey FIDO2** unlock support (optional, enrolled post-install)

## Quick Start

### Installation

A custom installer ISO handles partitioning, encryption, and system deployment:

```bash
# 1. Build the installer ISO, then flash it to USB (from an existing NixOS host)
nix build .#installer-iso                    # -> ./result/iso/*.iso
sudo dd if=./result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync   # replace sdX

# 2. Boot the USB on the target machine

# 3. Connect to network (NetworkManager is available)
nmtui

# 4. Run the installer
install-nixos
```

The installer will:
- Partition disks (GPT + EFI + LUKS2)
- Create ZFS pools and datasets
- Clone this flake from GitHub
- Generate hardware-configuration.nix for the target hardware
- Build and install the system

### Post-Install

```bash
# Enroll YubiKey for LUKS unlock (optional)
sudo systemd-cryptenroll /dev/nvme0n1p2 --fido2-device=auto

# Set user password
passwd <user>
```

> **Boot unlock order:** with a PIN-protected FIDO2 enrollment, the unlock at
> boot requires the PIN *first*, then a touch. systemd prompts for the token
> PIN and only blinks the YubiKey for touch after the PIN is accepted. The
> prompt does not state this order, so it is easy to tap the key too early — a
> premature tap is ignored, so just enter the PIN and tap when it blinks.

## Repository Structure

```
nixos-lab/
├── flake.nix                        # Flake: all hosts + installer ISO
├── flake.lock                       # Pinned inputs
├── deploy.sh                        # Multi-host deploy script
│
├── .github/workflows/check.yml      # CI: evaluate all systems + ISO, content guard
├── .sops.yaml                       # sops-nix age key config
├── secrets/
│   ├── secrets.yaml                 # Runtime secrets: WireGuard private keys (sops encrypted)
│   └── init-sops.sh                 # Helper to collect and encrypt WireGuard keys
│
├── installer/                       # Custom installer ISO
│   ├── default.nix                  # ISO system configuration
│   ├── install.sh                   # Interactive install script
│   ├── refresh-flake.sh             # Pull latest flake to USB
│   └── claude-config/               # CLAUDE.md baked into the ISO
│
├── hosts/
│   ├── network.nix                  # IPs, public keys, device IDs — plaintext data, the `net` module arg
│   ├── common/
│   │   ├── core/                    # Required on ALL hosts
│   │   │   ├── boot.nix             # systemd-boot
│   │   │   ├── locale.nix           # Locale/timezone
│   │   │   ├── networking.nix       # NetworkManager, host resolution (WireGuard IPs)
│   │   │   ├── nix.nix              # Flakes, settings
│   │   │   ├── packages.nix         # Base CLI tools
│   │   │   ├── shell.nix            # Zsh + Oh-My-Zsh
│   │   │   └── users.nix            # User definitions
│   │   │
│   │   └── optional/                # Opt-in modules
│   │       ├── ai/                  # Ollama, Open WebUI, ComfyUI, SearXNG, ChromaDB, dashboard
│   │       ├── desktop/             # MangoWM, greetd, audio, fonts, apps
│   │       ├── dev/                 # Game-dev tooling (gamedev.nix)
│   │       ├── gaming/              # Steam, GameMode, Vulkan
│   │       ├── hardware/            # AMD, Bluetooth, Framework, printing, DisplayLink (inactive)
│   │       ├── monitoring/          # Post-rebuild verifier, GPU-wedge sentinel, update advisor, AMD-stack smoke test (imported by no host)
│   │       ├── networking/          # Firewall, NordVPN, SSH, WiFi, WireGuard, Syncthing, Tailscale, sops
│   │       ├── power/               # Performance, portable, hibernate
│   │       ├── security/            # LUKS/FIDO2, YubiKey, PAM U2F, sudo
│   │       └── storage/             # ZFS maintenance (scrub, snapshots, logrotate)
│   │
│   ├── workstation/                 # Gaming workstation
│   ├── laptop/                      # Framework 13 laptop
│   ├── server/                      # Home server
│
├── home/
│   ├── <user>/                         # Home Manager entry point
│   └── common/optional/             # HM modules
│       ├── desktop/                 # MangoWM + Noctalia shell, yazi, etc.
│       ├── security/                # YubiKey user-level config
│       ├── theme.nix                # Catppuccin Macchiato
│       └── user-packages.nix        # User applications
│
├── ai-lab/                          # Self-hosted AI stack (see docs/ai-lab.md)
│   ├── api/                         # Lab OpenAPI tool server (Open WebUI tools)
│   ├── bench/                       # Reproducible model benchmark scripts
│   ├── comfyui/                     # ComfyUI image (Containerfile, Containerfile.gfx1201, patch-custom-nodes.sh; workflows untracked by policy)
│   ├── eliteintel/                  # Elite Dangerous voice copilot package
│   ├── lora-training/               # LoRA training toolkit
│   ├── mcp/                         # Host-health MCP server
│   ├── openwebui/                   # Open WebUI custom tools
│   ├── quorum/                      # Multi-model quorum CLI
│   ├── rag/                         # RAG (ChromaDB + embeddings) CLI
│   ├── research/                    # Deep-research CLI (SearXNG → synthesize)
│   ├── sentinel/                    # Nightly fleet-health + snapshot-freshness sentinel; SearXNG search-sentinel
│   ├── smoke-test/                  # AMD ROCm stack smoke test (module kept, imported by no host)
│   └── update-advisor/              # Weekly flake-update risk advisor
│
└── docs/
    ├── ai-lab.md                    # AI stack: models, benchmarks, hardware notes
    ├── nixos-primer.md              # Intro to this flake for NixOS newcomers
    ├── deployment.md                # Deployment guide
    ├── deployment-issues.md         # Deployment lessons learned
    ├── portal-filechooser.md        # xdg-desktop-portal FileChooser fix
    ├── kernel-module-autoload.md    # systemd-initrd switch_root module-load bug
    ├── searxng-engines-degraded.md  # SearXNG web engines disabled; API engines only
    ├── audit/                       # System audit framework
    └── NORDVPN-SETUP.md             # VPN guide
```

## Secrets

One system, **sops-nix**: `secrets/secrets.yaml` holds the WireGuard private keys, encrypted in git via age and decrypted to `/run/secrets/` at activation. Age keys derive from each host's SSH host key, so there is no key to distribute.

`hosts/network.nix` is **deliberately plaintext**: usernames, LAN and mesh addresses, public keys, Syncthing device IDs. None of it is secret. Modules receive it as the `net` argument (`net.wireguard.meshIPs.server-nixos`), so addresses live in one place. Until 2026-10-09 it was git-crypt-encrypted as `secrets/network.nix`; that blocked CI and protected nothing.

### Using this flake for your own lab

Replace `hosts/network.nix` with your own hosts' values. For sops, generate your own `.sops.yaml` from your hosts' age keys:

```bash
nix-shell -p ssh-to-age --run 'cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age'
```

Then run `bash secrets/init-sops.sh` to collect and encrypt the WireGuard private keys. Edit them later with:

```bash
nix-shell -p sops age ssh-to-age --run 'sops secrets/secrets.yaml'
```

## System Management

```bash
# Rebuild current host
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)

# Deploy to all hosts (rebuild local, push, rebuild remotes via WireGuard SSH)
bash /etc/nixos/deploy.sh all

# Deploy to a specific remote host
bash /etc/nixos/deploy.sh server-nixos

# Validate without switching (no sudo)
nixos-rebuild build --flake /etc/nixos#$(hostname)

# Update flake inputs — never under sudo (root-owned files in /etc/nixos break git)
nix flake update --flake /etc/nixos

# Garbage collect
sudo nix-collect-garbage --delete-older-than 30d
```

## Design Decisions

- **ZFS on LUKS** (not ZFS native encryption): enables FIDO2 unlock via systemd-cryptenroll, full-pool encryption including metadata
- **Single flake, multi-host**: shared modules reduce duplication; host-specific config via imports and `mkForce` overrides
- **Stable + unstable overlay**: `nixos-26.05` base with `pkgs.unstable.<pkg>` for select packages
- **Filesystem-agnostic modules**: device paths and UUIDs live exclusively in `hardware-configuration.nix` (generated per-host by the installer)
- **MangoWM compositor + Noctalia shell**: Wayland desktop on all desktop hosts (greetd + tuigreet login, defaults to the Mango session)
- **Catppuccin Macchiato**: system-wide theming via Home Manager
- **WireGuard-only SSH**: `openFirewall = false` on SSH/Mosh services, port 22 opened only on `wg0` interface — no LAN SSH exposure
- **One secrets system**: sops-nix for private keys; addresses and public keys are plaintext in `hosts/network.nix` because they are not secret
- **CI evaluates, does not build**: every push evaluates all three systems and the installer ISO and runs the content guard; ROCm closures are too heavy for hosted runners
- **Inactive modules kept in tree**: some optional modules (e.g. `displaylink.nix`, `yubikey/`) are not imported by any host but kept for future use. They have zero impact on builds — add the import to a host's `default.nix` to activate

## Networking

IPs and keys are in `hosts/network.nix`. The network topology:

- **WireGuard mesh** (`wg0`): encrypted full-mesh between all hosts. All SSH and NFS access is restricted to this mesh.

| Host | WireGuard IP |
|------|-------------|
| `workstation-nixos` | 10.100.0.1 |
| `server-nixos` | 10.100.0.2 |
| `laptop-nixos` | 10.100.0.3 |
- **NordVPN** (`wgnord`): outbound VPN via wgnord on workstation-nixos and laptop-nixos
- **Syncthing**: file sync across all hosts (LAN-only, no relays). Syncs `~/.claude/`; the server is receive-only
- **NFS**: server exports `/storage` to the workstation only, over the WireGuard mesh (encrypted in transit)

## Security

- LUKS2 with argon2id key derivation on every host
- Disk unlock: workstation and laptop by passphrase or YubiKey FIDO2; the headless server
  by TPM2 (PCRs 0+7, passphrase slot kept as fallback). No Secure Boot yet, so the TPM
  binding is weaker than it looks — the boot-menu editor is off, but other boot media can
  still request the key
- sudo requires the password (60-min cache); NOPASSWD only for three read-only `lab-*` wrappers; listed services restart via polkit
- Server automation reaches other hosts as `lab-monitor` (journal access only), never as the user
- SSH restricted to WireGuard mesh: `openFirewall = false`, `ListenAddress` bound to each host's WireGuard IP, fail2ban on all hosts
- Firewall enabled on all hosts; admin services (SSH, Mosh, Ollama, AdGuard UI) restricted to `wg0` interface
- sops-nix for private keys; no other encrypted material in the repo
- Kernel hardening with loose rp_filter for WireGuard compatibility
- NordVPN via WireGuard (wgnord)

## AI Lab

A self-hosted, local-first AI stack running entirely on consumer AMD hardware over the
WireGuard mesh — LLMs, embeddings, and image generation, no cloud inference. The server
(Ryzen AI Max+ 395, `gfx1151` iGPU) runs the model tier; the workstation (RX 9070 XT,
`gfx1201`) is a dedicated image-generation render node.

Headline: a Mixture-of-Experts model (`qwen3:30b-a3b`) hits **~62 tok/s** on the
server's iGPU — faster than the 7B dense models while carrying 30B-class knowledge —
and FLUX.1-schnell generates a 1024×1024 image in **~6.7 s** warm on the workstation.

The lab also **self-monitors**: a nightly fleet-health + snapshot-freshness sentinel (same-pool ZFS snapshots — not off-host backups), a
post-rebuild verifier (server + laptop), a GPU-wedge sentinel (workstation), a SearXNG
search-sentinel (server, 08:15/20:15), and a weekly flake-update advisor —
all pushing to a private self-hosted ntfy hub (bridged into the desktops' notifications).
Claude Code drives it through a read-only host-health MCP server (fleet health, backups,
snapshots, flake status).

See **[docs/ai-lab.md](docs/ai-lab.md)** for the full model roster (with per-model
purpose/strengths), measured benchmarks, use cases, the monitoring/MCP layer, and the AMD
ROCm gotchas. Benchmark scripts are in [`ai-lab/bench/`](ai-lab/bench/).

## Claude Code Integration

This lab is administered primarily through [Claude Code](https://claude.com/claude-code), Anthropic's CLI agent. Claude handles configuration changes, audits, deployments, and cross-host operations via SSH over the WireGuard mesh.

### How it works

- **CLAUDE.md** provides project context (repo structure, conventions, host access map, secrets workflow). Loaded when Claude Code runs in `/etc/nixos`; it is NOT symlinked to `~/.claude/CLAUDE.md` (that is the vault's Project-Map.md).
- **Memory files** (`~/.claude/projects/`) persist knowledge across sessions — audit history, network topology, module patterns, known issues. Synced to all hosts via Syncthing so sessions can resume on any machine.
- **Deployments**: Claude commits and pushes. A switch needs oat's sudo password (60-min cache), so the person either opens that window or runs `deploy.sh` themselves; Claude can only deploy inside an open sudo window.
- **Audits**: Claude runs the checklist from `docs/audit/README.md` across all hosts in parallel, filters journal errors against `docs/audit/known-states.md`, and records findings in per-host audit docs.

### What Claude does vs doesn't do

| Claude drives | User handles |
|---|---|
| Edit config, commit, push | Approve tool calls when prompted |
| Deploy to all hosts via SSH (only within a sudo window) | Type the sudo password / run `deploy.sh` |
| | Physical access (YubiKey tap, cable check) |
| Run audit checklists | Router/DHCP configuration |
| Update docs and memory | Reboot hosts when needed |
| Diagnose service issues | Confirm destructive operations |

## License

[MIT](LICENSE)
