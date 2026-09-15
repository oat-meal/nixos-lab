#!/usr/bin/env bash
# ComfyUI SDXL image-gen benchmark: end-to-end seconds/image per checkpoint.
# Cold = first gen after checkpoint switch (includes load-to-VRAM);
# warm = second gen with checkpoint resident. 1024x1024, fixed steps/seed/prompt.
#
# Usage:  bench.sh [host] [workflow.json]
#   host      defaults to the wg0 address the container actually binds
#   workflow  defaults to the templates directory on the ComfyUI dataset
#
# ⚠️ THIS SCRIPT HAD NEVER RUN ON server-nixos, AND SAID SO IN A FORMAT THAT READS
# LIKE DATA. Three independent reasons, found 2026-09-15 while A/B testing ROCm
# tuning flags:
#
#   1. `jq` is not installed on that host, so every jq call failed;
#   2. the default workflow path pointed at ai-lab/comfyui/workflows/, which is
#      gitignored data present only on the workstation checkout;
#   3. the default host was 127.0.0.1:8188 and the container publishes
#      10.100.0.2:8188 ONLY -- `ss -ltnp` shows one listener, and loopback
#      returns nothing at all.
#
# Through all three it printed `sd_xl_base_1.0,ERR,ERR` and exited 0. A CSV row
# saying ERR is still a row: it has the checkpoint name in the right column and
# scrolls past as a result. So the fixes below are as much about failing loudly
# as about the defaults -- preflight checks that stop before measuring nothing,
# and a non-zero exit when any cell is ERR.
set -u

HOST=${1:-}
WF=${2:-}

die() { echo "bench: $*" >&2; exit 2; }

# ── preflight: refuse to measure nothing ────────────────────────────────────
command -v jq >/dev/null || die "jq is not on PATH. On NixOS: nix shell nixpkgs#jq -c bash $0 $*"
command -v curl >/dev/null || die "curl is not on PATH"

# The host is PROBED rather than assumed, because the binding is the thing this
# script got wrong. Loopback first (a dev box may publish there), then wg0.
if [ -z "$HOST" ]; then
  for cand in http://127.0.0.1:8188 http://10.100.0.2:8188; do
    if curl -sf -o /dev/null --max-time 4 "$cand/system_stats"; then HOST=$cand; break; fi
  done
  [ -n "$HOST" ] || die "no ComfyUI answered on 127.0.0.1:8188 or 10.100.0.2:8188"
else
  curl -sf -o /dev/null --max-time 4 "$HOST/system_stats" || die "$HOST did not answer /system_stats"
fi

if [ -z "$WF" ]; then
  for cand in \
    "$(dirname "$0")/../comfyui/workflows/openwebui-text2img.json" \
    /storage/comfyui/workflow-templates/openwebui-text2img.json
  do
    [ -r "$cand" ] && { WF=$cand; break; }
  done
fi
[ -n "$WF" ] && [ -r "$WF" ] || die "no readable workflow; pass one as \$2"
jq -e . "$WF" >/dev/null 2>&1 || die "$WF is not valid JSON"

CKPTS=("sd_xl_base_1.0.safetensors" "Juggernaut-XL_v9.safetensors" "Illustrious-XL-v1.0.safetensors")
STEPS=30; W=1024; H=1024
POS="a detailed landscape photograph of a mountain lake at sunrise, mist, reflections"
NEG="blurry, low quality, watermark, text"

# ⚠️ A CHECKPOINT THE SERVER DOES NOT HAVE WOULD MEASURE A REFUSAL. Ask it.
have=$(curl -s --max-time 10 "$HOST/object_info/CheckpointLoaderSimple" \
  | jq -r '.CheckpointLoaderSimple.input.required.ckpt_name[0][]' 2>/dev/null)
missing=0
for c in "${CKPTS[@]}"; do
  grep -qxF "$c" <<<"$have" || { echo "bench: $HOST cannot load $c" >&2; missing=$((missing+1)); }
done
[ "$missing" -eq 0 ] || die "$missing of ${#CKPTS[@]} checkpoints are absent on the server"

submit() { # $1=ckpt $2=seed -> prompt_id
  local body
  body=$(jq -c --arg c "$1" --argjson seed "$2" --argjson steps "$STEPS" \
    --argjson w "$W" --argjson h "$H" --arg pos "$POS" --arg neg "$NEG" \
    '.["4"].inputs.ckpt_name=$c
     | .["3"].inputs.seed=$seed | .["3"].inputs.steps=$steps
     | .["5"].inputs.width=$w | .["5"].inputs.height=$h
     | .["6"].inputs.text=$pos | .["7"].inputs.text=$neg
     | {prompt: .}' "$WF")
  curl -s -X POST "$HOST/prompt" -d "$body" | jq -r '.prompt_id // empty'
}
run() { # $1=ckpt $2=seed -> seconds
  local t0 t1 id
  t0=$(date +%s%3N)
  id=$(submit "$1" "$2")
  { [ -z "$id" ] || [ "$id" = "null" ]; } && { echo "ERR"; return; }
  while [ "$(curl -s "$HOST/history/$id" | jq -r --arg id "$id" 'has($id)')" != "true" ]; do
    sleep 0.25
  done
  t1=$(date +%s%3N)
  awk "BEGIN{printf \"%.2f\", ($t1-$t0)/1000}"
}

echo "# host $HOST"
echo "# workflow $WF"
echo "checkpoint,cold_s,warm_s (${W}x${H}, ${STEPS} steps, dpmpp_2m/karras)"
errs=0
for c in "${CKPTS[@]}"; do
  cold=$(run "$c" 111); warm=$(run "$c" 222)
  [ "$cold" = "ERR" ] && errs=$((errs+1))
  [ "$warm" = "ERR" ] && errs=$((errs+1))
  echo "${c%.safetensors},$cold,$warm"
done

# ⚠️ THE EXIT CODE IS THE POINT. Printing ERR in a CSV cell and exiting 0 is how
# this script reported three different total failures as a table for months.
if [ "$errs" -gt 0 ]; then
  echo "bench: $errs of $(( ${#CKPTS[@]} * 2 )) measurements failed" >&2
  exit 1
fi
echo "# ok: $(( ${#CKPTS[@]} * 2 )) measurements over ${#CKPTS[@]} checkpoint(s)"
