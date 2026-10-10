# NixOS Primer

A brief introduction to NixOS concepts and how this repository is structured. For project-specific reference, see the [README](../README.md).

## The Core Idea

NixOS is a Linux distribution where the entire system is defined in configuration files. Instead of installing packages and editing configs imperatively (`apt install`, `vim /etc/sshd_config`), you declare what you want and rebuild. The system matches your declaration exactly — nothing more, nothing less.

```
edit .nix files → nixos-rebuild switch → new system generation
```

Every rebuild creates a new **generation**. Old generations stay on disk until garbage collected, so you can always roll back from the bootloader if something breaks.

## Nix Language Basics

Nix files (`.nix`) use a functional language. The key constructs:

```nix
# Attribute set (like a dictionary/object)
{ key = "value"; nested.key = true; }

# Function (single argument, usually a destructured set)
{ pkgs, lib, config, ... }:
{
  # module body — returns an attribute set
  services.openssh.enable = true;
}

# List
[ "item1" "item2" ]

# Let binding (local variables)
let
  myVar = "hello";
in
{
  environment.etc."greeting".text = myVar;
}

# Import (evaluate another .nix file)
imports = [ ./other-file.nix ];
```

Every NixOS module is a function that takes `{ config, pkgs, lib, ... }` and returns an attribute set of system options. NixOS merges all modules together — if two modules both set `environment.systemPackages`, the lists get combined.

## Flakes

A **flake** is a self-contained Nix project with pinned dependencies. A `flake.nix` has two parts:

### Inputs — where packages come from

```
nixpkgs          → the package repository (like apt sources)
nixpkgs-unstable → bleeding-edge packages (used selectively via overlay)
home-manager     → manages user-level dotfiles and configs
mango            → the MangoWM Wayland compositor
noctalia         → the Noctalia desktop shell
zen-browser      → the Zen browser
sops-nix         → secrets management
```

`flake.lock` pins each input to an exact git commit. Running `nix flake update` bumps them to the latest.

### Outputs — what the flake produces

```
nixosConfigurations.workstation-nixos  → full system config
nixosConfigurations.laptop-nixos       → full system config
nixosConfigurations.server-nixos       → full system config
packages.installer-iso                 → custom install ISO
```

When you run `nixos-rebuild switch --flake .#laptop-nixos`, Nix evaluates that output and builds the system.

## How This Repository Builds Hosts

The `flake.nix` has a `mkSystem` helper that wires up each host:

```
mkSystem { hostname, hostPath, enableDesktop, enableHomeManager }
         │
         ├── hostPath (e.g. hosts/laptop/default.nix)
         ├── sops-nix module (runtime secrets)
         ├── overlays (unstable packages, zen-browser)
         ├── mango + noctalia modules (desktop hosts only)
         └── home-manager (desktop hosts only)
             └── home/oat/default.nix
```

The server has `enableDesktop = false` and `enableHomeManager = false` — no GUI, no user-level config management.

## Module Layers

Configuration is organized in three layers:

```
┌─────────────────────────────────────────────┐
│  hosts/<hostname>/default.nix               │  Host-specific: kernel params,
│                                             │  services, hardware, firewall
├─────────────────────────────────────────────┤
│  hosts/common/core/                         │  Required on ALL hosts: boot,
│  (boot, locale, networking, nix, packages,  │  locale, networking, nix settings,
│   shell, users)                             │  shell, users
├─────────────────────────────────────────────┤
│  hosts/common/optional/                     │  Mix-in modules: each host imports
│  (desktop, gaming, hardware, networking,    │  only what it needs. Server skips
│   power, security, storage)                 │  desktop and gaming entirely.
└─────────────────────────────────────────────┘
```

**Core** modules are imported as a directory (`../common/core` evaluates `default.nix`, which imports all 7 sub-modules). Every host gets them automatically.

**Optional** modules are imported individually per host. For example, only the laptop imports `framework.nix` and `portable.nix`; only the workstation imports `performance.nix`.

## System-Level vs Home Manager

| | System (`hosts/`) | Home Manager (`home/`) |
|---|---|---|
| Scope | Entire machine | Single user |
| Manages | Services, kernel, hardware, firewall, system packages | Dotfiles, user apps, shell config, themes |
| Runs as | root | user |
| Examples | `services.openssh.enable`, `networking.firewall` | `programs.alacritty.settings`, `xdg.mimeApps` |

Home Manager is embedded in the NixOS rebuild via the flake config. When you rebuild, both system and user configs update atomically as a single generation.

## Option Merging and Priority

When multiple modules set the same option, NixOS merges them:

```nix
# Module A
environment.systemPackages = [ pkgs.git ];

# Module B
environment.systemPackages = [ pkgs.vim ];

# Result: both git and vim are installed (lists are concatenated)
```

For scalar values (strings, booleans — not lists), the last definition wins. You control priority with:

```nix
lib.mkDefault "value"    # low priority — easily overridden by any host
"value"                  # normal priority
lib.mkForce "value"      # high priority — wins over everything
lib.mkAfter [ ... ]      # append after other definitions (for ordered lists)
```

This is how shared modules work: `sudo.nix` sets base rules at normal priority, and the server uses `lib.mkAfter` to add its own commands without replacing the base rules.

## Overlays

Overlays modify the package set. This repo uses two:

```nix
# Makes pkgs.unstable.<package> available (e.g. pkgs.unstable.discord)
unstableOverlay = final: prev: {
  unstable = import nixpkgs-unstable { ... };
};

# Makes pkgs.zen-browser available
(final: prev: { zen-browser = zen-browser.packages.${system}.default; })
```

This lets you use stable nixpkgs for the system base while pulling specific packages from the unstable channel.

## Secrets

| | `hosts/network.nix` | `secrets/secrets.yaml` (sops-nix) |
|---|---|---|
| Contains | IPs, public keys, device IDs | WireGuard private keys |
| Protection | None — plaintext and public on purpose; nothing in it is secret | age, per-host SSH host keys |
| Available when | Nix evaluates the config (the `net` module argument) | System activates at boot |
| On disk | The working tree | `/run/secrets/` (tmpfs) |

Until 2026-10-09 the left column was `secrets/network.nix` under git-crypt. It protected
nothing (the addresses were public elsewhere) and stopped CI from evaluating the flake.

## The Rebuild Cycle

```
1. Edit .nix files
2. nix eval .#nixosConfigurations.<host>...   (optional: syntax/type check)
3. sudo nixos-rebuild switch --flake .#<hostname>
4. Nix evaluates all modules → builds derivations → activates new generation
5. Services restart as needed, new packages appear in PATH
```

If something breaks, reboot and select the previous generation from the boot menu. The old system is still there until you garbage collect it.

## Key Commands

```bash
# Rebuild the current host
sudo nixos-rebuild switch --flake /etc/nixos#$(hostname)

# Check config for errors without building
nix eval "/etc/nixos#nixosConfigurations.$(hostname).config.system.build.toplevel.drvPath"

# Update all flake inputs to latest
nix flake update

# List system generations
nixos-rebuild list-generations

# Roll back to previous generation
sudo nixos-rebuild switch --rollback

# Remove old generations and free disk space
sudo nix-collect-garbage --delete-older-than 30d
```
