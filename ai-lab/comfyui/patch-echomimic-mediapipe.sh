#!/usr/bin/env bash
# Make ComfyUI_EchoMimic loadable without mediapipe, so the v3 path can run.
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

if grep -q "EPHEMERIS-FORGE LAZY MEDIAPIPE" "$U"; then
  echo "patch: already applied to $U"
  exit 0
fi
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
