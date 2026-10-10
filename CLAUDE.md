# NixOS Lab — Claude Code Context

## Host Detection

Run `hostname` at conversation start to determine context.

| Hostname | Host Doc | Purpose |
|----------|----------|---------|
| `workstation-nixos` | `docs/audit/workstation.md` | Gaming workstation |
| `laptop-nixos` | `docs/audit/laptop.md` | Framework 13 laptop |
| `server-nixos` | `docs/audit/server.md` | Home server |

## Repository

- **Location**: `/etc/nixos/`
- **Remote**: `git@github.com:oat-meal/nixos-lab.git` (SSH)
- **Type**: Nix Flakes with Home Manager
- **Channel**: nixpkgs-25.11 stable, selective unstable overlay (`pkgs.unstable.<pkg>`)
- **Secrets**: sops-nix only (`secrets/secrets.yaml`); `hosts/network.nix` is plaintext by design (see Secrets section)
- **CI**: GitHub Actions evaluates all three systems + the ISO and runs the content guard on every push

## What belongs in this repo (infra vs content)

This repo is **PUBLIC and infrastructure-only**: the recipe to rebuild the lab, not its
contents. The test: *if I rebuilt on bare hardware from this flake, what should reappear
automatically vs. what would I restore from on-prem backup?*

- **Belongs here (infrastructure):** all `*.nix`, `flake.nix`, host/module configs, and the
  tool **code** Nix builds (`ai-lab/{quorum,rag,research}/*.py`, `ai-lab/api/server.py`,
  `ai-lab/mcp/.../server.py`, `ai-lab/eliteintel/package.nix`, `ai-lab/comfyui/Containerfile`,
  `ai-lab/lora-training/` toolkit). No secrets (sops handles those), no personal data.
- **Does NOT belong here (content/data → private, on-prem):** ComfyUI workflow JSONs
  (`ai-lab/comfyui/workflows/`), prompts/personas, generated images, model weights, RAG
  corpora, Open WebUI databases, the LoRA dataset, the Obsidian vault. These live on `/storage` (ZFS-snapshotted), service data
  dirs, or the on-prem **private** git — never GitHub:
  - `server:/storage/git/lab-content.git` — cards, ComfyUI workflows, prompts (clone: `~/Documents/lab-content`)
  - `server:/storage/git/ai-lab-vault.git` — Obsidian system-docs vault (clone: `~/Documents/ai-lab-vault`)

Enforced by `.gitignore`, a tracked pre-commit hook (`.githooks/pre-commit`), and CI, which
runs the same hook with `--all` over every tracked file on each push. The local hook is NOT
auto-active per clone — enable it once: `git config core.hooksPath .githooks`. Override for a
genuine infra file with `git commit --no-verify` (CI will still flag it).

## Structure

```
hosts/
├── common/
│   ├── core/          # Required on ALL hosts (boot, locale, networking, nix, packages, shell, users)
│   └── optional/      # Mix-in modules: ai/, desktop/, gaming/, hardware/, monitoring/,
│                      #   networking/, power/, security/, storage/
├── workstation/       # Gaming workstation config
├── laptop/            # Framework 13 config
├── server/            # Home server

home/
├── <user>/               # User-specific Home Manager config
└── common/optional/   # Shared HM modules (desktop/, security/, user-packages.nix, theme.nix)

hosts/network.nix      # IPs, public keys, device IDs — plaintext data, passed to modules as `net`

secrets/
├── secrets.yaml       # WireGuard private keys (sops-nix, runtime)
└── init-sops.sh       # Helper to collect and encrypt WireGuard keys

installer/             # Custom installer ISO

docs/
├── deployment.md            # Canonical change→deploy cycle (deploy.sh, monthly flake update)
├── deployment-issues.md     # Past failures + fixes (incl. root-run git corruption)
├── kernel-module-autoload.md # systemd-initrd switch_root bug (hit laptop + server)
├── portal-filechooser.md    # xdg-desktop-portal: FileChooser + AppChooser/PATH failures
├── ai-lab.md                # Models, benchmarks, serving stack, observability
├── nixos-primer.md          # Nix language / NixOS concepts
├── NORDVPN-SETUP.md         # wgnord setup guide (setup incomplete — see the doc)
└── audit/
    ├── README.md            # Audit procedure
    ├── known-states.md      # Expected anomalies — CHECK BEFORE FILING A FINDING
    ├── workstation.md / laptop.md / server.md   # Per-host audit docs
    └── postmortem-2026-08-wcn7850-wifi.md       # WiFi outage postmortem + action items
```

## Deployment

### Privilege (since 2026-10-09 — see `hosts/common/optional/security/sudo.nix`)

**sudo needs oat's password.** It is cached for 60 minutes across every terminal
(`timestamp_type=global`), so an agent session can sudo only inside a window the
person opened by typing it. Check with `sudo -n true` — if it fails, ASK; do not
look for another route to root. The old NOPASSWD list (nixos-rebuild, nix*,
systemctl, git, podman, zfs, zpool, iptables/nft, ss, udevadm) is gone.

Needs no sudo at all: `journalctl` (systemd-journal group), `systemctl status/show`,
`zpool status`, `zfs list`, `nixos-rebuild build`, `nix build`, and
`systemctl start|stop|restart <unit>` for the units in the host's
`lab.restartableUnits` (polkit).

Passwordless, read-only wrappers: `sudo lab-fw-dump` (nft + iptables rulesets),
`sudo lab-listeners` (`ss -tulpn` with owning processes),
`sudo lab-podman-probe ps|images|inspect C|logs C|has-py C MODULE`.

### Local rebuild

```bash
nixos-rebuild build --flake /etc/nixos#$(hostname)          # no sudo; validates
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)    # password (cached 60 min)
```

### Deploy script

```bash
# Local only (default)
bash /etc/nixos/deploy.sh

# Specific remote host
bash /etc/nixos/deploy.sh server-nixos

# All hosts (local + push + rebuild remotes)
bash /etc/nixos/deploy.sh all
```

### Manual remote rebuild

```bash
ssh -t server-nixos "git -C /etc/nixos pull --rebase && sudo nixos-rebuild switch --flake /etc/nixos#server-nixos"
```

`-t` because sudo asks for the password. Never `sudo git` — it leaves root-owned
files in `/etc/nixos` that break the next pull (`deploy.sh` refuses to run if it
finds any).

## Host Access Map

```
workstation-nixos (10.100.0.1) ──SSH/wg0──> server-nixos  (10.100.0.2)
workstation-nixos (10.100.0.1) ──SSH/wg0──> laptop-nixos  (10.100.0.3)
laptop-nixos      (10.100.0.3) ──SSH/wg0──> server-nixos  (10.100.0.2)
laptop-nixos      (10.100.0.3) ──SSH/wg0──> workstation-nixos (10.100.0.1)
server-nixos      (10.100.0.2) ──SSH/wg0──> workstation-nixos (10.100.0.1)
server-nixos      (10.100.0.2) ──SSH/wg0──> laptop-nixos  (10.100.0.3)
```

All SSH access is restricted to WireGuard mesh (`wg0`, 10.100.0.0/24). Syncthing syncs over LAN.

## Secrets

One system — **sops-nix**: `secrets/secrets.yaml` holds the WireGuard private keys, encrypted via age and decrypted to `/run/secrets/` at activation. Age keys derive from SSH host keys (`/etc/ssh/ssh_host_ed25519_key`).

**`hosts/network.nix` is plaintext and public on purpose** (since 2026-10-09; it was git-crypt'd as `secrets/network.nix`): usernames, LAN/mesh IPs, public keys, Syncthing IDs. Modules receive it as the `net` argument — write `net.wireguard.meshIPs.server-nixos`, never a literal `10.100.0.x`. Anything that would be dangerous to publish goes in sops, never here.

### Editing sops secrets

```bash
nix-shell -p sops age ssh-to-age --run 'sops secrets/secrets.yaml'
```

A fresh clone needs no key to evaluate — CI (`.github/workflows/check.yml`) proves it on every push. sops-nix uses SSH host keys automatically. The old git-crypt key stays in `~/.config/git-crypt/` only to read `network.nix` in history before `cdd0d69`.

## Troubleshooting

### Build fails with "access to absolute path forbidden"
Flake pure evaluation blocks absolute paths. All imports must be relative, and files must be tracked (`git add`) — flakes ignore untracked files.

### WireGuard handshake not completing
Check `rp_filter` — Linux uses `max(all, interface)`. Both `net.ipv4.conf.all.rp_filter` and `net.ipv4.conf.wg0.rp_filter` must be `2` (loose). The wireguard.nix module handles this with `lib.mkForce`.

### Service not restarting after rebuild
Some services (WireGuard, Syncthing) need manual restart: `systemctl restart wireguard-wg0.service` (no sudo — it is in every host's `lab.restartableUnits`)

### Firewall interface patterns
NixOS firewall defaults to iptables backend (unless `networking.nftables.enable = true`). In iptables, `+` is the wildcard suffix; in nftables, `*` is. The NixOS `interfaces` option passes the key directly to the backend. WireGuard interface `wg0` must be listed explicitly if SSH should be reachable over the mesh.

## Key Conventions

- **Module priority**: `lib.mkDefault` for common defaults, `lib.mkForce` for host overrides
- **Unstable packages**: `pkgs.unstable.<package>` (overlay in flake.nix).
  ⚠️ **ONLY FOR STANDALONE BINARIES.** It works for `ollama-rocm` and `sunshine`
  because those are programs; it does **not** transfer to a module that builds
  its own language environment, where the package and the interpreter must come
  from the same nixpkgs.

  Measured 2026-08-31: `services.searx.package = pkgs.unstable.searxng` took the
  service **completely down** — HTTP 500 on every route including the root page.
  The module builds uwsgi's interpreter from the stable `python3` (3.13) and the
  unstable package is built against 3.14, so `searx` landed in a site-packages
  tree the vassal's PythonHome never sees; the env contained 0 entries matching
  it. Journal: `ModuleNotFoundError: No module named 'searx'` then `no app
  loaded. going in full dynamic mode` — and **uwsgi stayed `active` throughout**,
  serving 500s while systemd called it healthy.

  Wanting a newer version of a module's package means moving the whole module to
  unstable, not swapping one package underneath a stable one. **The precedent is
  not the mechanism: check that the analogy holds before copying it.**

  Pre-deploy check that would have caught it, and now the standard one for any
  package override on a Python/Node module — read the built closure, not the
  exit code:

      # the module's interpreter env must actually contain the module
      ls <pyhome>/lib/python*/site-packages/ | grep -c '^searx$'
- **Desktop**: MangoWM Wayland compositor + Noctalia shell
- **Theme**: Catppuccin Macchiato system-wide
- **Browser**: Zen Browser
- **Shell**: Zsh with Oh-My-Zsh
- **User**: Single user `<user>` with Home Manager
- **sudo**: password, cached 60 min globally; NOPASSWD only for the read-only `lab-*` wrappers (see Privilege above)
- **Remote probes**: fleet-sentinel and host-health MCP log in to workstation/laptop as `lab-monitor` (journal group only) with `~/.ssh/lab_monitor` on the server; the server's oat key is not authorized anywhere

## Documentation Style

- Factual, specification-focused language
- Replace "optimized/tuned/enhanced" with "configured/specified/set"
- State technical specifications, not performance promises
- Always provide single-line commands for copy/paste (no unnecessary line breaks)

## Symlink Setup

This file lives in the repo and should be symlinked on each host:

```bash
ln -sf /etc/nixos/CLAUDE.md ~/.claude/CLAUDE.md
```
