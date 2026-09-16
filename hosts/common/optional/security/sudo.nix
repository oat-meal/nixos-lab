# Scoped passwordless sudo for system management
# Hosts can extend with additional commands via lib.mkAfter

{ ... }:

{
  security.sudo.extraRules = [{
    users = [ "oat" ];
    commands = [
      { command = "/run/current-system/sw/bin/nixos-rebuild"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/nix*"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/systemctl"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/git"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/zfs"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/zpool"; options = [ "NOPASSWD" ]; }

      # Network diagnosis. Added 2026-08-16 (oat-approved) after container-port
      # reachability could not be diagnosed without reading the live ruleset: every
      # NATIVE service on server-nixos answered over wg0 (ollama 11434, adguard 3000,
      # ntfy 2586, lab-api 8091) while BOTH podman published ports were blocked
      # (comfyui 8188, kokoro 8880) — and 8188 is present in the evaluated
      # wg0.allowedTCPPorts, so the declared config looked correct for both.
      #
      # This grants rule MODIFICATION, not just inspection: sudoers cannot usefully
      # constrain iptables by argument, since -L and -A differ by one flag. That is
      # acceptable here only because `nixos-rebuild` and `nix*` above are already
      # root-equivalent by construction — anyone who can build and switch a system
      # closure can do anything. This widens diagnostic reach, not privilege.
      #
      # nft is included for when/if the firewall backend moves off iptables;
      # ss needs root for -p (owning process), which is what identifies a listener.
      { command = "/run/current-system/sw/bin/iptables"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/ip6tables"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/nft"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/ss"; options = [ "NOPASSWD" ]; }

      # Container images. Added 2026-09-16 (oat-approved) after deploying a single
      # ComfyUI custom node cost FIVE build cycles. The image the service runs is
      # built out-of-band with rootful podman, and its venv is not readable from
      # the host — so "is this python module present" could only be answered by
      # building an image, switching the system, restarting the container and
      # reading one ModuleNotFoundError out of the journal. Four separate names
      # were discovered that way, one per round, each round needing a human.
      #
      # ⚠️ THIS IS STRONGER THAN THE NETWORK RULES ABOVE AND THE COMMENT THERE
      # SHOULD NOT BE REUSED FOR IT. That one says "widens diagnostic reach, not
      # privilege", which is true of reading a ruleset. It is NOT true here:
      # `podman run --privileged -v /:/host` as root is unrestricted root, and
      # sudoers cannot constrain podman by argument any more than it can iptables.
      #
      # It is granted anyway on the same ground the whole list rests on:
      # `nixos-rebuild` and `nix*` are already root-equivalent by construction —
      # anyone who can build and switch a system closure can already do anything.
      # So this adds no privilege that was not already here. What it adds is the
      # ability to answer a question in seconds instead of asking a person to run
      # a four-minute build to find out.
      { command = "/run/current-system/sw/bin/podman"; options = [ "NOPASSWD" ]; }
    ];
  }];
}
