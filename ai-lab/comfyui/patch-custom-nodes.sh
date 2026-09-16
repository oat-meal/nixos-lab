#!/usr/bin/env bash
# Source patches for the two avatar custom nodes, applied to the data volume.
#
#   sections 1-3  ComfyUI_EchoMimic             -- portrait + audio -> video
#   section 4     ComfyUI-LatentSyncWrapper     -- re-dub an existing video
#
# WARNING: RENAMED FROM patch-echomimic.sh 2026-09-16, WHEN IT STOPPED PATCHING
# ONE NODE. A script called patch-echomimic.sh that silently also edits a second
# node is the shape this lab keeps paying for -- `verify state, never infer it
# from a name`, pointed at a filename we chose ourselves. Nothing but a comment
# in the Containerfile referenced the old name.
#
# Sections 1-3: make ComfyUI_EchoMimic loadable without mediapipe, so v3 can run.
#
# ⚠️ THE TWO CONSTRAINTS CANNOT BOTH BE MET BY CHOOSING A VERSION, WHICH IS WHY
# THIS PATCH EXISTS RATHER THAN A PIN.
#
#   - the node calls `from mediapipe import solutions`, the legacy API, which
#     exists only in mediapipe 0.10.x
#   - every 0.10.x release declares `numpy<2`
#   - this image runs numpy 2.x, and torch breaks if it is downgraded
#
# So installing a mediapipe that satisfies the node breaks torch, and installing
# one that leaves torch alone does not satisfy the node. Measured 2026-09-16
# against PyPI across 0.10.18/0.10.20/0.10.21 and 1.0.1.
#
# ⚠️ AND A PIN OF `mediapipe>=1.0` WAS TRIED FIRST AND MADE IT WORSE. The reasoning
# was that the Containerfile's "mediapipe forces numpy<2" comment had gone stale,
# because 1.0.1 declares a bare `numpy`. That much was true. What it missed is
# that 1.0 also removed `solutions` -- so the floor pin bought numpy 2.x and cost
# the API the node imports, and ComfyUI logged
# `ImportError: cannot import name 'solutions' from 'mediapipe'`. The original
# comment was right all along; checking half of a constraint is how you conclude
# the opposite of it.
#
# ⚠️ WHAT MAKES THIS SAFE IS THAT v3 NEVER USES ANY OF IT. `echomimic_v3/` contains
# no mediapipe import at all, and imports nothing from utils.py that needs one.
# The dependency is an artefact of the node's __init__ importing EchoMimic_node ->
# utils.py -> src/utils/mp_utils.py eagerly, for the benefit of the v1 and v2
# paths. Made lazy, v3 loads and v1/v2 fail with a stated reason IF USED, which is
# the honest degradation rather than a silent one.
#
# Idempotent. Re-run after updating the node, because custom_nodes lives on the
# data volume and is not in this repository.
set -euo pipefail

NODE=${1:-/storage/comfyui/custom_nodes/ComfyUI_EchoMimic}
U="$NODE/utils.py"
[ -r "$U" ] || { echo "patch: no utils.py at $U" >&2; exit 2; }

# ⚠️ SKIP, DO NOT EXIT. This guard used to `exit 0`, so once section 1 had been
# applied the script returned success without ever reaching section 2 -- a fix
# added later was silently never run, and the script reported "already applied"
# as though it had done everything. Each section decides for itself now.
if grep -q "EPHEMERIS-FORGE LAZY MEDIAPIPE" "$U"; then
  echo "patch: utils.py already patched"
else
cp -n "$U" "$U.orig"

python3 - "$U" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf8").read()

# The three top-level imports that reach mediapipe, replaced by guarded ones.
old_lmk = "from .src.utils.mp_utils  import LMKExtractor"
old_mot = "from .src.utils.motion_utils import motion_sync"
old_pose = "from .echomimic_v2.src.utils.dwpose_util import draw_pose_select_v2"
for needed in (old_lmk, old_mot, old_pose):
    if needed not in s:
        raise SystemExit(f"patch: expected line not found, refusing to guess: {needed!r}")

guard = '''# --- EPHEMERIS-FORGE LAZY MEDIAPIPE -------------------------------------------
# These three reach mediapipe, which cannot be installed here without dragging
# numpy below 2 and breaking torch. They serve the v1/v2 paths only; v3 imports
# none of them. Guarded so the node LOADS, and so anything that genuinely needs
# them fails with a reason rather than at import time for everybody.
_MEDIAPIPE_WHY = (
    "this ComfyUI image has no usable mediapipe: the node needs the legacy "
    "`mediapipe.solutions` API, which exists only in 0.10.x, and every 0.10.x "
    "release requires numpy<2 while this image runs numpy 2.x for torch. The v3 "
    "path does not use mediapipe and is unaffected; v1 and v2 are not available."
)
try:
    from .src.utils.mp_utils  import LMKExtractor
    from .src.utils.motion_utils import motion_sync
    from .echomimic_v2.src.utils.dwpose_util import draw_pose_select_v2
    _MEDIAPIPE_OK = True
except Exception as _e:  # ImportError, and whatever mediapipe raises internally
    _MEDIAPIPE_OK = False
    _MEDIAPIPE_WHY = f"{_MEDIAPIPE_WHY} (import said: {_e})"

    def _mediapipe_missing(*_a, **_k):
        raise RuntimeError(_MEDIAPIPE_WHY)

    LMKExtractor = _mediapipe_missing
    motion_sync = _mediapipe_missing
    draw_pose_select_v2 = _mediapipe_missing
# --- end EPHEMERIS-FORGE LAZY MEDIAPIPE ---------------------------------------'''

# ⚠️ ORDER AND ANCHORING BOTH MATTER, AND THE FIRST VERSION GOT BOTH WRONG. It
# inserted the guard first and then deleted the other two imports with a plain
# substring replace -- but the guard CONTAINS those same import lines, indented
# inside its `try`. So the delete matched the copy it had just written, removing
# it from inside the try block and leaving a bare indent: IndentationError on a
# file that had been valid a moment earlier. Remove first, then insert, and anchor
# on the start of a line so an indented copy can never match.
s = re.sub(r"^" + re.escape(old_mot) + r"\n", "", s, count=1, flags=re.M)
s = re.sub(r"^" + re.escape(old_pose) + r"\n", "", s, count=1, flags=re.M)
s = re.sub(r"^" + re.escape(old_lmk) + r"\n", guard + "\n", s, count=1, flags=re.M)
open(p, "w", encoding="utf8").write(s)
print(f"patch: applied to {p}")
PY

python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf8').read()); print('patch: utils.py still parses')" "$U"
fi

# ── 2. the flash transformer imports a `dist` module that does not exist ──────
#
# ⚠️ THIS IS NOT A MISSING DEPENDENCY, AND THE ERROR READS LIKE ONE.
# `ModuleNotFoundError: No module named '<abs path>.echomimic_v3.src.dist'` --
# a module name with a filesystem path inside it, which looks like a broken venv
# and is not. echomimic_v3/src/ has no `dist` package at all.
#
# It is sequence-parallel / xFuser multi-GPU inference code, and upstream ALREADY
# commented these four lines out in the sibling file wan_transformer3d_audio.py
# (lines 25-28) while leaving them live in the _2512 flash variant. So this
# mirrors a decision upstream made rather than inventing one.
#
# The names ARE referenced later, in enable_multi_gpus_inference paths -- which is
# exactly why the sibling file gets away with it: single-GPU inference never
# reaches them, and a NameError there is the honest outcome for a multi-GPU call
# on a one-GPU box. Better a clear failure at the multi-GPU entry point than the
# whole node refusing to load for everybody.
T="$NODE/echomimic_v3/src/wan_transformer3d_audio_2512.py"
if [ -r "$T" ] && ! grep -q "EPHEMERIS-FORGE NO XFUSER" "$T"; then
  cp -n "$T" "$T.orig"
  python3 - "$T" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf8").read()
block = """from .dist import (get_sequence_parallel_rank,
                    get_sequence_parallel_world_size, get_sp_group,
                    xFuserLongContextAttention)
from .dist.wan_xfuser import usp_attn_forward"""
if block not in s:
    raise SystemExit("patch: the xfuser import block is not as expected, refusing to guess")
commented = "\n".join("# " + ln for ln in block.splitlines())
s = s.replace(block,
    "# --- EPHEMERIS-FORGE NO XFUSER ---------------------------------------------\n"
    "# src/dist does not exist in this node. Upstream commented the identical block\n"
    "# out of wan_transformer3d_audio.py and left it live here. Single-GPU inference\n"
    "# never reaches the names below; a multi-GPU call would NameError, which is the\n"
    "# honest failure on a one-GPU box.\n"
    + commented +
    "\n# --- end EPHEMERIS-FORGE NO XFUSER -----------------------------------------", 1)
open(p, "w", encoding="utf8").write(s)
print(f"patch: applied to {p}")
PY
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf8').read()); print('patch: flash transformer still parses')" "$T"
else
  echo "patch: flash transformer already patched or absent"
fi

# ── 3. torchaudio.save() now routes through torchcodec, which will not load ────
#
# ⚠️ NOT A MISSING PACKAGE THAT CAN SIMPLY BE INSTALLED. torchaudio 2.9 dropped its
# own encoders and forwards save() to torchcodec, so the node dies at
# `ImportError: TorchCodec is required for save_with_torchcodec` before the sampler
# ever runs. Installing torchcodec does not fix it: tested against this image, the
# wheel installs and then fails at import with
# `OSError: Could not load this library: .../libtorchcodec_image.so` -- its binary
# is built for CUDA torch and this is torch 2.9.1+rocm7.2.
#
# soundfile 0.14.0 is already in the venv (via librosa), writes WAV without any
# torch involvement, and is what the downstream reader expects anyway.
#
# ⚠️ AND IT FIXES A LATENT BUG IN THE NODE WHILE IT IS HERE: the original wrote
# FLAC-encoded bytes into a file named `.wav`. That works only because the reader
# sniffs content rather than trusting the extension -- a file whose name lies about
# its contents, waiting for the first consumer that believes the name.
N_NODE="$NODE/EchoMimic_node.py"
if [ -r "$N_NODE" ] && ! grep -q "EPHEMERIS-FORGE SOUNDFILE" "$N_NODE"; then
  cp -n "$N_NODE" "$N_NODE.orig"
  python3 - "$N_NODE" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf8").read()
old = '        torchaudio.save(buff, audio["waveform"].squeeze(0), audio["sample_rate"], format="FLAC")'
if old not in s:
    raise SystemExit("patch: the torchaudio.save line is not as expected, refusing to guess")
new = '''        # --- EPHEMERIS-FORGE SOUNDFILE ---------------------------------------
        # torchaudio 2.9 forwards save() to torchcodec, whose binary will not load
        # against ROCm torch. soundfile is already present and needs no torch.
        # Also writes WAV rather than FLAC-named-.wav, which is what the filename
        # has always claimed.
        import soundfile as _sf
        _wave = audio["waveform"].squeeze(0).detach().cpu().numpy()
        if _wave.ndim == 2:
            _wave = _wave.T          # soundfile wants (samples, channels)
        _sf.write(buff, _wave, int(audio["sample_rate"]), format="WAV", subtype="PCM_16")
        # --- end EPHEMERIS-FORGE SOUNDFILE -----------------------------------'''
open(p, "w", encoding="utf8").write(s.replace(old, new, 1))
print(f"patch: applied to {p}")
PY
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf8').read()); print('patch: EchoMimic_node.py still parses')" "$N_NODE"
else
  echo "patch: EchoMimic_node.py already patched or absent"
fi

# -- 4. LatentSync: the same torchaudio.save defect, in a different shape -------
#
# WARNING: THE SECOND NODE HAS THE SAME BUG AND SECTION 3 DOES NOT FIX IT,
# because a patch keyed to an exact line only ever repairs the line it names.
# Section 3 matched `torchaudio.save(buff, ..., format="FLAC")` in EchoMimic;
# this one is `torchaudio.save(audio_path, waveform_cpu, sample_rate)` -- a PATH
# rather than a buffer, no format argument, different variable names. Same root
# cause, nothing shared to reuse.
#
# The root cause is recorded in full at section 3 and is worth not re-deriving:
# torchaudio 2.9 dropped its own encoders and forwards save() to torchcodec, and
# installing torchcodec does NOT fix it -- tested against this image, the wheel
# installs and then fails at import because its binary is built for CUDA torch
# while this is torch 2.9.1+rocm7.2.
#
# WARNING: AND IT WAS THE SECOND DEFECT HIDING BEHIND THE FIRST. The dub failed
# at `FFmpeg is required but not found`, that was fixed in the image (v0.2-8),
# and the very next run failed here instead. Both were always present; the
# ffmpeg check simply runs first, at the top of the node's entry point, so it
# masked everything downstream of it. A fix that reveals a new failure has not
# necessarily failed.
#
# Idempotent. Re-run after updating the node: custom_nodes lives on the data
# volume and is not in this repository.
LS_NODE=${2:-/storage/comfyui/custom_nodes/ComfyUI-LatentSyncWrapper}
LS_FILE="$LS_NODE/nodes.py"

if [ ! -r "$LS_FILE" ]; then
  echo "patch: no nodes.py at $LS_FILE -- skipping section 4"
elif grep -q "EPHEMERIS-FORGE SOUNDFILE" "$LS_FILE"; then
  echo "patch: LatentSync nodes.py already patched"
else
  python3 - "$LS_FILE" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf8").read()
old = "            torchaudio.save(audio_path, waveform_cpu, sample_rate)"
if old not in s:
    raise SystemExit("patch: the torchaudio.save line is not as expected, refusing to guess")
new = "\n".join([
    "            # --- EPHEMERIS-FORGE SOUNDFILE ---------------------------------",
    "            # torchaudio 2.9 forwards save() to torchcodec, whose binary will",
    "            # not load against ROCm torch. soundfile is already present (via",
    "            # librosa) and writes WAV with no torch involvement at all.",
    "            import soundfile as _sf",
    "            _wave = waveform_cpu.detach().cpu().numpy()",
    "            if _wave.ndim == 2:",
    "                _wave = _wave.T          # soundfile wants (samples, channels)",
    "            _sf.write(audio_path, _wave, int(sample_rate), format=\"WAV\", subtype=\"PCM_16\")",
    "            # --- end EPHEMERIS-FORGE SOUNDFILE -----------------------------",
])
open(p, "w", encoding="utf8").write(s.replace(old, new, 1))
print(f"patch: applied to {p}")
PY
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf8').read()); print('patch: LatentSync nodes.py still parses')" "$LS_FILE"
fi
