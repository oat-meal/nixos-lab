#!/usr/bin/env bash
# Deploy nixos-lab to all hosts
# Usage: deploy.sh [target...]
#   local              — rebuild this host (default)
#   server-nixos       — push + rebuild server
#   laptop-nixos       — push + rebuild laptop
#   workstation-nixos   — push + rebuild workstation
#   all                — rebuild local, push, rebuild all remotes
set -euo pipefail

FLAKE="/etc/nixos"
LOCAL=$(hostname)

confirm() {
  local msg="$1"
  echo ""
  echo "$msg"
  read -r -p "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

rebuild_local() {
  echo "==> Rebuilding $LOCAL"
  sudo nixos-rebuild switch --flake "$FLAKE#$LOCAL"
}

push_repo() {
  echo "==> Pushing to git"
  cd "$FLAKE"
  # No `git add -A` here. Staging on the user's behalf is what made the missing
  # commit invisible: the change looked handled, `git push` had nothing new to
  # send, and the remote rebuilt an identical closure. The clean-tree guard above
  # now catches this before anything is pushed, so staging here is both
  # unnecessary and actively misleading.
  git push
}

rebuild_remote() {
  local host="$1"
  echo "==> Rebuilding $host"
  # Run git as the login user (oat), NOT root: a root-run pull writes
  # root-owned objects/files into the oat-owned repo, which then breaks
  # subsequent user-run git on that host. Only nixos-rebuild needs sudo.
  # -t, not -n: since 2026-10-09 sudo asks for oat's password (security/sudo.nix),
  # and it needs a terminal to ask on. The confirm prompt for the next host is read
  # after this ssh returns, so giving ssh the terminal does not eat it. Not usable
  # piped or unattended — which is the point: a person owns each switch.
  #
  # Guards, in order:
  #  - non-oat-owned files in /etc/nixos (the tell-tale of a prior `sudo git`)
  #    would make the pull fail mid-deploy.
  #  - uncommitted changes on the REMOTE are silently built into its system, because
  #    a flake in a dirty git tree evaluates the working tree. Found 2026-10-09: the
  #    laptop carried an uncommitted hardening.nix edit from 2026-09-03 that would
  #    have gone live on the next deploy with no commit anywhere describing it.
  ssh -t "$host" "
    if [ -n \"\$(find /etc/nixos -xdev ! -user oat -print -quit 2>/dev/null)\" ]; then
      echo 'ERROR: /etc/nixos has non-oat-owned files (likely a prior sudo git).'
      echo 'Fix on $host:  sudo chown -R oat:users /etc/nixos'
      exit 1
    fi
    if [ -n \"\$(git -C /etc/nixos status --porcelain)\" ]; then
      echo 'ERROR: /etc/nixos on $host has uncommitted changes, which would be built in:'
      git -C /etc/nixos status --short
      echo 'Commit them (and push from there) or stash them, then deploy again.'
      exit 1
    fi
    git -C /etc/nixos pull --rebase && sudo nixos-rebuild switch --flake /etc/nixos#$host
  "
}

# No args = local
targets=("${@:-local}")

# Validate targets
valid_targets="local all server-nixos laptop-nixos workstation-nixos"
for target in "${targets[@]}"; do
  if [[ ! " $valid_targets " =~ " $target " ]]; then
    echo "Unknown target: $target"
    echo "Usage: deploy.sh [local|all|server-nixos|laptop-nixos|workstation-nixos]"
    exit 1
  fi
done

# Show plan and confirm
echo "Deploy plan:"
echo "  Host:    $LOCAL"
echo "  Targets: ${targets[*]}"
echo "  Flake:   $FLAKE"

cd "$FLAKE"
changes=$(git status --short 2>/dev/null)
if [[ -n "$changes" ]]; then
  echo ""
  echo "Uncommitted changes:"
  echo "$changes"
fi

# Pre-flight: verify all target configs evaluate
echo ""
echo "==> Pre-flight: evaluating flake configurations..."
eval_targets=()
for target in "${targets[@]}"; do
  case "$target" in
    local) eval_targets+=("$LOCAL") ;;
    all) eval_targets+=(workstation-nixos laptop-nixos server-nixos) ;;
    *) eval_targets+=("$target") ;;
  esac
done
# Deduplicate
eval_targets=($(printf '%s\n' "${eval_targets[@]}" | sort -u))
for host in "${eval_targets[@]}"; do
  if ! nix eval "$FLAKE#nixosConfigurations.$host.config.system.build.toplevel.drvPath" >/dev/null 2>&1; then
    echo "FAIL: $host config does not evaluate cleanly"
    nix eval "$FLAKE#nixosConfigurations.$host.config.system.build.toplevel.drvPath" 2>&1 | tail -5
    exit 1
  fi
  echo "  $host: OK"
done

# A dirty tree is fine locally and silently useless remotely, so the guard is
# scoped to remote targets only.
#
# Local rebuilds pass --flake "$FLAKE#$LOCAL", which reads the working tree, so
# uncommitted edits apply. Remote rebuilds go through git: push_repo pushes, the
# host pulls, and nixos-rebuild runs against whatever landed there. Anything not
# committed never leaves this machine.
#
# Before this guard that failed silently and expensively: the deploy reported
# success, the host rebuilt an identical closure, no generation was created, and
# nothing changed — with the plan above having already listed the very changes it
# was about to not deploy. Cost two reboots on 2026-08-24 to notice.
remote_targets=()
for host in "${eval_targets[@]}"; do
  [[ "$host" != "$LOCAL" ]] && remote_targets+=("$host")
done

if [[ -n "$changes" && ${#remote_targets[@]} -gt 0 ]]; then
  echo ""
  echo "ERROR: uncommitted changes, but ${remote_targets[*]} deploy(s) via git."
  echo "Those changes would NOT reach the remote host, and the deploy would"
  echo "report success having changed nothing. Commit first:"
  echo ""
  echo "  git -C $FLAKE commit -am '<what changed>'"
  echo ""
  exit 1
fi

confirm "Proceed with deployment?"

for target in "${targets[@]}"; do
  case "$target" in
    local)
      rebuild_local
      ;;
    all)
      rebuild_local
      push_repo
      for remote in server-nixos laptop-nixos workstation-nixos; do
        [ "$remote" = "$LOCAL" ] && continue
        confirm "Rebuild $remote?"
        rebuild_remote "$remote"
      done
      ;;
    server-nixos|laptop-nixos|workstation-nixos)
      if [ "$target" = "$LOCAL" ]; then
        rebuild_local
      else
        push_repo
        rebuild_remote "$target"
      fi
      ;;
    *)
      echo "Unknown target: $target"
      echo "Usage: deploy.sh [local|all|server-nixos|laptop-nixos|workstation-nixos]"
      exit 1
      ;;
  esac
done
