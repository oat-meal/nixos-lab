"""HY-Motion text-to-motion, as a long-running HTTP service.

WHY A SERVICE AND NOT A COMMAND. The upstream CLI (`local_infer.py`) works, and
it exits 139 every single time -- a segmentation fault at interpreter teardown,
AFTER the artefacts are written. Measured 2026-09-15: a script that loads the
runtime once and generates twice printed "REACHED END OF MAIN" and then exited
139, with both outputs present and correct on disk.

So a caller that spawns the CLI can never use the exit code: a teardown crash
and a genuine failure are the same 139, and the only way to tell them apart is
to go looking for files. A process that does not exit never reaches teardown,
which removes the defect rather than working around it.

⚠️ THE OTHER ARGUMENT FOR A SERVICE -- AMORTISING MODEL LOAD -- DOES NOT HOLD
HERE, AND IT IS WRITTEN DOWN SO NOBODY RE-DERIVES IT. Load is 5.3s against ~52s
per generation, because both LLM stages are disabled (see below) and so neither
Qwen3-8B nor the 45 GB prompt module is ever read. Spawning per request would
cost about 10%, not the 10x an unmeasured guess suggested. The reasons that
survive measurement are the exit code above, the resident-memory cost of
concurrent spawns, and matching the HTTP contract the rest of this lab uses.

⚠️ BOTH LLM STAGES ARE OFF, AND NOT BY PREFERENCE. `bitsandbytes` 4-bit
quantisation segfaults on ROCm/gfx1151, and upstream's own flag logic is
`call_llm = not disable_rewrite or not disable_duration_est` -- an `or`, so
disabling one stage leaves the LLM loaded and still crashes. Both must be off,
which is what `disable_prompt_engineering=True` does in one argument. The cost
is that the caller supplies the duration instead of having it estimated, and
the prompt reaches the model as written rather than rewritten.

⚠️ CPU, NOT GPU. The GPU path segfaults on this hardware (gfx1151, Strix Halo);
the model is built against CUDA. `force_cpu` is a first-class constructor
argument upstream, so this is a supported configuration rather than a hack.
~52s per 4-second clip. If a future ROCm or upstream release fixes the GPU path,
FORCE_CPU=0 is the only change needed here.

This binds on the wireguard address by default, exactly as ComfyUI does, and has
no authentication -- the private network is the boundary. Do not publish it.
"""

import os
import os.path as osp
import threading
import time
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

ROOT = os.environ.get("HY_MOTION_ROOT", "/storage/hy-motion")
MODEL_DIR = os.environ.get("HY_MOTION_MODEL", osp.join(ROOT, "ckpts/tencent/HY-Motion-1.0"))
OUT_DIR = os.environ.get("HY_MOTION_OUT", osp.join(ROOT, "out-service"))
FORCE_CPU = os.environ.get("HY_MOTION_FORCE_CPU", "1") != "0"

# ⚠️ UPSTREAM RESOLVES ASSETS RELATIVE TO THE CURRENT DIRECTORY, AND THAT IS WHY
# THIS LINE EXISTS. Loading the runtime reads
# `scripts/gradio/static/assets/dump_wooden/v_template.bin` as a relative path.
# The CLI never noticed because it is always run from inside the checkout; the
# service is not, so the first real request failed with a FileNotFoundError
# naming a path that plainly exists. Found by driving the assembled service over
# HTTP -- nothing in the code reads wrongly, and no import or unit test would
# have caught it, because the defect only exists when the cwd differs.
os.chdir(ROOT)

os.makedirs(OUT_DIR, exist_ok=True)

app = FastAPI(title="hy-motion")

# ⚠️ ONE LOCK, AND IT IS LOAD-BEARING. Generation is CPU-bound and saturates the
# machine; FastAPI runs a `def` endpoint in a threadpool, so without this two
# requests would interleave and both would be slower than running in sequence.
# The lock also protects the runtime, which upstream pools internally but does
# not document as thread-safe.
_lock = threading.Lock()
_runtime = None
_runtime_error: Optional[str] = None
_load_seconds: Optional[float] = None
_generated = 0
_waiting = 0


def _get_runtime():
    """Load on first use, once.

    ⚠️ A FAILED LOAD IS RECORDED BUT NOT STICKY, AND THE FIRST VERSION GOT THIS
    WRONG. It refused every later request with the first error it had ever seen,
    so a fixable condition -- a weights volume not yet mounted, a file being
    written as the service started -- would brick the service until someone
    restarted it by hand, while `Restart=on-failure` never fired because the
    process was perfectly healthy. The error is kept for /health to report; the
    next request tries again.
    """
    global _runtime, _runtime_error, _load_seconds
    if _runtime is not None:
        return _runtime
    from hymotion.utils.t2m_runtime import T2MRuntime

    cfg = osp.join(MODEL_DIR, "config.yml")
    ckpt = osp.join(MODEL_DIR, "latest.ckpt")
    for path in (cfg, ckpt):
        if not osp.exists(path):
            _runtime_error = f"missing {path}"
            raise RuntimeError(_runtime_error)
    t0 = time.time()
    try:
        rt = T2MRuntime(
            config_path=cfg,
            ckpt_name=ckpt,
            device_ids=None,
            force_cpu=FORCE_CPU,
            disable_prompt_engineering=True,
        )
        rt.load()
    except Exception as e:  # noqa: BLE001 -- the reason is the product here
        _runtime_error = f"{type(e).__name__}: {e}"
        raise
    _load_seconds = time.time() - t0
    _runtime = rt
    _runtime_error = None  # a later success must clear an earlier failure
    return _runtime


class GenerateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=2000)
    # ⚠️ REQUIRED-WITH-A-DEFAULT IS A LIE WHEN THE ESTIMATOR IS OFF. Upstream
    # would normally infer duration with an LLM; that stage is disabled, so this
    # value is used verbatim and the caller owns it.
    duration: float = Field(default=4.0, gt=0.4, le=20.0)
    seed: int = Field(default=42, ge=0)
    cfg_scale: float = Field(default=5.0, gt=0.0, le=20.0)
    output_format: str = Field(default="fbx", pattern="^(fbx|npz)$")


@app.get("/health")
def health():
    """Answers without loading the model, so it is usable as a readiness probe."""
    return {
        "ok": _runtime_error is None,
        "loaded": _runtime is not None,
        "load_seconds": _load_seconds,
        "device": "cpu" if FORCE_CPU else "gpu",
        "model_dir": MODEL_DIR,
        "model_present": osp.exists(osp.join(MODEL_DIR, "latest.ckpt")),
        "generated": _generated,
        "waiting": _waiting,
        "error": _runtime_error,
    }


@app.post("/generate")
def generate(req: GenerateRequest):
    global _generated, _waiting
    stem = f"g{int(time.time() * 1000)}_{req.seed}"
    # `counted` rather than a bare decrement inside the lock: a request that
    # never acquires the lock would otherwise leak the counter upward forever,
    # and a queue depth that only grows is worse than no queue depth at all.
    _waiting += 1
    counted = True
    try:
        with _lock:
            _waiting -= 1
            counted = False
            try:
                runtime = _get_runtime()
            except Exception as e:  # noqa: BLE001
                raise HTTPException(status_code=503, detail=f"runtime unavailable: {e}")
            t0 = time.time()
            try:
                runtime.generate_motion(
                    text=req.text,
                    seeds_csv=str(req.seed),
                    duration=req.duration,
                    cfg_scale=req.cfg_scale,
                    output_format=req.output_format,
                    output_dir=OUT_DIR,
                    output_filename=stem,
                )
            except HTTPException:
                raise
            except Exception as e:  # noqa: BLE001
                raise HTTPException(status_code=500, detail=f"{type(e).__name__}: {e}")
            seconds = time.time() - t0
            _generated += 1
    finally:
        if counted:
            _waiting -= 1

    # ⚠️ REPORT WHAT IS ON DISK, NOT WHAT WAS ASKED FOR. Upstream writes an .npz
    # beside every .fbx and names files with its own suffixes; a response that
    # echoed the request would claim artefacts that may not exist.
    produced = sorted(f for f in os.listdir(OUT_DIR) if f.startswith(stem))
    if not produced:
        raise HTTPException(status_code=500, detail="generation reported success but wrote nothing")
    return {
        "files": produced,
        "seconds": round(seconds, 2),
        "text": req.text,
        "duration": req.duration,
        "seed": req.seed,
        "device": "cpu" if FORCE_CPU else "gpu",
    }


@app.get("/file/{name}")
def file(name: str):
    """Serve one produced artefact.

    ⚠️ THE CALLER IS ON ANOTHER MACHINE, so this is not a convenience. Without it
    the contract would require a shared filesystem, which the toolkit does not
    assume and a teammate on a laptop does not have.
    """
    # basename first, then containment: the second check is what actually holds,
    # and it holds even if the first is ever relaxed.
    safe = osp.basename(name)
    path = osp.realpath(osp.join(OUT_DIR, safe))
    if not path.startswith(osp.realpath(OUT_DIR) + os.sep) or not osp.isfile(path):
        raise HTTPException(status_code=404, detail="no such artefact")
    return FileResponse(path, filename=safe)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("HY_MOTION_HOST", "10.100.0.2"),
        port=int(os.environ.get("HY_MOTION_PORT", "8190")),
        log_level="info",
    )
