# systemd sandboxing baseline — 2026-10-10

`systemd-analyze security` exposure scores (0 = fully sandboxed, 10 = none), measured on the
running hosts at nixos-lab `0308e21`, without root. 126 services scored (workstation 43,
laptop 34, server 49). Re-measure after hardening and compare against this file:

    systemd-analyze security --no-pager

## Units this repo defines or configures

| Host | Unit | Exposure | Verdict | Owner |
|---|---|---|---|---|
| server-nixos | `hy-motion.service` | 9.2 | UNSAFE | this repo |
| server-nixos | `lab-api.service` | 8.2 | EXPOSED | this repo |
| server-nixos | `fleet-sentinel.service` | 9.2 | UNSAFE | this repo (oneshot, scored directly) |
| server-nixos | `update-advisor.service` | 9.2 | UNSAFE | this repo (oneshot, scored directly) |
| server-nixos | `search-sentinel.service` | 8.2 | EXPOSED | this repo (oneshot, scored directly) |
| workstation-nixos | `podman-comfyui-render.service` | 9.8 | UNSAFE | this repo (rootful podman) |
| server-nixos | `podman-kokoro.service` | 9.8 | UNSAFE | this repo (rootful podman) |
| server-nixos | `podman-comfyui.service` | 9.8 | UNSAFE | this repo (rootful podman) |
| workstation-nixos | `sshd.service` | 9.6 | UNSAFE | upstream module |
| server-nixos | `sshd.service` | 9.6 | UNSAFE | upstream module |
| laptop-nixos | `sshd.service` | 9.6 | UNSAFE | upstream module |
| server-nixos | `uwsgi.service` | 7.2 | MEDIUM | upstream module |
| server-nixos | `chromadb.service` | 6.1 | MEDIUM | upstream module |
| workstation-nixos | `syncthing.service` | 5.1 | MEDIUM | upstream module |
| server-nixos | `syncthing.service` | 5.1 | MEDIUM | upstream module |
| laptop-nixos | `syncthing.service` | 5.1 | MEDIUM | upstream module |
| server-nixos | `ntfy-sh.service` | 4.0 | OK | upstream module |
| server-nixos | `jellyfin.service` | 1.8 | OK | upstream module |
| server-nixos | `adguardhome.service` | 1.6 | OK | upstream module |
| server-nixos | `open-webui.service` | 1.4 | OK | upstream module |
| server-nixos | `ollama.service` | 1.4 | OK | upstream module |
| server-nixos | `homepage-dashboard.service` | 1.2 | OK | upstream module |

Reading it: upstream modules such as ollama (1.4), jellyfin (1.8) and open-webui (1.4) show
what is achievable. The repo's own long-running units are the gap — `hy-motion` and `lab-api`
— and are the first hardening targets (`ProtectSystem=strict`, `NoNewPrivileges`,
`PrivateTmp`, `ProtectHome`, `RestrictAddressFamilies`, `SystemCallFilter=@system-service`).
Timer-driven oneshots (the sentinels) are not loaded between runs, so the bulk listing
misses them; their rows above were measured with `systemd-analyze security <unit>`. sshd and rootful podman
units score high by nature.

## After hardening — 2026-10-10 (ff5b81b)

Measured offline (`systemd-analyze security --offline=true` on the built unit files) before
and after `hosts/common/sandbox.nix` was applied; the live re-measure follows the deploy.

| Host | Unit | Before | After | What it keeps |
|---|---|---|---|---|
| server-nixos | `lab-api` | 8.2 EXPOSED | **1.3 OK** | baseline (DynamicUser, HTTP only) |
| server-nixos | `search-sentinel` | 8.2 EXPOSED | **1.2 OK** | + MemoryDenyWriteExecute |
| server-nixos | `fleet-sentinel` | 9.0 UNSAFE | **1.5 OK** | `~/.ssh` writable, `/dev/zfs` only |
| server-nixos | `hy-motion` | 9.0 UNSAFE | **1.4 OK** | torch: no MDWE, `@resources`, AF_NETLINK; `out-service` rw |
| workstation-nixos | `gpu-wedge-sentinel` | 9.0 UNSAFE | **1.8 OK** | devices + full `/proc` (sysfs, rocm-smi, ps) |
| server-nixos | `update-advisor` | 9.0 UNSAFE | **4.0 OK** | light only: `nix flake update` as oat writes `~/.cache` |

(Offline "before" scores differ slightly from the live table above — 9.0 vs 9.2 — because the
live measurement includes runtime state such as the unit's actual user.)
