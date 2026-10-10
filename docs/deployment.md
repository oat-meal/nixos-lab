# Deployment

How to keep all hosts current and in sync. See [deployment-issues.md](deployment-issues.md) for past problems and fixes.

> Placeholders: `<user>` is your login user (the repo is owned by it, not root).
> Hostnames below (`workstation-nixos`, `laptop-nixos`, `server-nixos`) are
> examples — substitute your own. Replace them throughout your own config.

## Principle

`origin/main` is the single source of truth. Every host converges by pulling
from it. Hosts only stay in sync if changes are **committed and pushed** —
local edits that are not committed build on the local host but never reach the
others. Git runs as `<user>`; only `nixos-rebuild` uses sudo.

## Standard change → deploy cycle

1. **Edit** on any host.
2. **Commit** — required, because Nix flakes only see tracked/committed files
   and `git push` only sends commits. Stage explicit paths, not `-A` — parallel
   sessions edit this repo too:
   ```sh
   cd /etc/nixos && git add <paths> && git commit -m "describe change"
   ```
3. **Deploy to all hosts:**
   ```sh
   bash /etc/nixos/deploy.sh all
   ```
   In order, this runs:
   - **Pre-flight:** `nix eval` of every target config — aborts before
     changing anything if a host does not evaluate.
   - **Rebuild local** from the committed git tree.
   - **Push** to `origin/main`.
   - **Per remote:** `git pull --rebase` (as `<user>`) → `sudo nixos-rebuild
     switch`, each gated by a `[y/N]` confirm.

## Variations

- **One host:** `bash /etc/nixos/deploy.sh server-nixos` (push, then
  pull + rebuild that host only).
- **This host only:** `bash /etc/nixos/deploy.sh local` (or no arguments).
- **Monthly flake update:**
  ```sh
  cd /etc/nixos && nix flake update && git add flake.lock && git commit -m "flake: update inputs" && bash /etc/nixos/deploy.sh all
  ```

## Staying in sync / avoiding drift

- **Always deploy through `deploy.sh`.** Never `sudo git pull` by hand — running
  git as root writes root-owned files into the `<user>`-owned repo and breaks
  later user-run git (see [deployment-issues.md](deployment-issues.md)).
- **Prefer `all`** for changes that should be uniform, so hosts land on the
  same commit and generation together.
- **Offline host during `all`:** the deploy aborts at that host (`set -euo pipefail`)
  and later hosts are not attempted. Re-run `deploy.sh <hostname>` for each host
  not yet converged.
- **Reboot when needed:** `switch` applies most changes live, but kernel,
  initrd, and bootloader changes only take effect after a reboot.

## Verify hosts are in sync

```sh
# Same commit everywhere?
for h in workstation-nixos laptop-nixos server-nixos; do printf "%-18s " "$h"; ssh -n "$h" 'git -C /etc/nixos rev-parse --short HEAD'; done

# Same (new) system generation?
for h in workstation-nixos laptop-nixos server-nixos; do printf "%-18s " "$h"; ssh -n "$h" 'readlink /run/current-system'; done

# Repo ownership clean (expect 0)?
for h in workstation-nixos laptop-nixos server-nixos; do printf "%-18s " "$h"; ssh -n "$h" 'find /etc/nixos -not -user <user> | wc -l'; done
```

All HEADs equal → repos in sync. All on the new `…-nixos-system…` generation →
configs applied. All `0` → ownership clean.
