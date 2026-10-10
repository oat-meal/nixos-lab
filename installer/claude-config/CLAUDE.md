# NixOS Lab — Claude Code Context

## Host Detection

**On every new conversation**, run `hostname` to determine which host you're on, then load the appropriate host documentation:

| Hostname | Host Doc | Purpose |
|----------|----------|---------|
| `workstation-nixos` | `docs/audit/workstation.md` | Gaming workstation |
| `laptop-nixos` | `docs/audit/laptop.md` | Framework 13 laptop |
| `server-nixos` | `docs/audit/server.md` | Home server |

Read the host doc for hardware specs, known states, and audit history before making changes.

## Repository

- **Location**: `/etc/nixos/`
- **Remote**: `git@github.com:oat-meal/nixos-lab.git` (SSH)
- **Type**: Nix Flakes with Home Manager
- **Channel**: nixpkgs nixos-26.05 stable (home-manager release-26.05), selective unstable overlay (`pkgs.unstable.<pkg>`); claude-code from its own pinned `nixpkgs-claude` input

## Structure

```
hosts/
├── common/
│   ├── core/          # Required on ALL hosts (boot, locale, networking, nix, packages, shell, users)
│   └── optional/      # Mix-in modules (ai/, desktop/, dev/, gaming/, hardware/, monitoring/, networking/, power/, security/, storage/)
├── workstation/       # Gaming workstation config
├── laptop/            # Framework 13 config
├── server/            # Home server

home/
├── <user>/               # User-specific Home Manager config
└── common/optional/   # Shared HM modules (desktop/, user-packages.nix, theme.nix)

docs/
├── ai-lab.md          # Self-hosted AI stack: models, benchmarks, notes
├── deployment.md      # Change→deploy cycle (deploy.sh, monthly flake update)
├── deployment-issues.md # Past deploy failures + fixes
├── kernel-module-autoload.md # systemd-initrd switch_root bug
├── portal-filechooser.md # xdg-desktop-portal failures
├── searxng-engines-degraded.md # SearXNG web engines disabled; API engines only
├── nixos-primer.md    # Intro to this flake for NixOS newcomers
├── audit/             # Per-host audit framework
│   ├── README.md      # Audit checklist
│   ├── known-states.md # Expected anomalies (do not flag)
│   ├── workstation.md # Workstation hardware, audit history
│   ├── laptop.md      # Laptop hardware, audit history
│   └── server.md      # Server hardware, audit history
└── NORDVPN-SETUP.md   # wgnord VPN guide
```

## Common Commands

```bash
# Rebuild (replace <hostname> with output of `hostname`)
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)

# Dry run
sudo nixos-rebuild dry-activate --flake /etc/nixos#$(hostname)

# Update inputs
nix flake update --flake /etc/nixos

# Garbage collect
sudo nix-collect-garbage --delete-older-than 30d
```

## Multi-Host Workflow

This repo is shared across machines. Before editing:

```bash
git -C /etc/nixos pull --rebase
```

After committing:

```bash
git -C /etc/nixos push
```

Never run git as root (`sudo git`) — it leaves root-owned objects in `.git`
(see `docs/deployment-issues.md`).

On the other machine, pull before rebuilding.

## Audit Process

When performing a system audit, follow `docs/audit/README.md`. Check `docs/audit/known-states.md` before flagging issues — many apparent anomalies are documented and expected.

Record audit results in the host's doc file (`docs/audit/<host>.md`).

## Key Conventions

- **Module priority**: Use `lib.mkDefault` for common defaults, `lib.mkForce` for host overrides
- **Unstable packages**: Access via `pkgs.unstable.<package>` (overlay defined in flake.nix)
- **Desktop**: MangoWM Wayland compositor + Noctalia shell on all desktop hosts
- **Theme**: Catppuccin Macchiato system-wide
- **Browser**: Zen Browser (sole browser)
- **Shell**: Zsh with Oh-My-Zsh
- **User**: Single user `<user>` with Home Manager

## Documentation Style

- Use factual, specification-focused language
- Replace "optimized/tuned/enhanced" with "configured/specified/set"
- State technical specifications, not performance promises
- Repo docs are the source of truth; Obsidian links back to them

## Where this file is loaded

The ISO links /etc/claude/CLAUDE.md into ~/.claude automatically. On installed hosts, the
repo's own `/etc/nixos/CLAUDE.md` is project context, loaded when Claude Code runs in
/etc/nixos. Do NOT symlink it to `~/.claude/CLAUDE.md` — that is the vault's Project-Map.md.
