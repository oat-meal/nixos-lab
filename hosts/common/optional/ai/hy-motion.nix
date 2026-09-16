# HY-Motion — text-to-motion generation (a text prompt in, a skeletal animation out).
#
# The one generative capability in this lab with no vendor behind it, which is why
# it is here at all: every other media type has a paid API as a fallback, and
# motion does not. Produces SMPL-H motion (52 joints) as .npz plus an .fbx export.
#
# ⚠️ CPU, NOT THE iGPU, AND THAT IS NOT A CONFIGURATION MISTAKE. The GPU path
# segfaults on gfx1151 — the model is built against CUDA. Measured 2026-09-15:
# ~52s per 4-second clip on CPU, 5.3s to load. Slow, and it works with no key, no
# account and no network, which is the property that matters here. If a later
# ROCm or upstream release fixes the GPU path, HY_MOTION_FORCE_CPU=0 is the only
# change needed.
#
# ⚠️ AND IT IS CPU FOR A SECOND REASON WORTH KNOWING: both of upstream's LLM
# stages (prompt rewriting, duration estimation) are disabled, because
# bitsandbytes 4-bit quantisation segfaults on ROCm. Upstream's own flag logic is
# an `or`, so disabling one stage still loads the LLM and still crashes — both
# must be off. The upside is that neither Qwen3-8B nor the 45 GB prompt module is
# ever read, which is why load is 5.3s rather than minutes.
#
# NOT A CONTAINER, unlike the rest of ai-lab: upstream ships a python checkout and
# a requirements file, and the ROCm torch wheels are ~10 GB. The checkout, venv and
# weights live on the storage dataset at /storage/hy-motion and are NOT in this
# repository — this module is the service definition only.

{ pkgs, ... }:

let
  root = "/storage/hy-motion";
  port = 8190; # 8188 ComfyUI, 8880 Kokoro, 8091 lab-api, 8085 dashboard
in
{
  systemd.services.hy-motion = {
    description = "HY-Motion text-to-motion service";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # `nix` is on PATH because run.sh resolves the shared libraries the ROCm
    # wheels dlopen: the server has no nix-ld, so they are not found otherwise.
    #
    # ⚠️ nettools IS NOT OPTIONAL, AND ONLY THE REAL UNIT ENVIRONMENT SHOWS IT.
    # Upstream shells out to `hostname` while loading, just to log which machine
    # it came up on. Started by hand it works, because a login shell has the
    # whole system path; started by systemd the PATH is exactly this list, and
    # the first request died with "No such file or directory: 'hostname'" -- an
    # error that names a command and not the capability it was serving. A
    # service verified only the way it was developed is verified on the wrong
    # environment.
    path = [ pkgs.nix pkgs.bash pkgs.coreutils pkgs.nettools ];

    environment = {
      HY_MOTION_ROOT = root;
      HY_MOTION_SERVE = "${./../../../../ai-lab/hy-motion/serve.py}";
      HY_MOTION_HOST = "10.100.0.2"; # wg0 only
      HY_MOTION_PORT = toString port;
      HY_MOTION_FORCE_CPU = "1";
      HY_MOTION_OUT = "${root}/out-service";
    };

    serviceConfig = {
      Type = "exec";
      User = "oat"; # owns the checkout, the venv and the weights
      Group = "users";

      # Upstream resolves some assets relative to the current directory, so the
      # service must start inside the checkout. serve.py also chdir's here, which
      # is the authoritative fix; this makes the requirement visible in the unit.
      WorkingDirectory = root;
      ExecStart = "${pkgs.bash}/bin/bash ${./../../../../ai-lab/hy-motion/run.sh}";
      Restart = "on-failure";
      RestartSec = "10s";

      # First start resolves library packages through nix and imports torch.
      TimeoutStartSec = "10min";

      # ⚠️ THERE IS DELIBERATELY NO `SuccessExitStatus = 139` HERE, AND THE FIRST
      # VERSION OF THIS UNIT HAD ONE. The reasoning was that this model segfaults
      # at python interpreter teardown — which it does, every time, when run as a
      # command: a script that printed "REACHED END OF MAIN" then exited 139 with
      # its outputs correct on disk. That is the whole reason this is a service
      # rather than a command.
      #
      # But the guard was written from that reasoning rather than from a
      # measurement of THIS path, and the measurement refutes it. A stop with the
      # model loaded gives ExecMainCode=2 ExecMainStatus=15 Result=success:
      # uvicorn handles SIGTERM and the process never reaches the teardown that
      # crashes. So the allowance was never exercised, and it is not free — it
      # would make a GENUINE segfault during load read as a clean exit and stop
      # Restart=on-failure from ever firing. An unexercised allowance that
      # silences the failure it was never needed for is strictly worse than none.
    };
  };

  networking.firewall.interfaces."wg0".allowedTCPPorts = [ port ];
}
