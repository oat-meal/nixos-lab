#!/usr/bin/env bash
# Launch the HY-Motion service. Intended as the ExecStart of a systemd unit, and
# runnable by hand for exactly the same result.
#
# ⚠️ WHY THIS WRAPPER EXISTS AT ALL: THE SERVER HAS NO nix-ld. The workstation
# does, so pip-installed wheels there find libstdc++ and friends by themselves.
# On server-nixos they do not, and the failure is an ImportError deep inside
# torch that names a .so and not the cause. Every library the wheels dlopen has
# to be on LD_LIBRARY_PATH before python starts.
#
# ⚠️ AND THE FIRST VERSION OF THIS RESOLVED THEM WITH `find /nix/store | head -1`,
# which is two defects: it walks the whole store on every start, and `head -1`
# picks an arbitrary generation, so a working service could become a broken one
# after an unrelated garbage collection. These are resolved by name through nix
# and cached, and the cache is VERIFIED rather than trusted -- a stale path that
# no longer exists must fail loudly here, not as an ImportError later.
set -euo pipefail

ROOT=${HY_MOTION_ROOT:-/storage/hy-motion}
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# ⚠️ SERVE MUST BE OVERRIDABLE, BECAUSE NIX SPLITS THE PAIR. Run by hand the two
# files sit side by side; imported into the store by the systemd module they get
# one store path each, so `$SELF/serve.py` does not exist there.
SERVE=${HY_MOTION_SERVE:-$SELF/serve.py}
CACHE=$ROOT/.ldpath
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

# Packages that own the shared libraries the ROCm torch wheels dlopen.
#
# ⚠️ THIS LIST IS A SUPERSET ON PURPOSE, AND THE CHECK BELOW IS NOT "ARE THEY ALL
# HERE". An earlier version asserted six named .so files must exist and refused
# to start without them -- but libxml2.so.2 is not in this store at all, and the
# configuration that has been generating motion all along never had it. The
# assertion was transcribed from a helper script that silently skipped whatever
# it could not find, so the list described a wish rather than a requirement, and
# a stricter gate than the working system would have blocked a working system.
#
# `^*` selects every output of each package: libraries frequently live in a
# `lib` or `out` output that the default derivation path does not point at.
PKGS=(stdenv.cc.cc.lib zlib zstd libxml2 numactl elfutils)

build_ldpath() {
  local out paths=()
  for p in "${PKGS[@]}"; do
    # A package absent from this channel is not fatal -- see above.
    out=$($NIX build --no-link --print-out-paths "nixpkgs#$p^*" 2>/dev/null) || continue
    while read -r o; do
      [ -n "$o" ] && [ -d "$o/lib" ] && paths+=("$o/lib")
    done <<<"$out"
  done
  [ "${#paths[@]}" -gt 0 ] || { echo "hy-motion: no library directories resolved" >&2; return 1; }
  (IFS=:; echo "${paths[*]}")
}

# Rebuild the cache when absent, when asked, or when any cached entry has gone.
stale=0
if [ ! -s "$CACHE" ] || [ "${HY_MOTION_REFRESH_LDPATH:-0}" = "1" ]; then
  stale=1
else
  IFS=: read -r -a cached <<<"$(cat "$CACHE")"
  for d in "${cached[@]}"; do [ -d "$d" ] || stale=1; done
fi
if [ "$stale" = "1" ]; then
  echo "hy-motion: resolving ${#PKGS[@]} library packages through nix" >&2
  build_ldpath > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
fi
LDPATH=$(cat "$CACHE")

IFS=: read -r -a dirs <<<"$LDPATH"
echo "hy-motion: ${#dirs[@]} library directories on LD_LIBRARY_PATH" >&2

[ -x "$ROOT/.venv/bin/python" ] || { echo "hy-motion: no venv at $ROOT/.venv" >&2; exit 2; }
[ -r "$SERVE" ] || { echo "hy-motion: no serve.py at $SERVE (set HY_MOTION_SERVE)" >&2; exit 2; }

# ⚠️ VERIFY BY ASKING THE THING TO DO ITS JOB. Checking that a list of .so files
# exists is a fact about the filesystem; importing torch is the question that
# actually matters, and it is the exact operation that fails when this path is
# wrong. Costs a few seconds once per start, and converts an ImportError buried
# in the first request into a named startup failure with the real reason.
if ! err=$(env LD_LIBRARY_PATH="$LDPATH" PYTHONPATH="$ROOT" \
    "$ROOT/.venv/bin/python" -c 'import torch, hymotion' 2>&1); then
  echo "hy-motion: torch/hymotion will not import with this library path" >&2
  echo "$err" | tail -5 >&2
  echo "hy-motion: try HY_MOTION_REFRESH_LDPATH=1 $0" >&2
  exit 2
fi
echo "hy-motion: torch and hymotion import" >&2

# PYTHONPATH because `hymotion` is the upstream checkout, not an installed
# package: python puts the SCRIPT's directory on sys.path, and this script is
# deliberately not in that checkout.
exec env \
  LD_LIBRARY_PATH="$LDPATH" \
  PYTHONPATH="$ROOT" \
  CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES-}" \
  HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES-}" \
  HY_MOTION_MODEL="${HY_MOTION_MODEL:-$ROOT/ckpts/tencent/HY-Motion-1.0}" \
  HY_MOTION_OUT="${HY_MOTION_OUT:-$ROOT/out-service}" \
  HY_MOTION_HOST="${HY_MOTION_HOST:-10.100.0.2}" \
  HY_MOTION_PORT="${HY_MOTION_PORT:-8190}" \
  HY_MOTION_FORCE_CPU="${HY_MOTION_FORCE_CPU:-1}" \
  "$ROOT/.venv/bin/python" "$SERVE"
