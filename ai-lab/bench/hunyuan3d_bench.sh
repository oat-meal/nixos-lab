#!/usr/bin/env bash
# Hunyuan3D image-to-mesh benchmark: end-to-end seconds per generation.
#
# Usage:  hunyuan3d_bench.sh [host] [runs] [seed-base]
#
# WHY THIS EXISTS. The lab gained a 3D generation capability (hunyuan3d-dit-v2 in
# ComfyUI's checkpoints, native nodes, no wrapper) and had no way to measure it.
# comfy_bench.sh measures SDXL, whose UNet is convolution-dominated; this one is a
# DiT plus a volume decode, so it stresses attention and memory bandwidth instead.
# That difference is not academic: an attention tuning flag that does nothing for
# SDXL could still matter here, and without this script there was no way to tell.
#
# ⚠️ SEEDS MUST DIFFER BETWEEN RUNS *AND* BETWEEN COMPARISONS. ComfyUI caches by
# prompt content, so re-submitting an identical graph returns the cached result
# in well under a second. Measured 2026-09-15: a run reported 0.37s against a
# neighbouring 78.62s for exactly this reason, and 0.37 looks like a spectacular
# result rather than a cache hit. `seed-base` exists so each phase of an A/B can
# occupy its own seed range.
set -u

HOST=${1:-}
RUNS=${2:-3}
SEEDBASE=${3:-100}
# The workflow ships beside this script, the way flux-schnell-bench.json does: a
# benchmark whose graph lives only on one machine's data volume is a benchmark
# nobody else can reproduce.
WF=${WF:-$(dirname "$0")/hunyuan3d-image-to-mesh.json}

die() { echo "bench3d: $*" >&2; exit 2; }

command -v jq >/dev/null || die "jq is not on PATH. On NixOS: nix shell nixpkgs#jq -c bash $0 $*"

if [ -z "$HOST" ]; then
  for cand in http://127.0.0.1:8188 http://10.100.0.2:8188; do
    curl -sf -o /dev/null --max-time 4 "$cand/system_stats" && { HOST=$cand; break; }
  done
  [ -n "$HOST" ] || die "no ComfyUI answered on 127.0.0.1:8188 or 10.100.0.2:8188"
else
  curl -sf -o /dev/null --max-time 4 "$HOST/system_stats" || die "$HOST did not answer"
fi
[ -r "$WF" ] || die "workflow not readable: $WF (override with WF=...)"

# The checkpoint and the subject image both have to be present, or this measures
# a refusal rather than a generation.
curl -s --max-time 10 "$HOST/object_info/CheckpointLoaderSimple" \
  | jq -e '.CheckpointLoaderSimple.input.required.ckpt_name[0] | index("hunyuan3d-dit-v2.safetensors")' \
  >/dev/null 2>&1 || die "$HOST cannot load hunyuan3d-dit-v2.safetensors"
subject=$(jq -r '.["1"].inputs.image' "$WF")
curl -s --max-time 10 "$HOST/object_info/LoadImage" \
  | jq -e --arg s "$subject" '.LoadImage.input.required.image[0] | index($s)' \
  >/dev/null 2>&1 || die "subject image $subject is not in ComfyUI's input directory"

echo "# host $HOST"
echo "# workflow $WF  subject $subject  seeds $((SEEDBASE+1))..$((SEEDBASE+RUNS))"
echo "run,seconds"
errs=0
for i in $(seq 1 "$RUNS"); do
  body=$(jq -c --argjson seed "$((SEEDBASE+i))" '.["6"].inputs.seed=$seed | {prompt: .}' "$WF")
  t0=$(date +%s%3N)
  id=$(curl -s -X POST "$HOST/prompt" -d "$body" | jq -r '.prompt_id // empty')
  if [ -z "$id" ]; then
    echo "run$i,ERR"
    errs=$((errs+1))
    continue
  fi
  while [ "$(curl -s "$HOST/history/$id" | jq -r --arg id "$id" 'has($id)')" != "true" ]; do
    sleep 2
  done
  t1=$(date +%s%3N)
  echo "run$i,$(awk "BEGIN{printf \"%.2f\", ($t1-$t0)/1000}")"
done

if [ "$errs" -gt 0 ]; then
  echo "bench3d: $errs of $RUNS runs failed to submit" >&2
  exit 1
fi
echo "# ok: $RUNS run(s). Run 1 includes load-to-VRAM; compare steady state, not run 1."
