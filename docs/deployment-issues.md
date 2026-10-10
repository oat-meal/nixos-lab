# Deployment Issues & Lessons Learned

## Git ownership corruption from root-run pulls (2026-06-04)

### Symptom

User-run `git fetch`/`push` in `/etc/nixos` fails:

```
error: insufficient permission for adding an object to repository database .git/objects
fatal: failed to write object
```

Inspection found root-owned objects in `.git/objects` plus root-owned
working-tree files and a root-owned subdirectory, in an otherwise
<user>-owned repo.

### Root cause

`deploy.sh` ran the remote update as root:

```sh
ssh "$host" "sudo git -C /etc/nixos pull --rebase && sudo nixos-rebuild switch ..."
```

Running `git` as root writes root-owned objects and checks out root-owned
files into the <user>-owned repo. The next user-run git command cannot write
into those paths. With three meshed hosts pulling on each deploy, the
corruption recurred regularly.

### Fix

- `deploy.sh` now runs `git pull` as the login user (<user>); only
  `nixos-rebuild` uses sudo. <user>'s default `~/.ssh/id_ed25519` provides
  GitHub auth, so the earlier `core.sshCommand` key override (added
  because root lacked the key) was removed.
- `rebuild_remote` used `ssh -n` so ssh did not consume the script's
  stdin (the confirm prompts) when the loop iterated over multiple hosts; since
  2026-10-09 it uses `ssh -t` (sudo prompts for the password).

### One-time cleanup

Repair ownership already on disk across all hosts:

```sh
for h in workstation-nixos laptop-nixos server-nixos; do ssh -t "$h" 'sudo chown -R <user>:users /etc/nixos'; done
```

Verify a host is clean:

```sh
find /etc/nixos -not -user <user> | wc -l   # expect 0
```

## Server Deploy (2026-06-02)

Issues encountered deploying the flake from workstation to server via thumb drive:

1. **hardware-configuration.nix not generated** — copying the flake from another host does not include the target's hardware config. Run `nixos-generate-config --show-hardware-config` on the target.
2. **Redirect permission denied** — `sudo command > file` runs the redirect as the user, not root. Use `sudo command | sudo tee file > /dev/null`.
3. **Flake only saw tracked files** — Nix flakes ignore untracked files. New/modified files must be `git add`ed before `nixos-rebuild` sees them.
4. **Duplicate filesystems in /mnt** — generated hardware config picked up installer mount points under `/mnt`, causing conflicts. Remove them from `hardware-configuration.nix`.
5. **Git ownership was root** — `/etc/nixos` owned by root caused git safe-directory issues. Needs correct ownership (<user>) or `git config --global --add safe.directory /etc/nixos`.
6. **ZFS assertion: network hostid required** — ZFS requires `networking.hostId` per host (`head -c 8 /etc/machine-id`).
