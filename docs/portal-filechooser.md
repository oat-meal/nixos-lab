# Wayland: file/folder pickers do nothing (xdg-desktop-portal FileChooser)

## Symptom
On a minimal Wayland compositor (e.g. MangoWM), GTK/Electron apps' file dialogs silently
fail — e.g. Obsidian "Open folder as vault" does nothing, browser upload/download pickers
never appear. No error to the user.

## Cause
`xdg-desktop-portal` routed the `FileChooser` interface to the **GNOME** backend, whose
implementation **delegates to Nautilus** — which isn't installed. The call fails silently:

```
xdg-desktop-portal-gnome: Delegated FileChooser call failed:
The name org.gnome.Nautilus was not provided by any .service files
```

Compounding it: the portal config referenced `gtk` for some interfaces, but
`xdg-desktop-portal-gtk` was never in `extraPortals`, so there was no GTK backend to fall
back to.

## Fix
In the shared desktop base (`hosts/common/optional/desktop/base.nix`), add the GTK portal
and route `FileChooser` to it (GTK's portal has a built-in chooser; no Nautilus needed):

```nix
xdg.portal = {
  enable = true;
  extraPortals = [ pkgs.xdg-desktop-portal-gnome pkgs.xdg-desktop-portal-gtk ];
  config.common = {
    default = [ "gnome" "gtk" ];
    "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
  };
};
```

Deploy, then **restart the user portal services** (a system rebuild doesn't restart user
services) or re-login:

```
systemctl --user restart xdg-desktop-portal.service xdg-desktop-portal-gtk.service
```

Electron apps (Obsidian, etc.) bind the portal at launch — **fully quit and relaunch** them.

## Verify
```
# gtk backend present:
ls /run/current-system/sw/share/xdg-desktop-portal/portals/ | grep gtk   # -> gtk.portal
# FileChooser routed to gtk:
grep -r FileChooser /run/current-system/sw/share/xdg-desktop-portal/*portals.conf
# -> org.freedesktop.impl.portal.FileChooser=gtk
```

Fixes all file dialogs, not just Obsidian. Commit `9a7bb53` (2026-06-07).
Alternative fix would be installing Nautilus, but the GTK portal is lighter and the standard
choice for non-GNOME compositors.

---

# Related: "No apps available" when opening a URL (AppChooser)

**Different root cause from the above — nothing to do with backend routing.** Diagnosed
2026-08-15, commit `958a94a`.

## Symptom
Clicking a link inside a sandboxed app (a Steam game, a Flatpak) pops a GNOME-looking
"no apps available" dialog with **nothing selectable**, even though a browser is installed and
is the registered default.

## Not the cause
All the obvious checks pass, which is what makes this confusing:

```
xdg-settings get default-web-browser        # -> zen-beta.desktop
xdg-mime query default x-scheme-handler/https  # -> zen-beta.desktop
gio mime x-scheme-handler/https             # -> Recommended: zen-beta.desktop
```

That last one is the exact list the portal's chooser draws from, so the data is fine.

## Cause
PAM starts the **systemd user manager** with `PATH` set to only systemd's own bin directory, and
every user service inherits it — `xdg-desktop-portal` included. **GIO validates a `.desktop`
entry by resolving its `Exec` binary on `PATH`, and silently discards entries it cannot resolve.**
Zen registers as `Exec=zen-beta` — a bare command name — so it was thrown out along with every
other app, leaving the chooser empty.

Confirm by comparing the portal's view against your shell's:

```sh
# Re-run gio under the portal's own environment (xargs -0 mangles values with spaces;
# env -i also strips PATH, so call the binary absolutely):
bash -c 'declare -a E; while IFS= read -r -d "" v; do E+=("$v"); done \
  < /proc/$(systemctl --user show xdg-desktop-portal -p ExecMainPID --value)/environ
  env -i "${E[@]}" /run/current-system/sw/bin/gio mime x-scheme-handler/https'
```

Broken hosts print `No default applications` — no registered apps at all. Also check directly:

```sh
systemctl --user show-environment | grep ^PATH
```

## Fix
Set `PATH` on the user manager itself, in `hosts/common/optional/desktop/base.nix`, so it is in
place before any portal is D-Bus activated:

```nix
systemd.user.extraConfig = ''
  DefaultEnvironment="PATH=/run/wrappers/bin:/etc/profiles/per-user/oat/bin:/home/oat/.nix-profile/bin:/run/current-system/sw/bin"
'';
```

`DefaultEnvironment` in `user.conf` does **not** expand `%u` — specifiers are a unit-file
feature — hence the literal username.

## Gotcha
`nixos-rebuild switch` alone does **not** apply this: `user.conf` is only read when the user
manager re-execs. Run `systemctl --user daemon-reexec` or re-login.

## Note on the config above — RESOLVED 2026-08-16
The `default = [ "gnome" "gtk" ]` shown in the FileChooser fix above is **historical**. It was
inert on the mango hosts: the mango package ships
`/etc/xdg/xdg-desktop-portal/mango-portals.conf` with `default=gtk`, and a desktop-specific
config file wins over the generic `portals.conf` this repo generates — so the GNOME backend was
listed in `extraPortals` but never selected.

`base.nix` now declares **GTK only** (`default = [ "gtk" ]`, `extraPortals = [ gtk ]`). The GNOME
backend was wrong for these hosts on *every* interface, not just FileChooser: its
implementations delegate to GNOME components that aren't running — FileChooser to Nautilus,
AppChooser to GNOME Shell. Keeping it listed meant that if the mango package ever stopped
shipping its conf, everything would fall back to a backend that isn't there.
