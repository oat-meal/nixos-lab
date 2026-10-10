# Known States (Do Not Flag)

Items that appear anomalous in system checks but are expected behavior. Check this list before filing audit findings.

## All Hosts

### Notifications — no mako service
- **Symptom**: `systemctl --user status mako.service` shows not-found / inactive
- **Reason**: Notifications are handled by the Noctalia shell (started from MangoWM's autostart), not a standalone mako systemd unit. Verify: `pgrep -a noctalia`

### en_DK.UTF-8 Locale with America/Denver Timezone
- **Symptom**: Locale region (DK) does not match timezone (US Mountain)
- **Reason**: `en_DK` gives English with ISO 8601 dates (YYYY-MM-DD) and metric units. Intentional.

### dbus "Unknown username pulse"
- **Symptom**: `Unknown username "pulse" in message bus configuration file`
- **Reason**: PipeWire replaces PulseAudio; stale dbus config reference. Cosmetic.

### gnome-keyring PAM Warning
- **Symptom**: `gkr-pam: unable to locate daemon control file` at login
- **Reason**: gnome-keyring referenced in PAM but fully managed elsewhere. No functional impact.

### xdg-desktop-portal pidns Warnings
- **Symptom**: `Could not get pidns for pid NNNN`
- **Reason**: xdg-desktop-portal interacting with Steam pressure-vessel containers. Cosmetic.

### nm-applet GTK Assertion
- **Symptom**: `gtk_widget_get_scale_factor: assertion 'GTK_IS_WIDGET (widget)' failed`
- **Reason**: GTK3 bug under Wayland. Does not affect network functionality.

### PipeWire ALSA Device Drop
- **Symptom**: `spa.alsa: front:4p: snd_pcm_drop: No such device`
- **Reason**: Transient on Bluetooth/HDMI disconnect. Non-impactful.

### Bluetooth Rejected Unbonded Device
- **Symptom**: `Rejected connection from !bonded device`
- **Reason**: Correct security behavior.

### Steam Split-Lock Warnings
- **Symptom**: `x86/split lock detection: [...] steam` in journal
- **Reason**: Valve bug — unaligned atomic operations in 32-bit client on Zen 4/5.
- **Fix**: LD_PRELOAD shim (`steam-split-lock-fix.nix`) sets `prctl(PR_SET_BUS_LOCK_DETECT, WARN)` per-process. System-wide: detection is **off on the workstation** (`split_lock_detect=off` kernel param) and enforced on the laptop.
- **Note (2026-05-04)**: Steam observed relaunching with dark window during gameplay. May be related to split lock traps or a separate XWayland/CEF issue. Reopen investigation if it persists after fix.
- **Cleanup (2026-05-04)**: Removed invalid env vars `STEAM_DISABLE_BROWSER_RESTART` and `STEAM_ENABLE_WAYLAND_BROWSER` (non-existent flags). Removed `STEAM_FORCE_DESKTOPUI_SCALING=1` (default value, no-op).

### Fightcade Coredump (fc2-electron)
- **Symptom**: fc2-electron SIGSEGV in Flatpak sandbox
- **Reason**: Upstream Fightcade Flatpak bug. NixOS config is correct.

### sudo PAM "conversation failed" in Non-TTY Context
- **Symptom**: `pam_unix(sudo:auth): conversation failed` and `auth could not identify password for [<user>]`
- **Reason**: Since 2026-10-09 sudo requires the password (60-min global cache). Outside the 60-min window any sudo except the `lab-*` wrappers fails without a TTY; PAM logs it. Expected.

### sops-nix /run/secrets Permission Denied
- **Symptom**: `ls: cannot open directory '/run/secrets/': Permission denied`
- **Reason**: Correct behavior — secrets are root-owned with mode 0600. sops-nix symlinks through `/run/secrets.d/`.

### sshd Bind Failure During Rebuild (fixed)
- **Symptom**: `Bind to port 22 on 10.100.0.x failed: Cannot assign requested address` and `Failed to start SSH Daemon`
- **Reason**: sshd restarted before WireGuard interface had its IP assigned.
- **Fix**: `systemd.services.sshd.after/wants = wireguard-wg0.service` in ssh.nix. May still appear in journal from pre-fix boots.

## workstation-nixos Only

### amdgpu MES Errors (RDNA 4)
- **Symptom**: `amdgpu: MES(1) failed to respond to msg=INVALIDATE_TLBS`
- **Reason**: Known Navi 48 (RX 9070 XT) firmware issue. AMD actively fixing.
- **Action**: Monitor frequency; update kernel/mesa when available. < 5/week is acceptable.

### DisplayLink xserver.videoDrivers on Wayland
- **Symptom**: `services.xserver.videoDrivers` set despite Wayland-only session
- **Reason**: DisplayLink DRM/KMS requires modesetting DDX. Needed even on Wayland.
- *(superseded 2026-10-09: DisplayLink/EVDI is not active — `displaylink.nix` is kept but imported by no host; `videoDrivers` is the default `modesetting` + `fbdev`.)*

### Suspend/Hibernate Disabled
- **Symptom**: System never suspends
- **Reason**: AMD Ryzen 9950X (Zen 5) has Linux suspend/wake hardware issues. Always-on is intentional.

## laptop-nixos Only

### UCSI USB-C Controller Error
- **Symptom**: `ucsi_acpi USBC000:00: unknown error 256`
- **Reason**: Framework 13 USB-C controller firmware noise. Cosmetic, no functional impact.

### amdgpu Adaptive Backlight Disabled
- **Symptom**: `amdgpu.abmlevel=0` kernel parameter
- **Reason**: Prevents GPU idle lockups on Framework 13. Intentional.
