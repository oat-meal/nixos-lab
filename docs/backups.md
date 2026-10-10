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
- **One timer, pulls in sequence.** `lab-backup-pull` (hourly) runs each `syncoid-<name>` in
  turn and logs `pulls: N/M ok`. Not one timer per pull: the syncoid module grants and then
  revokes `zfs allow` on the shared parent, so overlapping pulls revoked each other's grant
  mid-receive (`permission denied`, then a hang). Found by `checks.backup` in CI, 2026-10-10.
  Each pull has an 8 h start timeout so one hang cannot block the rest.
- **Holds.** `--use-hold` keeps the newest replicated snapshot on both sides until the next
  good run, so an incremental base survives a source being offline for days (the laptop).
- **Retention.** Sources: 24 hourly / 3 daily / 1 monthly. Archive: 30 daily / 24 monthly.
- **Archive parent** is readonly, unmounted, and has a quota — backups can never fill the
  pool they share (the 20 TB disk also holds `media/library`).
- **Opt-ins are declared.** Listed datasets get `com.sun:auto-snapshot=false`, so the older
  hand-set zfs-auto-snapshot path does not snapshot them twice.
- **SSH host keys (opt-in, `source.hostKeys.enable`).** Copies `/etc/ssh/ssh_host_*` and the
  server's initrd key into a root-only dataset (`rpool/lab-hostkeys`, mode 700) that is pulled
  like any other. Restoring them makes a rebuilt host keep its identity, so sops decrypts and
  every pin holds without a re-key (`docs/bare-metal-rebuild.md`). **Trade-off:** root on the
  archive host, or its syncoid key, can then impersonate that host over ssh. sops is no worse
  off: any one host key already decrypts all of `secrets/secrets.yaml`. Decide per host.

## Proof

| Check | What it proves | Result |
|---|---|---|
| `checks.recovery-drill` | the design restores (pull, send-only source, disaster → restore) | 29 files, checksums match, git fsck |
| `checks.backup` | **this module**, real sanoid/syncoid services, two VMs | 12/12: tiers, remote + local pull in sequence from one timer, holds both sides, pruning 3→0 hourlies, quota/readonly, no destroy, `from=` refusal, no source→archive credential, byte-identical restore; host keys root-only, re-copied on change, restored byte-identical with mode 600 |

Both run in CI (`vm-tests` job) on every push.
Not proven by VMs: real data volume, restore time at scale, the real disk.

**No off-site copy — by decision** (oat, 2026-10-10): media and data do not leave the premises.
The archive therefore protects against pool loss, bad deletes and source compromise, not against
losing the site. An optional on-site equivalent is a cold disk, periodically synced and stored
disconnected elsewhere in the building.

## Proposed datasets (decide before enabling)

| Host | Dataset | Size | Why |
|---|---|---|---|
| workstation | `rpool/home` | ~200 GB after `~/Downloads/fs-mp4` is removed | includes forge `reference/` — 105 files in no git history |
| server | `rpool/storage/git` | 0.5 GB | every bare repo incl. the vault — irreplaceable |
| server | `rpool/storage/reference` | 7.6 GB | EthrA reference recordings |
| server | `rpool/storage/gameserver-backups` | 0.2 GB | |
| server | `rpool/home` | 12 GB | |
| laptop | `rpool/home` | 22 GB | pulled when the laptop is home |
| server | `rpool/storage/workstation-backup` (to be split out — runbook step 0) | 2.2 GB | GitHub recovery codes, the nixos-lab pre-rewrite bundle, the old game-design archive — irreplaceable |

Excluded as replaceable: the workstation's whole `storage` pool — `storage/data` (`/storage`,
124 GB), `storage/steam` (588 GB), `storage/comfyui` — which holds game installs, Steam and
models (oat, 2026-10-10: "all replaceable and non critical"); also `rpool/storage/ollama`
(102 GB), `rpool/storage/comfyui` (models) and `media/library` (expendable media).
Server `rpool/storage` itself is excluded (oat, 2026-10-10): `fsimport` (395 GB, expendable
media) moves to the 20 TB disk, `lora-training` (33 GB) is being deleted, `hy-motion` (98 GB)
is a re-downloadable checkout + weights. Proposed total ≈ 245 GB (+ history), quota 2 TB.

## Runbook

0. **Split `workstation-backup` into its own dataset** (backups work per dataset; today it is a
   plain directory inside `rpool/storage`). On the server:
   `sudo zfs create rpool/storage/workstation-backup-new && sudo rsync -aHAX /storage/workstation-backup/ /storage/workstation-backup-new/ && sudo mv /storage/workstation-backup /storage/workstation-backup-old && sudo zfs rename rpool/storage/workstation-backup-new rpool/storage/workstation-backup`
   — compare, then remove `-old`.
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
