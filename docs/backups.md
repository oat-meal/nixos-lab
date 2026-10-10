# Backups — design, proof, and deploy runbook

Status 2026-10-10: **designed, built, and proven in VMs; not yet enabled on any host.**
Until it is, the only protection is same-pool ZFS snapshots.

## Design (`hosts/common/optional/storage/backup.nix`, option `lab.backup`)

- **Pull, not push.** The archive host runs syncoid and logs in to each source. A source
  holds no credential for its own backups, so a compromised source cannot reach or delete them.
- **Least privilege on sources.** User `zfs-send`, `zfs allow` send,hold,release on the listed
  datasets only — never destroy. Its key is accepted only from the archive's address.
- **Pinned host keys.** Remote pulls use strict host-key checking against keys declared in
  config (`pulls.<name>.hostKey`) — no trust-on-first-use.
- **Holds.** `--use-hold` keeps the newest replicated snapshot on both sides until the next
  good run, so an incremental base survives a source being offline for days (the laptop).
- **Retention.** Sources: 24 hourly / 3 daily / 1 monthly. Archive: 30 daily / 24 monthly.
- **Archive parent** is readonly, unmounted, and has a quota — backups can never fill the
  pool they share (the 20 TB disk also holds `media/library`).
- **Opt-ins are declared.** Listed datasets get `com.sun:auto-snapshot=false`, so the older
  hand-set zfs-auto-snapshot path does not snapshot them twice.

## Proof

| Check | What it proves | Result |
|---|---|---|
| `checks.recovery-drill` | the design restores (pull, send-only source, disaster → restore) | 29 files, checksums match, git fsck |
| `checks.backup` | **this module**, real sanoid/syncoid services, two VMs | 10/10: tiers, remote + local pull, holds both sides, pruning 3→0 hourlies, quota/readonly, no destroy, `from=` refusal, no source→archive credential, byte-identical restore |

Both run in CI (`vm-tests` job) on every push.
Not proven by VMs: real data volume, restore time at scale, the real disk.

## Proposed datasets (decide before enabling)

| Host | Dataset | Size | Why |
|---|---|---|---|
| workstation | `rpool/home` | ~200 GB after `~/Downloads/fs-mp4` is removed | includes forge `reference/` — 105 files in no git history |
| workstation | `storage/data` (`/storage`) | 124 GB | |
| server | `rpool/storage/git` | 0.5 GB | every bare repo incl. the vault — irreplaceable |
| server | `rpool/storage/reference` | 7.6 GB | EthrA reference recordings |
| server | `rpool/storage/gameserver-backups` | 0.2 GB | |
| server | `rpool/home` | 12 GB | |
| laptop | `rpool/home` | 22 GB | pulled when the laptop is home |
| — | **decide:** server `rpool/storage` itself | 499 GB held directly (not in a child) | contents unreviewed |

Excluded as re-downloadable: `storage/steam` (588 GB), `rpool/storage/ollama` (102 GB),
`storage/comfyui` / `rpool/storage/comfyui` (models), `media/library` (expendable media).
Proposed total ≈ 370 GB (+ history), against a default quota of 2 TB.

## Runbook

1. **Move the disk to the server** (backlog item 17): on the workstation
   `sudo zpool export media && sudo cryptsetup close media`; attach to the server; declare it
   there (crypttab entry with `nofail` + TPM2 enrolment, `boot.zfs.extraPools = [ "media" ]`).
2. **Create the archive's key** on the server (once; never in git):
   `sudo install -d -m 700 /var/lib/syncoid && sudo ssh-keygen -t ed25519 -N "" -C syncoid@server-nixos -f /var/lib/syncoid/id_ed25519`
3. **Record public keys** in `hosts/network.nix`: `backupKey` = that `.pub`; `hostKeys` =
   each source's `/etc/ssh/ssh_host_ed25519_key.pub` (already collected 2026-10-10).
4. **Enable** — server: `lab.backup.target` with `parent = "media/backups"` and one `pulls`
   entry per source dataset (`host` = mesh IP + `hostKey`; the server's own datasets as local
   pulls, `host = null`). Each source: `lab.backup.source` with its datasets,
   `targetAddress = net.wireguard.meshIPs.server-nixos`, `targetKey = net.backupKey`.
5. **Deploy** sources first, then the server; `chown -R syncoid /var/lib/syncoid` after the
   first switch creates the user.
6. **Verify**: `systemctl start syncoid-<name>`; `zfs list -t snapshot -r media/backups`; then
   a restore of one dataset into a scratch dataset and a checksum comparison (drill layer 2).
