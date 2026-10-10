# Base packages for all hosts
# Minimal CLI tools that every system should have

{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Core CLI tools
    git
    wget
    curl
    neovim
    htop
    ripgrep

    # System utilities
    pciutils
    usbutils
    lsb-release
    lm_sensors
    ethtool        # audit procedure calls for it (link speed); was missing on server-nixos
  ];

  # /etc/nixos is owned by the login user, so git refuses to operate on it as root
  # ("repository path is not owned by current user"). Declared here rather than left in
  # the user's ~/.gitconfig: sudo happens to preserve HOME so user-run sudo worked, but
  # any root context with its own HOME did not — a systemd-run nixos-rebuild failed on
  # exactly this 2026-08-16. This does NOT invite running git as root (see
  # docs/deployment-issues.md); it stops a legitimate root reader from failing.
  # `enable` is required: programs.git.config is inert without it (the module only writes
  # /etc/gitconfig when enabled). git is already in systemPackages above; enabling the module
  # is what materialises the system-level config.
  programs.git.enable = true;
  programs.git.config.safe.directory = [ "/etc/nixos" ];
}
