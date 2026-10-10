# Bare-metal rebuild

How to bring a host back from a blank disk. The configuration is in git, so the
system itself redeploys in about an hour. What the flake does **not** hold is the
per-host state below. Every item in the table has to be recreated or restored by
hand, and every one of them is a step in the procedure.

Written 2026-10-10. Not yet exercised on real hardware: the VM tests in
`tests/recovery-drill.nix` prove the data-restore path, and the rescue ISO boots
in a VM. A real rebuild is what proves this page. Update it after the first one.

## What git does not hold

| State | Where it lives | If lost | Recovery |
|---|---|---|---|
| SSH host key | `/etc/ssh/ssh_host_ed25519_key` | sops age identity changes, so `secrets/secrets.yaml` no longer decrypts on that host; pinned host keys break | Re-key sops (step 4), update `hostKeys` in `hosts/network.nix` |
| LUKS passphrases | your memory / password manager | disk cannot be unlocked | none: keep them somewhere off the lab |
| ZFS `hostId` | `hardware-configuration.nix` (server: `hosts/server/default.nix` + `spl.spl_hostid`) | installer generates a new one | see **Trap: server hostId** |
| User passwords | `/etc/shadow` (`mutableUsers`, no hash in git) | no password | `passwd oat` (step 5) |
| Syncthing device ID | `~/.config/syncthing/` | new ID, peers reject it | update `syncthing` in `hosts/network.nix` (step 6) |
| WireGuard private key | `secrets/secrets.yaml` (sops) | only lost if **all three** hosts are lost | regenerate (see **All hosts lost**) |
| Server TPM2 enrolment | TPM + LUKS header | boot asks for the passphrase | re-enrol (server, step 7) |
| Server initrd SSH key | `/etc/secrets/initrd/ssh_host_ed25519_key` | initrd build fails (file missing) | generate before the first rebuild (server, step 7) |
| `lab_monitor` key | `~oat/.ssh/lab_monitor` on the server | sentinels and host-health MCP cannot probe | new key, update `monitorKey` (server, step 7) |
| Local container images | podman store on the server/workstation | ComfyUI units fail to start | rebuild from `ai-lab/comfyui/Containerfile*` (step 7) |
| Ollama models, HY-Motion checkout | `/storage/ollama`, `/storage/hy-motion` | services start with nothing to serve | re-pull / re-clone (server, step 7) |
| Workstation storage keyfile | `/etc/secrets/storage.key` | `storage` pool cannot unlock | pool is replaceable by decision (game installs, Steam): recreate it |
| On-prem git remotes | server `/storage/git/*.git` | the only shared copy of the private repos | the workstation clones are the other copy; re-push them (server, step 8) |
| User data | `rpool/home`, server `/storage/*` | lost | only what `lab.backup` holds (`docs/backups.md`). **Not enabled yet** |

No off-site copy exists, by decision. A loss that takes every disk in the house
takes the data with it. The configuration survives on GitHub.

## Before you need this

- An installer USB: `nix build .#installer-iso` on any NixOS host, then `dd` it.
  CI evaluates the ISO on every push; it does not build it, so build one ahead of time.
- The LUKS passphrases, stored outside the lab.
- GitHub access from at least one surviving host or browser, to merge a re-key commit.

## Procedure: one host lost, the others alive

The common case. A surviving host can decrypt `secrets/secrets.yaml`, so no secret
is regenerated, only re-encrypted for the new host key.

1. **Install.** Boot the ISO, `nmtui`, `install-nixos`. The installer partitions,
   creates the LUKS2 + ZFS layout, clones this repo, generates
   `hardware-configuration.nix` with a new `hostId` and LUKS block, commits it
   locally and runs `nixos-install`. Server: fix the hostId conflict **before**
   it builds (see the trap below).
2. **First boot.** Expect `wg0` to be down and any sops-backed unit to fail: the
   new host key cannot decrypt anything yet. LAN SSH works.
3. **Publish the host commit.** The installer commits the new `hardware-configuration.nix`
   in the host's clone, which was cloned over HTTPS and cannot push. Copy the file to the
   workstation, commit and push it there, then on the rebuilt host
   `git remote set-url origin git@github.com:oat-meal/nixos-lab.git` and
   `git fetch && git reset --hard origin/main`. Until it is on GitHub, the only record
   of the new UUIDs and hostId is that one disk.
4. **Re-key sops** on a surviving host, in `/etc/nixos`, as oat (never sudo for
   anything that writes the repo):
   ```bash
   ssh-keyscan -t ed25519 <lan-ip> 2>/dev/null | nix-shell -p ssh-to-age --run ssh-to-age
   # put the new age1... key in .sops.yaml under the host's anchor, then:
   SOPS_AGE_KEY=$(sudo nix-shell -p ssh-to-age --run 'ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key') \
     nix-shell -p sops --run 'sops updatekeys -y secrets/secrets.yaml'
   ```
   Also replace the host's entry in `hostKeys` in `hosts/network.nix` with the line
   from `ssh-keyscan -t ed25519 <lan-ip>`. Commit both and push.
5. **Password.** `passwd oat` on the console. sudo has no NOPASSWD fallback for
   general use, so nothing else works until this is set.
6. **Syncthing ID.** `syncthing cli show system | grep myID` on the rebuilt host,
   update `syncthing.<host>` in `hosts/network.nix`, commit.
7. **Host-specific state:**
   - **server-nixos:**
     - initrd SSH key: `sudo mkdir -p /etc/secrets/initrd && sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key`
     - TPM2: `sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 <dev>` for
       each of `cryptroot0` and `cryptroot1` (exact devices in `hosts/server/default.nix`)
     - `lab_monitor` key: `ssh-keygen -t ed25519 -N "" -C lab-monitor@server-nixos -f ~/.ssh/lab_monitor`,
       put the `.pub` in `monitorKey` in `hosts/network.nix`, commit
     - container images: `podman build` from `ai-lab/comfyui/Containerfile`
       (tag `localhost/comfyui-gfx1151-impact:v0.2-8`, as `comfyui.nix` names it)
     - Ollama: re-pull the models listed in `docs/ai-lab.md`; HY-Motion: see the
       header of `hosts/common/optional/ai/hy-motion.nix`
   - **workstation-nixos:** `podman build -f ai-lab/comfyui/Containerfile.gfx1201`
     (tag `localhost/comfyui-gfx1201-render:v2`). If the `storage` mirror is gone,
     recreate it; it holds nothing irreplaceable.
   - **laptop-nixos:** optional YubiKey enrolment (README, Post-Install).
8. **Deploy.** `bash deploy.sh <host>` from the workstation pushes the commits from
   steps 4–7. The rebuilt host's sops secrets now decrypt and `wg0` comes up. Use
   `nixos-rebuild boot` + reboot if systemd differs from what was installed.
   Server: once `/storage/git` exists, re-create each bare repo and push from the
   workstation clones (`git init --bare` + `git push --all`).
9. **Data.** Restore from the archive per `docs/backups.md`. Until `lab.backup` is
   enabled there is nothing to restore from.

## All hosts lost

Nothing can decrypt `secrets/secrets.yaml`. Install every host as above, then
regenerate instead of re-keying:

1. New WireGuard keypairs: `wg genkey | tee priv | wg pubkey` per host. Put the
   public keys in `hosts/network.nix`.
2. Rebuild `.sops.yaml` from each host's `ssh-to-age` key, then
   `bash secrets/init-sops.sh` to write and encrypt the private keys.
3. Steps 4–8 above for every host, then deploy all.

## Trap: server hostId

The installer injects `networking.hostId` into the new `hardware-configuration.nix`,
and `hosts/server/default.nix` already sets it (with `spl.spl_hostid` matching).
Two values do not merge. Verified 2026-10-10 by evaluating the server
configuration with a second hostId:

```
error: The option `networking.hostId' has conflicting definition values:
- In `.../hosts/server/default.nix': "dc598b84"
- In `<unknown-file>': "deadbeef"
```

Before the install builds, delete the injected `networking.hostId` line from
`hosts/server/hardware-configuration.nix`. The new pool was created with the
installer's hostId, so either set `hosts/server/default.nix` and the
`spl.spl_hostid=0x…` kernel parameter to that value, or run `zgenhostid
dc598b84` in the installer before `nixos-install`. Workstation and laptop keep
their hostId only in `hardware-configuration.nix`, so they are not affected.

## Verify

Each check runs the thing, not its wrapper:

```bash
systemctl --failed --no-pager                        # expect 0 units
sudo wg show wg0 latest-handshakes                   # a recent handshake from each peer
ssh <other-host> true                                # mesh SSH both directions
sudo ls /run/secrets/wireguard/                      # the host's secret decrypted
```

Then the cross-host checks in `docs/deployment.md` ("Verify hosts are in sync"),
and for the server `zpool status -x` and a request to each service on `wg0`.
