# Style LoRA training (anime, Illustrious) — runbook

Trains an SDXL **style LoRA** (trigger `oatstyle`) from a folder of example images,
entirely local on `server-nixos` (gfx1151 / ROCm). One-off job in a podman container.

**Privacy:** every step runs in the container against the dataset by path; the curation
and trigger scripts print only aggregate counts, and the WD14 tagger (not a person)
reads the images to caption them. The dataset is never viewed outside the box.

## Layout
```
/storage/lora-training/anime-style/
  raw/        <- you dump the example images here (subfolders OK; recursed)
  curated/    <- created by step 2 (deduped/filtered, flat)
  output/     <- the trained LoRA(s) land here
  logs/
```

## One-time: build the trainer
```
cd /etc/nixos/ai-lab/lora-training && sudo podman build -t localhost/lora-trainer:v1 .
```
Ends with `torch OK: 2.9.1+rocm...` — that confirms the ROCm torch survived the kohya install.

## The run command (base)
All steps use this wrapper; only the final command changes:
```
sudo podman run --rm -it \
  --device=/dev/kfd --device=/dev/dri --group-add video --group-add render \
  --ipc=host --security-opt seccomp=unconfined \
  -e HSA_OVERRIDE_GFX_VERSION=11.0.0 \
  -v /storage/lora-training/anime-style:/data \
  -v /storage/comfyui/models/checkpoints:/base:ro \
  -v /etc/nixos/ai-lab/lora-training:/config:ro \
  localhost/lora-trainer:v1 \
  <COMMAND>
```

### Step 2 — curate  (`<COMMAND>` =)
```
python3 /config/curate.py /data/raw /data/curated
```
Dedups, drops too-small/corrupt, and **samples a balanced subset** (up to
`max_per_folder` per pose folder, capped to `target_total`). Defaults: target 800,
max 3/folder. Override: `... curate.py /data/raw /data/curated 600 2`.
Prints e.g. `scanned=6345 valid_after_filter=5900 groups=468 final_kept=800 …`.

### Step 3 — caption + trigger  (`<COMMAND>` =)
```
bash -lc 'python3 /opt/sd-scripts/finetune/tag_images_by_wd14_tagger.py --onnx --remove_underscore --batch_size 4 --caption_extension .txt --repo_id SmilingWolf/wd-v1-4-moat-tagger-v2 /data/curated && python3 /config/add_trigger.py /data/curated oatstyle'
```
First run downloads the WD14 tagger from HuggingFace (leaves the mesh, like any model pull).
Writes one `.txt` per image, then prepends `oatstyle,`.

### Step 4 — train  (`<COMMAND>` =)
```
accelerate launch --num_processes 1 --mixed_precision bf16 /opt/sd-scripts/sdxl_train_network.py --config_file /config/config.toml --dataset_config /config/dataset.toml
```
A few hours on the iGPU. Intermediate LoRAs save every 400 steps (`save_every_n_steps = 400`, `max_train_epochs = 1`) to `/data/output`.
**Avoid heavy ComfyUI/Ollama use during training** — they share the one GPU.

### Step 5 — use it
Copy the result into ComfyUI and load it in the `lora-text2img.json` workflow:
```
cp /storage/lora-training/anime-style/output/oatstyle.safetensors /storage/comfyui/models/loras/
```
In the workflow's **Load LoRA** node pick `oatstyle.safetensors`, and put **`oatstyle`** in
your prompt to invoke the style. Compare the intermediate checkpoints (`oatstyle-step00000400` etc.)
to find the sweet spot (too weak = undertrained, too rigid = overtrained).

## Notes / iteration
- ROCm *training* on gfx1151 is the least-proven piece here. If a step errors, paste the
  error text (no image data needed) and we tune the container/config.
- Tunables: `network_dim` (style strength/size), `max_train_epochs`, `learning_rate`,
  `num_repeats`. Defaults are a sane starting point for a style LoRA.
