# System Audit Process

Repeatable audit procedure for all NixOS lab hosts.

## When to Audit

- After major configuration changes
- After flake input updates
- Monthly maintenance check
- When adding a new host

## Flake Input Updates

Update monthly to stay current with security patches:

**Never run git or `nix flake update` under `sudo`.** Both write into `/etc/nixos`, which is
owned by the user; running them as root leaves root-owned files that break every later
user-run git command. See [../deployment-issues.md](../deployment-issues.md) §"Git ownership
corruption from root-run pulls". Only `nixos-rebuild` needs sudo.

The canonical procedure lives in [../deployment.md](../deployment.md) §"Monthly flake update" —
kept there so there is one copy to keep correct:

```bash
cd /etc/nixos && nix flake update && git add flake.lock && git commit -m "flake: update inputs" && bash /etc/nixos/deploy.sh all
```

`flake.lock` must be **committed**, not just updated: flakes only see tracked files, so an
uncommitted lock builds locally and never reaches the other hosts. `deploy.sh all` runs a
pre-flight `nix eval` of every target before changing anything.

(Modern Nix reads positional arguments to `nix flake update` as *input names*, so the older
`nix flake update /etc/nixos` form tries to update an input called "/etc/nixos". Use `cd` or
`--flake`.)

Check input ages during audits:
```bash
nix flake metadata /etc/nixos 2>/dev/null | grep -A20 "Inputs:"
```

## Audit Checklist

Run on each host. Record results in the host's audit file (`docs/audit/<hostname>.md`).

### 1. Pre-flight

```bash
# Which host are we auditing?
hostname

# Current system generation
nixos-rebuild list-generations | tail -5

# Flake input ages
nix flake metadata /etc/nixos 2>/dev/null | grep -A20 "Inputs:"
```

### 2. Service Health

```bash
# Failed units
systemctl --failed
systemctl --user --failed

# Active timers (GC, logrotate, fstrim)
systemctl list-timers --all --no-pager
```

### 3. Journal Errors

Filter out known states (see `known-states.md`):
```bash
journalctl -p err -b --no-pager \
  | grep -v -E "split.lock|pulse|gkr-pam|MES|amdgpu|pidns|gtk_widget_get_scale" \
  | tail -40
```

### 4. Disk & Store

```bash
df -h
du -sh /nix/store
nix-env --list-generations --profile /nix/var/nix/profiles/system | wc -l
```

### 5. Hardware

```bash
sensors 2>/dev/null | head -30
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/class/drm/card*/device/power_dpm_force_performance_level 2>/dev/null
```

### 6. Network

```bash
# Interfaces
ip link show | grep -E "^[0-9]"

# DNS
resolvectl status 2>/dev/null | head -15

# Listening ports (NOPASSWD wrapper; plain ss -tlnp hides other users' processes)
sudo lab-listeners

# WireGuard mesh (needs the sudo password window)
sudo wg show wg0

# Syncthing status
systemctl is-active syncthing
```

### 7. Secrets

```bash
# sops-nix secrets decrypted
ls -la /run/secrets/

# WireGuard using sops-managed key
systemctl status wireguard-wg0.service | head -10
```

### 8. Firewall

```bash
# Verify SSH restricted to wg0
sudo lab-fw-dump | grep -E '22|wg0'

# Verify LAN SSH blocked (run from another host)
# nc -z -w 3 <LAN_IP> 22
```

### 9. Desktop State (desktop hosts only)

```bash
pgrep -a mango
pgrep -a noctalia
pgrep -a pipewire
```

### 10. Stale Files

```bash
# Broken symlinks in applications
find ~/.local/share/applications -xtype l 2>/dev/null

# Home Manager backup files
find ~ -name "*.hm_bak" -maxdepth 3 2>/dev/null

# Coredumps
coredumpctl list --no-pager 2>/dev/null | tail -10

# Stray `result` symlinks — these are GC ROOTS, so each one pins a whole system
# closure against nix.gc indefinitely. `nixos-rebuild build` leaves one behind by
# default. Expect none; delete any you find (they are regenerable).
ls -ld /etc/nixos/result ~/result 2>/dev/null
```

**Do not rely on the ownership check to catch these.** A `result` left by a *root-run*
build shows up as a non-`oat` file, but one left by a normal user build does not — the
tree still reads clean because `result` is gitignored. Both were found on 2026-08-16:
root-owned on laptop-nixos (from a root-run build during the module-autoload debugging)
and oat-owned on workstation-nixos, each pinning a stale closure. Check for the file
itself, not for who owns it.

Delete with `rm -f /etc/nixos/result` — this works even when the symlink is root-owned,
because removing it needs write permission on `/etc/nixos` (owned by the user), not on
the link.

### 11. Configuration

```bash
# Evaluate without building (catches syntax/type errors)
nix eval "/etc/nixos#nixosConfigurations.$(hostname).config.system.build.toplevel.drvPath"
```

### 12. Documentation matches the tree (repo-wide — run once, not per-host)

Docs and code comments drift as modules/services are renamed or removed. Verify the
repo still describes reality:

```bash
cd /etc/nixos

# a) Dangling path references — any repo path named in a comment or doc should exist
#    (skips <user>/<hostname> placeholders; gitignored dirs may legitimately be absent):
git grep -hoE '(hosts|home|ai-lab|docs|installer|secrets)/[A-Za-z0-9_./<>-]+\.(nix|md|py|sh|json)' \
  | sort -u | while read -r p; do
      case "$p" in *'<'*|*...*) continue;; esac   # skip placeholders + abbreviations
      [ -e "$p" ] || echo "MISSING: $p"
    done

# b) Structure-tree drift — list the real dirs/docs, then eyeball vs the README
#    "Repository Structure" block (anything new that isn't listed → add it):
ls -d hosts/common/optional/*/ home/common/optional/* ai-lab/*/ 2>/dev/null; ls docs/*.md

# c) Stale desktop/service names (extend the pattern as things are removed/renamed):
git grep -niE '\bniri\b|sillytavern|waybar|comfyui-ww' -- . | grep -v 'docs/audit/'
```

- Any `MISSING:` from (a) is a candidate broken reference — investigate each (a few are
  false positives: nixpkgs `modulesPath` imports, or absolute runtime paths like `/home/nixos/`).
- (b): every listed dir/doc should appear in the README tree.
- (c): matches outside dated audit history are stale references to clean up.
- Also confirm any orphan module (a `.nix` imported by no host) is listed under the
  README "Inactive modules kept in tree" note.

## Cross-Host Checks

After auditing individual hosts, verify connectivity and shared state:

```bash
# WireGuard mesh — full connectivity
ssh -o ConnectTimeout=5 <user>@10.100.0.1 "echo workstation OK"
ssh -o ConnectTimeout=5 <user>@10.100.0.2 "echo server OK"
ssh -o ConnectTimeout=5 <user>@10.100.0.3 "echo laptop OK"

# LAN SSH blocked on all hosts
nc -z -w 3 <server-lan-ip> 22 && echo "server LAN SSH OPEN" || echo "server LAN SSH blocked"
nc -z -w 3 <laptop-lan-ip> 22 && echo "laptop LAN SSH OPEN" || echo "laptop LAN SSH blocked"

# Syncthing connected (the REST API returns 403 without an API key)
syncthing cli show connections | grep -c '"connected": true'

# NFS over WireGuard (from workstation)
ls /mnt/server/ && echo "NFS OK" || echo "NFS FAIL"

# Repo hygiene, fleet-wide — expect owner=0 dirty=0 result=none on every host.
#   owner  — catches root-run git/nix (see ../deployment-issues.md)
#   dirty  — uncommitted edits that build locally but never reach the other hosts
#   result — GC roots pinning stale closures (see §10)
# Note the local-host branch: a host cannot ssh to itself (host key verification
# fails), so run the check directly there.
# Run from workstation-nixos or laptop-nixos (the server's oat key is authorized nowhere).
CHECK='printf "owner=%s dirty=%s result=%s\n" "$(find /etc/nixos -not -user "$(stat -c %U /etc/nixos)" | wc -l)" "$(git -C /etc/nixos status --porcelain | wc -l)" "$(ls /etc/nixos/result >/dev/null 2>&1 && echo PRESENT || echo none)"'
for h in workstation-nixos laptop-nixos server-nixos; do
  printf "%-18s " "$h"
  if [ "$h" = "$(hostname)" ]; then sh -c "$CHECK"; else ssh -n "$h" "$CHECK"; fi
done
```

Also verify shared modules:

- `hosts/common/core/` settings apply correctly to all hosts
- `hosts/common/optional/` modules don't have host-specific assumptions
- `home/common/optional/` works for all users/hosts
- No hardcoded paths (use `config.users.users.<name>.home`, etc.)

## Recording Results

Add findings to `docs/audit/<hostname>.md` under a dated heading:

```markdown
### YYYY-MM-DD — Audit Summary

**Status**: Healthy / Issues Found

**New Issues:**
| Issue | Severity | Resolution |
|-------|----------|------------|

**Resolved Since Last Audit:**
- ...
```

## Files

- `known-states.md` — Shared known states across all hosts (do not flag)
- `workstation.md` — workstation-nixos audit history and host-specific notes
- `laptop.md` — laptop-nixos audit history and host-specific notes
- `server.md` — server-nixos audit history and host-specific notes
