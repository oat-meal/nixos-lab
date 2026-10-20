# Desktop applications
# File managers, GUI tools, and common desktop packages

{ pkgs, ... }:

{
  # Virtual filesystem for file managers
  services.gvfs.enable = true;

  environment.systemPackages = with pkgs; [
    # File management
    # The Thunar packages all moved to top-level in 26.05.
    thunar
    thunar-volman
    thunar-archive-plugin
    tumbler
    xarchiver
    trash-cli

    # Terminal
    alacritty

    # Wayland tools
    wayland
    xwayland

    # Cursors
    bibata-cursors

    # X11 compatibility
    # The xorg package set is deprecated in 26.05; these are the top-level names.
    libxcursor
    libx11
    libxrandr
    libxext
    libxcb

    # Multimedia
    ffmpeg
    libGL
    glib
    gtk3

    # GStreamer for video playback
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-vaapi
    gst_all_1.gst-libav

    # Hardware video acceleration
    libva-utils
    mesa-demos

    # PDF viewer
    zathura

    # CLI tools
    pkgs.unstable.claude-code
    p7zip

    # AI desktop apps (official Linux builds; see flake.nix and pkgs/)
    claude-desktop
    pkgs.unstable.chatgpt

    # Browsers
    zen-browser

    # Notes
    obsidian
  ];

  # Claude Desktop's Cowork VM looks for UEFI firmware ONLY at these fixed
  # paths, and the app's asar-integrity fuse forbids patching them out (see
  # pkgs/claude-desktop/package.nix). Without this, Cowork cannot boot its VM.
  # virtiofsd likewise: the copy bundled with the app is used ONLY on Ubuntu
  # 22.x; everywhere else it must be at /usr/libexec or /usr/bin. Measured
  # 2026-10-20: with OVMF alone, Cowork still reported "unsupported".
  systemd.tmpfiles.rules = [
    "L+ /usr/share/OVMF - - - - ${pkgs.OVMF.fd}/FV"
    "L+ /usr/libexec/virtiofsd - - - - ${pkgs.virtiofsd}/bin/virtiofsd"
  ];

  # Wayland environment
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  };
}
