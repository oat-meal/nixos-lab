# Kernel module autoload silently dies on systemd-initrd hosts

Affects any host with `boot.initrd.systemd.enable = true` — i.e. anything importing
`hosts/common/optional/security/luks.nix`. Hit **laptop-nixos 2026-08-10** and
**server-nixos 2026-08-16**. workstation-nixos has the same preconditions but has not
reproduced it; the failure is a boot-ordering race, not a config difference.

## Symptom

After a **reboot** — but never after a `nixos-rebuild switch` — on-demand kernel module
autoloading is dead, cascading into unrelated-looking failures:

```
boot.mount                    mount: /boot: unknown filesystem type 'vfat'
firewall.service              iptables: Failed to initialize nft: Protocol not supported
proc-fs-nfsd.mount            mount: /proc/fs/nfsd: unknown filesystem type 'nfsd'
podman-*.service              container networking never comes up
```

On the laptop it also broke DHCP and WiFi: without `af_packet`, `socket(AF_PACKET)` returns
`EAFNOSUPPORT`, which kills NetworkManager's DHCP client and wpa_supplicant.

The tell is that the module tree is **fine** — `vfat` is right there in `modules.dep`. Check the
helper path instead:

```sh
cat /proc/sys/kernel/modprobe     # broken: /sbin/modprobe   (does not exist on NixOS)
```

## Cause

With systemd-initrd, `systemd-sysctl.service` and `systemd-modules-load.service` run **inside the
initrd**, are restarted there by the daemon-reload that `initrd-parse-etc` triggers, and — being
`Type=oneshot` + `RemainAfterExit=yes` — their `active (exited)` state is serialized across
`switch_root`. systemd therefore never re-runs them against the real `/etc`, so `/etc/sysctl.d`
and `/etc/modules-load.d` are silently never applied.

Everything in `60-nixos.conf` stays at its kernel default. Verified on the laptop:
`vm.swappiness` 60 not 1, `kernel.pid_max` 32768 not 4194304, `rp_filter` 0 not 2, and
`kernel.modprobe` still `/sbin/modprobe`.

`kernel.modprobe` only governs **kernel-initiated** autoload. Running `modprobe` directly still
works — which is how you break the deadlock by hand (see below).

`nixos-rebuild switch` masks the whole thing by restarting both units as full root. That is why
it only ever recurs on reboot, and why a host can look completely healthy while still being
broken on its next boot.

## Fix

Import `hosts/common/optional/hardware/kernel-module-autoload.nix`. It does three things:

1. `boot.kernel.sysctl."kernel.modprobe"` → the real kmod binary.
2. `boot.kernelModules` force-loads `vfat`, `nls_cp437`, `nls_iso8859_1`, `af_packet`, `rfkill` (added 2026-08-21) — these are
   inserted by systemd-modules-load via libkmod, independent of the modprobe path.
3. A `reapply-kernel-config` oneshot re-invokes both generators after `switch_root`, ordered
   `before` the consumers that were failing (`boot.mount`, `firewall.service`, `network-pre.target`,
   NetworkManager, wpa_supplicant, and the two NFS mounts).

Ordering against units a host does not have is a no-op, so the `before` list is safe to carry
everywhere.

## Recovering a host that is already in this state

There is a deadlock: `nixos-rebuild` needs `/boot` mounted to install the bootloader, `/boot`
needs `vfat`, and `vfat` needs the fix that only a rebuild can apply. Break it by loading the
modules by hand first — invoking `modprobe` directly bypasses the broken helper path:

```sh
sudo modprobe vfat; sudo modprobe nls_cp437; sudo modprobe nls_iso8859_1; sudo modprobe nf_tables
sudo systemctl start boot.mount
sudo nixos-rebuild switch --flake /etc/nixos#<host>
```

Load them **one per invocation** — `modprobe a b c` stops at the first failure, so a single
missing module silently skips the rest.

## Verifying the fix actually holds

Only a **reboot** proves it. After a `switch` everything looks correct because the switch itself
re-ran the generators. A clean boot should show `/proc/sys/kernel/modprobe` pointing into the
nix store, `reapply-kernel-config` active, and `systemctl --failed` empty.
