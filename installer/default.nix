{ pkgs, lib, ... }:

{
  imports = [
    # Imported via flake.nix to avoid pkgs.path infinite recursion
  ];

  # ZFS + LUKS support
  boot.supportedFilesystems = [ "zfs" ];

  # 6.18 LTS, pinned explicitly, and NOT linuxPackages_latest.
  #
  # This is a ZFS rescue ISO, so the kernel is chosen by what ZFS supports and by
  # nothing else. Measured 2026-10-08 against the pinned stable nixpkgs: of 20
  # named linuxKernel.packages.linux_* attributes 8 still evaluate (the other 12
  # are EOL throw-aliases), and of those 8 six carry a buildable ZFS module while
  # two do not -- 7.1.8 and 7.2, which exceed zfs_2_4's declared
  # kernelMaxSupportedMajorMinor of "7.0" (pkgs/os-specific/linux/zfs/2_4.nix:16).
  # All three packaged variants fail together: zfs_2_3, zfs_2_4 and zfs_unstable
  # are 0 of 3 buildable on kernel 7.2 and 3 of 3 on kernel 6.18.44. So 6.18 is
  # the newest kernel here that is both packaged and ZFS-supported.
  #
  # linuxPackages_latest resolved to 7.2 and made the ISO UNEVALUATABLE:
  # "Refusing to evaluate package 'zfs-kernel-2.4.3-7.2' ... broken". Setting
  # problems.handlers.zfs.broken = "ignore" is not the repair -- it yields an ISO
  # that builds and cannot import a pool, failing at the moment of use instead of
  # now. Dropping zfs from boot.supportedFilesystems also evaluates and is wrong
  # for the same reason: importing rpool is what this ISO is for.
  #
  # The initrd is NOT the lever, although the error surfaces under
  # boot.initrd.systemd.contents."/lib".source. zfs is not in
  # boot.initrd.supportedFilesystems at all here (5 entries: iso9660, overlay,
  # squashfs, tmpfs, vfat); the module arrives via boot.extraModulePackages, so
  # forcing boot.initrd.systemd.enable = false still refuses to evaluate. The
  # stack trace names where evaluation first touched the module, not why.
  #
  # The RDNA 3.5 reason the previous comment gave is satisfied by 6.18 and is no
  # longer a reason to chase latest: gfx1151 support landed around 6.14-6.15, and
  # server-nixos -- the Framework Server with the Radeon 8060S that comment was
  # written for -- runs 6.18.44 today with rpool ONLINE. workstation-nixos runs
  # the same 6.18.44. Matching the fleet is also what makes a rescue ISO useful:
  # the same kernel and the same zfs-kernel-2.4.3-6.18.44 that wrote the pool.
  #
  # hosts/server/default.nix:64-84 reached this same answer on 2026-08-16 for the
  # running host. The installer never got that repair, which is the shape where a
  # fix lands in one of two parallel consumers and leaves the other broken with
  # the fix's own comment standing beside it as evidence somebody knew.
  boot.kernelPackages = pkgs.linuxPackages_6_18;

  # Networking for Claude Code auth
  networking = {
    wireless.enable = lib.mkForce false;
    networkmanager.enable = true;
  };

  # All firmware (WiFi 7 ath12k, etc.)
  hardware.enableAllFirmware = true;

  # Load amdgpu early for RDNA 3.5 display (Framework Server)
  boot.initrd.kernelModules = [ "amdgpu" ];

  environment.systemPackages = with pkgs; [
    # Claude assistant
    unstable.claude-code

    # ZFS + LUKS partitioning workflow
    parted
    gptfdisk
    dosfstools
    cryptsetup
    tpm2-tss

    # Essentials
    jq  # required by nixos-install --flake (resolves flake URI)
    git
    neovim
    tmux
    htop
    ripgrep
    wget
    curl

    # Networking
    networkmanagerapplet
    iw

    # YubiKey + agenix
    yubikey-manager
    libfido2
    gnupg
    pinentry-curses
    age
    age-plugin-yubikey
    pam_u2f
  ];

  # Enable flakes (required for nixos-install --flake)
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  programs.zsh.enable = true;
  users.users.nixos.shell = pkgs.zsh;

  # Smart card daemon for YubiKey
  services.pcscd.enable = true;

  # SSH server for headless install option
  services.openssh.enable = true;

  # Larger console font (Framework laptop readability)
  console.font = "ter-v24n";
  console.packages = [ pkgs.terminus_font ];

  # Claude context files
  #
  # claude-config/LAB-REDEPLOYMENT.md was referenced here until 2026-10-08 and has
  # not existed since 2026-06-03, when 9ffe459 ("docs: remove redeployment plans,
  # sanitize server audit") deleted both copies of it -- 1,445 lines each from
  # docs/ and installer/claude-config/ -- because this repository is public. This
  # file has not been touched since the initial commit, 86dd171, on that same day,
  # so the reference has been dangling for the whole life of the repo and the ISO
  # has never once been buildable: "error: path
  # '/etc/nixos/installer/claude-config/LAB-REDEPLOYMENT.md' does not exist".
  #
  # It was invisible because the ZFS kernel refusal above is raised FIRST, so the
  # one error everybody saw masked the second. Found only by neutralising the ZFS
  # fault in a probe and watching a different error appear.
  #
  # The reference is removed rather than the file restored: the deletion was a
  # deliberate sanitisation of a public repo, and restoring 1,445 lines of
  # redeployment plan to github.com/oat-meal/nixos-lab is the operator's call, not
  # a side effect of fixing a build. installer/claude-config/CLAUDE.md remains and
  # is the context file the ISO actually ships.
  environment.etc."claude/CLAUDE.md".source = ./claude-config/CLAUDE.md;

  # Install scripts
  environment.etc."nixos-installer/install.sh" = {
    source = ./install.sh;
    mode = "0755";
  };
  environment.etc."nixos-installer/refresh-flake.sh" = {
    source = ./refresh-flake.sh;
    mode = "0755";
  };

  # Set up environment on boot
  system.activationScripts.installer-setup = ''
    mkdir -p /home/nixos/.claude
    ln -sf /etc/claude/CLAUDE.md /home/nixos/.claude/CLAUDE.md

    # Create .zshrc so the newuser wizard doesn't appear
    cat > /home/nixos/.zshrc <<'ZSHRC'
# Disable history expansion (! character issues)
setopt NO_BANG_HIST
ZSHRC

    chown -R nixos:users /home/nixos/.claude /home/nixos/.zshrc 2>/dev/null || true
  '';

  # Convenience aliases in the default shell profile
  environment.shellAliases = {
    install-nixos = "sudo /etc/nixos-installer/install.sh";
    refresh-flake = "sudo /etc/nixos-installer/refresh-flake.sh";
  };
}
