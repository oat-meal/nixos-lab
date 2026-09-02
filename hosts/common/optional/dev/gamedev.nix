# Game-development content-creation toolchain — workstation only.
#
# Deliberately NOT under optional/ai/. That directory holds lab SERVICES
# (ComfyUI, Ollama, ntfy, the sentinels) — long-running things with ports and
# systemd units. These are interactive authoring tools that happen to be used
# alongside them, and filing them by "an AI pipeline calls it" would make the ai/
# category mean nothing.
#
# Workstation only, on purpose. Home Manager's user-packages.nix applies to the
# workstation AND the laptop, and the laptop is a thin client for game dev — it
# SSHes to the workstation rather than rendering locally (see the ephemeris-forge
# docs). Putting Blender there would cost ~1 GB on a machine that never runs it.
#
# Blender is a hard dependency of the forge toolchain, not a convenience: seven
# build-time tools import `bpy` and cannot run or even be import-checked without
# it — render_actions, rig_octants, dump_pose, convert_body, convert_pack,
# inspect_groups, split_part_meshes. That is the whole 3D-to-sprite animation
# pipeline, i.e. the strategy for making animations without an animator. Until
# this landed those seven sat outside every automated gate in the repo.
#
# Note the split: Godot is still provided per-user via
# home/common/optional/user-packages.nix (it ships a .desktop entry for the
# Noctalia launcher, and the laptop does open projects). Consolidating the two
# is a reasonable future tidy-up; it is not done here because moving Godot
# between mechanisms is churn with no functional gain.

{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    blender  # headless `--background --python` driver for the forge anim tools

    # Xvfb, so Godot can render OFFSCREEN. Godot's own --headless mode selects
    # the `dummy` rendering driver (the only one its `headless` display driver
    # supports), so it writes a file containing nothing — measured: a turntable
    # run produced a 37 KB PNG of exactly ONE colour while still reporting
    # success. Rendering therefore needs a real display, which meant a window
    # popping up on the live desktop and stealing focus.
    #
    # Under Xvfb the working combination is specifically
    #   xvfb-run -a --server-args='-screen 0 1280x720x24' \
    #     godot --display-driver x11 --rendering-driver opengl3
    # Vulkan under Xvfb also renders blank (no GPU surface), so the driver
    # choice is not optional. Bonus: the virtual screen fixes output resolution
    # independently of the real display, which removes a large source of
    # variance for golden-image comparison.
    xvfb-run

    # Reference capture. wf-recorder is the wlroots-native screen recorder, which
    # matches the MangoWM/Wayland session; ffmpeg is already present system-wide
    # and does the frame extraction afterwards.
    #
    # This is for measuring REFERENCE footage, not for making videos. A recording
    # is a source of hundreds of frames to sample statistically — which is
    # strictly better than hand-picked screenshots, because single-sample style
    # targets are exactly what went wrong: two of the six committed targets turned
    # out to be measuring the wrong thing (a white highlight inside the `soil`
    # box, and probably sky inside `cliff`), and nothing could tell, because with
    # one sample per material there is no distribution for an outlier to stand out
    # against.
    wf-recorder
  ];
}
