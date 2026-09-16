# Gaming graphics configuration
# Vulkan, OpenGL, 32-bit support for Proton games

{ pkgs, lib, ... }:

{
  # Hardware graphics stack
  hardware.graphics = {
    enable = true;
    enable32Bit = true;

    extraPackages = with pkgs; [
      # AMD drivers and acceleration
      libva
      libva-utils
      libva-vdpau-driver
      libvdpau-va-gl
      mesa.opencl
      rocmPackages.clr.icd
    ];

    extraPackages32 = with pkgs.pkgsi686Linux; [
      libva-vdpau-driver
      libvdpau-va-gl

      # 32-bit text/compositing libraries for wine.
      #
      # The Steam FHS (and therefore steam-run, which is how Proton is invoked
      # outside Steam) builds its 32-bit library set from this list -- see
      # programs.steam.package's `extraLibraries`, which appends
      # hardware.graphics.extraPackages32 for the non-64-bit case. Without
      # these, /usr/lib32 inside that FHS held 856 entries against 2792 in
      # /usr/lib, and all three below were absent.
      #
      # Measured 2026-09-12 with the 32-bit Battle.net client:
      #   freetype    - wine logs "Wine cannot find the FreeType font library"
      #                 ~29x per launch and renders NO glyphs at all, which
      #                 looks like a blank window rather than a font fault
      #   fontconfig  - font discovery/matching
      #   libXrender  - winex11.drv uses XRender for surface blits and alpha
      #                 compositing; without it repaints leave stale white
      #                 regions that only refresh under the pointer
      #
      # NB: programs.steam.extraPackages is NOT the right option for this --
      # it feeds targetPkgs and is 64-bit only.
      freetype
      fontconfig
      libXrender
    ];
  };

  # Gaming environment variables
  environment.sessionVariables = {
    # Mesa/Vulkan
    __GLX_VENDOR_LIBRARY_NAME = "mesa";
    __GL_THREADED_OPTIMIZATIONS = "1";
    __GL_SHADER_CACHE = "1";
    MESA_GL_VERSION_OVERRIDE = "4.6";
    MESA_GLSL_VERSION_OVERRIDE = "460";

    # AMD GPU optimizations
    LIBVA_DRIVER_NAME = lib.mkDefault "radeonsi";
    VDPAU_DRIVER = lib.mkDefault "radeonsi";
    AMD_VULKAN_ICD = "RADV";
    RADV_PERFTEST = "aco,sam,nggc,RT";
    mesa_glthread = "true";

    # DXVK optimizations
    DXVK_HUD = "compiler";
    DXVK_LOG_LEVEL = "none";
    DXVK_STATE_CACHE = "1";

    # VKD3D-Proton (DirectX 12)
    VKD3D_CONFIG = "dxr11,dxr";
    VKD3D_SHADER_MODEL = "6_6";

    # Wine/Proton
    WINEDLLOVERRIDES = "winemenubuilder.exe=d";
    WINE_LARGE_ADDRESS_AWARE = "1";

    # Audio
    PULSE_LATENCY_MSEC = "60";

  };

  # Gaming kernel optimizations
  boot.kernel.sysctl = {
    "fs.file-max" = 2097152;
    "net.core.rmem_default" = 31457280;
    "net.core.rmem_max" = 134217728;
    "net.core.wmem_default" = 31457280;
    "net.core.wmem_max" = 134217728;
    "net.core.netdev_max_backlog" = 5000;
    "vm.dirty_writeback_centisecs" = 6000;
    "vm.dirty_expire_centisecs" = 6000;
    "vm.swappiness" = lib.mkDefault 1;
    "vm.vfs_cache_pressure" = 50;
    "vm.dirty_ratio" = 15;
    "vm.dirty_background_ratio" = 5;
  };

  # Vulkan packages
  environment.systemPackages = with pkgs; [
    vulkan-tools
    vulkan-loader
    vulkan-validation-layers
    (pkgs.pkgsi686Linux.vulkan-loader)
    mangohud
    vkbasalt
  ];
}
