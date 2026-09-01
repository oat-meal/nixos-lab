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
- **Secrets**: `secrets/network.nix` encrypted via git-crypt (see Secrets section)

## What belongs in this repo (infra vs content)

This repo is **PUBLIC and infrastructure-only**: the recipe to rebuild the lab, not its
contents. The test: *if I rebuilt on bare hardware from this flake, what should reappear
automatically vs. what would I restore from on-prem backup?*

- **Belongs here (infrastructure):** all `*.nix`, `flake.nix`, host/module configs, and the
  tool **code** Nix builds (`ai-lab/{quorum,rag,research}/*.py`, `ai-lab/api/server.py`,
  `ai-lab/mcp/.../server.py`, `ai-lab/eliteintel/package.nix`, `ai-lab/comfyui/Containerfile`,
  `ai-lab/lora-training/` toolkit). No secrets (git-crypt/sops handle those), no personal data.
- **Does NOT belong here (content/data → private, on-prem):** ComfyUI workflow JSONs
  (`ai-lab/comfyui/workflows/`), prompts/personas, generated images, model weights, RAG
  corpora, Open WebUI databases, the LoRA dataset, the Obsidian vault. These live on `/storage` (ZFS-snapshotted), service data
  dirs, or the on-prem **private** git — never GitHub:
  - `server:/storage/git/lab-content.git` — cards, ComfyUI workflows, prompts (clone: `~/Documents/lab-content`)
  - `server:/storage/git/ai-lab-vault.git` — Obsidian system-docs vault (clone: `~/Documents/ai-lab-vault`)

Enforced by `.gitignore` + a tracked pre-commit hook (`.githooks/pre-commit`). The hook is
NOT auto-active per clone — enable it once after cloning: `git config core.hooksPath .githooks`
(see "Unlocking git-crypt after a fresh clone"). Override for a genuine infra file with
`git commit --no-verify`.

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

secrets/
├── network.nix        # IPs, public keys, device IDs (git-crypt, build-time)
├── network.nix.example # Template with placeholders
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

### Local rebuild

```bash
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)
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
ssh server-nixos "sudo git -C /etc/nixos -c core.sshCommand='ssh -i /home/<user>/.ssh/id_ed25519 -o IdentitiesOnly=yes' pull --rebase && sudo nixos-rebuild switch --flake /etc/nixos#server-nixos"
```

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

Two layers:

- **git-crypt** (build-time): `secrets/network.nix` — IPs, public keys, device IDs. Plaintext in working tree, encrypted in git. Imported by Nix modules at evaluation.
- **sops-nix** (runtime): `secrets/secrets.yaml` — WireGuard private keys. Encrypted via age, decrypted to `/run/secrets/` at system activation. Age keys derived from SSH host keys (`/etc/ssh/ssh_host_ed25519_key`).

### Committing changes to git-crypt files

```bash
nix-shell -p git-crypt --run 'git add -A && git commit -m "message"'
```

### Editing sops secrets

```bash
nix-shell -p sops age ssh-to-age --run 'sops secrets/secrets.yaml'
```

### Unlocking git-crypt after a fresh clone

```bash
git-crypt unlock ~/.config/git-crypt/nixos-lab.key
```

The git-crypt key is synced to all hosts via Syncthing (`~/.config/git-crypt/`). sops-nix uses SSH host keys automatically.

## Troubleshooting

### Build fails with "access to absolute path forbidden"
Flake pure evaluation blocks absolute paths. All imports must be relative. Secrets must be tracked in git (git-crypt handles encryption).

### WireGuard handshake not completing
Check `rp_filter` — Linux uses `max(all, interface)`. Both `net.ipv4.conf.all.rp_filter` and `net.ipv4.conf.wg0.rp_filter` must be `2` (loose). The wireguard.nix module handles this with `lib.mkForce`.

### Service not restarting after rebuild
Some services (WireGuard, Syncthing) need manual restart: `sudo systemctl restart wireguard-wg0.service`

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
- **Passwordless sudo**: All hosts have scoped NOPASSWD for nixos-rebuild, nix*, systemctl, git, zfs, zpool

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
