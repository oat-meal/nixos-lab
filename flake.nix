{
  description = "NixOS Lab - Multi-host infrastructure with MangoWM desktop, home server, and laptop";

  ################################
  ## FLAKE INPUTS
  ################################
  inputs = {
    # Stable (system base)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Unstable (for Discord, cutting-edge libs, etc.)
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Claude Code — a THIRD nixpkgs, pinned, feeding exactly one package.
    #
    # WHY NOT nixpkgs-unstable, MEASURED 2026-10-08. That input has seven
    # consumers: mango (the desktop compositor, via inputs.nixpkgs.follows
    # below), ollama-rocm, ollama-vulkan, searxng, sunshine and discord. Bumping
    # it from 2026-08-02 to 2026-10-08 to reach a newer claude-code was tried and
    # reverted, because it moved two things nobody asked it to:
    #
    #   claude-code   2.1.220 -> 2.1.292   wanted (2.1.287+ for mods)
    #   ollama-rocm   0.24.0  -> 0.40.0    sixteen minor versions, on the server
    #   mango                              rebuilt against a newer wlroots
    #
    # Both unwanted moves are on load-bearing software. hosts/server has ollama
    # on unstable specifically because stable 0.21.1 crashed during compute on
    # Strix Halo, and mango's own comment below records that the wrong wlroots
    # takes the whole session down on the first keypress after a monitor sleeps.
    # Neither would have failed at rebuild time on the workstation; both would
    # have been armed for whenever the server next rebuilt, which is the worst
    # shape available — correct today, surprising in a month, nothing to
    # re-derive it.
    #
    # WHY A SEPARATE INPUT IS CHEAP HERE AND WOULD NOT BE FOR THE OTHERS.
    # claude-code is stdenvNoCC.mkDerivation over a prebuilt native binary
    # fetched from Anthropic's CDN — no Node.js, no compilation, and no stdenv,
    # kernel, Mesa or ROCm coupling. A second nixpkgs for it costs a parallel
    # closure (a second glibc plus ripgrep, procps, alsa-lib, bubblewrap, socat)
    # and rebuilds nothing. The same trick for ollama-rocm would not work: that
    # one is coupled to ROCm and the kernel, which is why it is pinned by sharing
    # an input rather than isolated in its own.
    #
    # Pinned to the nixos-unstable CHANNEL revision, not a nixpkgs master commit,
    # so the dependency closure comes from the binary cache instead of building
    # locally. Bump THIS input alone to move Claude Code; nothing else rides it.
    nixpkgs-claude.url = "github:NixOS/nixpkgs/e7439b6b14ad3cc35d05608ebca9bce01a25f5f8";

    # Home Manager
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Zen Browser
    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix — runtime secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Noctalia — native Wayland desktop shell (v5). Evaluating on the workstation;
    # follows nixpkgs (builds from source, no upstream binary cache).
    noctalia = {
      url = "github:noctalia-dev/noctalia";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # MangoWM — dwl-based Wayland compositor. The desktop compositor on all
    # desktop hosts (niri fully removed 2026-07-04).
    #
    # Follows nixpkgs-unstable, NOT nixpkgs: since 2026-07-08 mango requires
    # wlroots_0_20, which 25.11 does not package (it stops at 0_19). Pinning
    # mango back to a wlroots_0_19 rev is not an option — the selmon NULL-deref
    # fix in keypress() landed after that bump, and that crash takes the whole
    # session down on the first keypress after the only monitor sleeps.
    # Revisit if/when 25.11 gains wlroots_0_20.
    mango = {
      url = "github:mangowm/mango";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  ################################
  ## FLAKE OUTPUTS
  ################################
  outputs = { self, nixpkgs, nixpkgs-unstable, nixpkgs-claude, home-manager, zen-browser, sops-nix, noctalia, mango, ... }:
    let
      system = "x86_64-linux";

      # Shared overlay for unstable packages
      unstableOverlay = final: prev: {
        unstable = (import nixpkgs-unstable {
          inherit system;
          config = prev.config;
        }) // {
          # ⚠️ claude-code ALONE comes from its own pinned input, for the reasons
          # in the nixpkgs-claude comment under inputs. Overridden HERE rather
          # than at the two call sites -- hosts/common/optional/desktop/apps.nix:61
          # and installer/default.nix:28, both `unstable.claude-code` -- so that
          # one name keeps working and no host has to know where it came from. A
          # call-site change would also have had to be made twice and stay made,
          # which is the shape this repository has already been bitten by: a fix
          # applied to one of two parallel consumers leaves the other broken and
          # leaves its own comment standing beside it as evidence somebody knew.
          #
          # The attribute is replaced on the RESULT set, not inside nixpkgs' own
          # fixpoint, so nothing in unstable's package set resolves against it.
          # That is correct here and worth stating: claude-code has no reverse
          # dependencies in this tree, so there is nothing that would want the
          # pinned one by any route other than this name.
          # ⚠️ AND IT TAKES THIS SYSTEM'S alsa-lib, NOT ITS OWN NIXPKGS'. Measured
          # 2026-10-08, hours after the pin landed: claude-code's wrapper appends
          # alsa-lib to LD_LIBRARY_PATH for voice mode, EVERY CHILD PROCESS
          # INHERITS IT, and the alsa-lib from nixpkgs-claude is built against
          # glibc 2.44 while this host runs 2.42. So anything launched from a
          # Claude Code session that loads libasound dies in the loader:
          #
          #   godot: .../glibc-2.42-67/lib/libm.so.6: version `GLIBC_2.43' not
          #          found (required by .../alsa-lib-1.2.16.1/lib/libasound.so.2)
          #
          # Four tools broke on this one variable -- godot, Electron, gamescope's
          # SDL3, and ffmpeg -- and worse, a GATE went silently green: forge's
          # engine-script-parse runs godot and greps its output for a parse error,
          # so a godot that dies in the loader produces no such line and the gate
          # reported "3/3 engine scripts parse" having parsed nothing at all.
          #
          # THE OBVIOUS FIX WAS `--unset LD_LIBRARY_PATH` IN A RE-WRAP AND IT IS
          # THE WORSE ONE. It throws away voice mode's reason for the variable,
          # and it drops whatever else the parent had put there -- on this host,
          # pipewire-jack. `alsa-lib` is an ordinary argument of the package, so
          # handing it the version this system already runs fixes the mismatch at
          # its source and costs nothing: 1.2.15.3 against glibc 2.42, matching
          # everything else on the machine. The ABI is stable across that gap.
          #
          # `prev` is the STABLE package set here, which is the whole point --
          # that is where the host's own glibc lives.
          claude-code = (import nixpkgs-claude {
            inherit system;
            config = prev.config;
          }).claude-code.override {
            alsa-lib = prev.alsa-lib;
          };
        };
      };

      # Builder helper for NixOS hosts
      mkSystem = { hostname, hostPath, extraModules ? [], enableHomeManager ? true, enableDesktop ? true }:
        nixpkgs.lib.nixosSystem {
          inherit system;

          specialArgs = {
            inherit system;
            inputs = {
              inherit self nixpkgs nixpkgs-unstable home-manager noctalia mango;
            };
          };

          modules = [
            # Host-specific configuration
            hostPath

            # Runtime secrets
            sops-nix.nixosModules.sops

            # Overlays
            { nixpkgs.overlays = [
              unstableOverlay
              (final: prev: { zen-browser = zen-browser.packages.${system}.default; })
            ]; }
          ]
          # Desktop compositor (MangoWM) is imported per-host via hosts/*/default.nix
          ++ extraModules
          ++ (if enableHomeManager then [
            # Home Manager integration
            home-manager.nixosModules.home-manager
            {
              home-manager.sharedModules = [
                { nixpkgs.overlays = [ unstableOverlay ]; }
              ];
              home-manager.users.oat = import ./home/oat/default.nix;
              home-manager.extraSpecialArgs = {
                inherit system hostname;
                inputs = {
                  inherit self nixpkgs nixpkgs-unstable home-manager noctalia mango;
                };
              };
              home-manager.backupFileExtension = "hm_bak";
            }
          ] else []);
        };

    in {
      ############################################################
      ## INSTALLER ISO
      ############################################################

      packages.${system}.installer-iso = (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./installer/default.nix
          { nixpkgs.overlays = [ unstableOverlay ]; }
          { nixpkgs.config.allowUnfree = true; }
        ];
      }).config.system.build.isoImage;

      ############################################################
      ## HOSTS
      ############################################################

      nixosConfigurations = {
        # Gaming Workstation
        # AMD Ryzen 9950X, MangoWM compositor, gaming optimizations
        workstation-nixos = mkSystem {
          hostname = "workstation-nixos";
          hostPath = ./hosts/workstation/default.nix;
        };

        # Framework 13 Laptop
        # AMD Ryzen, MangoWM compositor, power management
        laptop-nixos = mkSystem {
          hostname = "laptop-nixos";
          hostPath = ./hosts/laptop/default.nix;
        };

        # Home Server — Framework Server (headless)
        # AMD Ryzen AI Max+ 395, 128GB RAM, Ollama/Jellyfin/AdGuard
        server-nixos = mkSystem {
          hostname = "server-nixos";
          hostPath = ./hosts/server/default.nix;
          enableDesktop = false;
          enableHomeManager = false;
        };
      };
    };
}
