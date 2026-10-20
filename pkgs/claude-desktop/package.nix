# Claude Desktop (Chat, Cowork, Code) — Anthropic's official Linux build,
# repackaged from their apt repository. nixpkgs has no package for it.
#
# Provenance, checked 2026-10-20 the way apt would: key.asc fingerprint
# 31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE (Anthropic's published
# one) -> good signature on dists/stable/InRelease -> Packages SHA256 matches
# InRelease -> the .deb SHA256 below matches Packages. To bump, re-walk that
# chain; `version` and `hash` are the two lines that change.
#
# ⚠️ app.asar is NOT patched, on purpose. The binary's Electron fuses have
# EnableEmbeddedAsarIntegrityValidation ON, so any edit to the bundle makes
# the app refuse to start. Hardcoded system paths are satisfied from outside
# instead: Cowork's VM wants /usr/share/OVMF/OVMF_CODE.fd and
# /usr/libexec/virtiofsd (tmpfiles rules in hosts/common/optional/desktop/
# apps.nix -- the bundled virtiofsd is used only on Ubuntu 22.x), plus
# `qemu-system-x86_64` on PATH (the wrapper below) and rw /dev/kvm and
# /dev/vhost-vsock.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  dpkg,
  wrapGAppsHook3,

  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libnotify,
  libcap_ng,
  libseccomp,
  libuuid,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxtst,
  nspr,
  nss,
  pango,
  systemdLibs,

  libGL,
  libpulseaudio,
  libsecret,
  pipewire,
  vulkan-loader,

  qemu_kvm,
  xdg-utils,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "claude-desktop";
  version = "2.42304.2";

  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${finalAttrs.version}_amd64.deb";
    hash = "sha256-OKfVi1ipdsiMplLqovesAsh8SjiK4w9GjXK3kOa1f5A=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libnotify
    libcap_ng
    libseccomp
    pipewire
    libuuid
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libxtst
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemdLibs
  ];

  # Added to RPATH by autoPatchelf rather than LD_LIBRARY_PATH, so nothing
  # leaks into the shells and tools Claude Code spawns (see the alsa-lib note
  # in flake.nix for what that leak cost once).
  runtimeDependencies = [
    libGL
    libnotify
    libpulseaudio
    libsecret
    pipewire
    vulkan-loader
  ];

  dontWrapGApps = true;

  unpackCmd = "dpkg-deb -x $curSrc root";
  sourceRoot = "root";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share
    cp -r usr/lib $out/lib
    cp -r usr/share/icons usr/share/applications $out/share/

    # setuid helper; it cannot be setuid in the store, and Chromium falls back
    # to the user-namespace sandbox, which NixOS permits.
    rm $out/lib/claude-desktop/chrome-sandbox

    install -Dm644 $out/lib/claude-desktop/resources/linux-mime/com.anthropic.Claude.xml \
      $out/share/mime/packages/com.anthropic.Claude.xml

    runHook postInstall
  '';

  # ⚠️ makeSHELLWrapper, explicitly. wrapGAppsHook3 swaps `makeWrapper` for
  # the BINARY wrapper, which cannot evaluate the ${NIXOS_OZONE_WL:+...} below,
  # so it passed those words through literally. Measured 2026-10-20: the app
  # takes the first non-flag argv entry as its deep link, that was the literal
  # "${NIXOS_OZONE_WL:+..." fragment, and every claude:// sign-in callback was
  # silently dropped. The check at the end makes that a build failure.
  postFixup = ''
    makeShellWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : ${lib.makeBinPath [ qemu_kvm xdg-utils ]} \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"

    [ "$(head -c2 $out/bin/claude-desktop)" = "#!" ] \
      || { echo "claude-desktop wrapper is not a shell script; flags would pass literally" >&2; exit 1; }
  '';

  dontStrip = true;

  meta = {
    description = "Claude desktop app: Chat, Cowork and Claude Code";
    homepage = "https://claude.ai/download";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "claude-desktop";
  };
})
