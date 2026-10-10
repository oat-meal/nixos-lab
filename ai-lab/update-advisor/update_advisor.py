#!/usr/bin/env python3
"""Update advisor — preview what `nix flake update` would change and summarize the
risk with a local LLM. READ-ONLY: it updates a throwaway copy of the flake, never
the real /etc/nixos, and never switches anything. Meant to run weekly.

Compares the current flake.lock against a fresh `nix flake update` of a clean
`git archive` copy, reports which direct inputs would bump (and over how long a
span), and asks qwen3 for a risk briefing tuned to this AMD ROCm + gaming lab.

Env: NIXOS_DIR, OLLAMA_HOST_URL, ADVISOR_MODEL, ADVISOR_REPORT, NTFY_URL.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime
import re

# Ollama 0.40 + qwen3 can return reasoning inside the answer even with think:false —
# either a full <think>…</think> block or reasoning ending in a bare </think> (seen
# 2026-10-10). Keep only what follows it. A no-op for models that never emit it.
_THINK_BLOCK = re.compile(r"(?s)<think>.*?</think>")


def strip_reasoning(text: str) -> str:
    text = _THINK_BLOCK.sub("", text)
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    return text.strip()


def parse_json_reply(text: str):
    """JSON from an LLM reply: reasoning stripped; prose around the object tolerated."""
    text = strip_reasoning(text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        i, j = text.find("{"), text.rfind("}")
        if i != -1 and j > i:
            return json.loads(text[i:j + 1])
        raise

NIXOS = os.environ.get("NIXOS_DIR", "/etc/nixos")
OLLAMA = os.environ.get("OLLAMA_HOST_URL", "http://10.100.0.2:11434")
MODEL = os.environ.get("ADVISOR_MODEL", "qwen3:30b-a3b")
REPORT = os.environ.get("ADVISOR_REPORT", "/var/lib/update-advisor/latest.md")
NTFY = os.environ.get("NTFY_URL", "")


# Accurate descriptions so the LLM doesn't guess what obscure inputs are.
INPUT_DESC = {
    "nixpkgs": "NixOS STABLE package channel — carries the kernel, Mesa/graphics, and ComfyUI's ROCm deps",
    "nixpkgs-unstable": "bleeding-edge channel, used via overlay — notably ollama-rocm (the AMD LLM runtime)",
    "home-manager": "user-level dotfile/config management",
    "mango": "MangoWM — the dwl-based Wayland compositor (window manager). Desktop UI only.",
    "noctalia": "the Noctalia desktop shell (bar/notifications/launcher). Desktop UI only.",
    "zen-browser": "the Zen web browser. Low risk.",
    "sops-nix": "secrets management (decrypts secrets at activation). Low risk.",
}


def run(cmd, timeout=900):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def input_locks(path):
    """Direct root inputs -> {rev, lastModified} from a flake.lock."""
    with open(path) as f:
        lock = json.load(f)
    root = lock["nodes"][lock["root"]].get("inputs", {})
    out = {}
    for name, ref in root.items():
        nn = ref if isinstance(ref, str) else ref[0]
        loc = lock["nodes"].get(nn, {}).get("locked", {})
        if loc:
            out[name] = {"rev": (loc.get("rev") or loc.get("narHash", ""))[:12],
                         "lastModified": loc.get("lastModified", 0)}
    return out


def diff_updates():
    old = input_locks(f"{NIXOS}/flake.lock")
    tmp = tempfile.mkdtemp(prefix="update-advisor-")
    try:
        a = run(["bash", "-c", f"git -C {NIXOS} archive HEAD | tar -x -C {tmp}"])
        if a.returncode != 0:
            return None, f"git archive failed: {a.stderr[:200]}"
        run(["cp", f"{NIXOS}/flake.lock", f"{tmp}/flake.lock"])
        u = run(["nix", "flake", "update", "--flake", f"path:{tmp}"])
        if u.returncode != 0:
            return None, f"nix flake update failed: {u.stderr[:300]}"
        new = input_locks(f"{tmp}/flake.lock")
        changes = []
        for name, o in old.items():
            n = new.get(name)
            if n and n["rev"] != o["rev"]:
                days = ((n["lastModified"] - o["lastModified"]) / 86400
                        if o["lastModified"] and n["lastModified"] else 0)
                changes.append({"input": name, "what": INPUT_DESC.get(name, "(unknown input)"),
                                "old": o["rev"], "new": n["rev"], "days_span": round(days, 1)})
        return changes, None
    finally:
        run(["rm", "-rf", tmp], timeout=30)


SYSTEM = """You advise on NixOS flake updates for a personal home lab: an AMD ROCm inference stack \
(ollama-rocm on a gfx1151 iGPU, ComfyUI on a gfx1201/RDNA4 GPU), a gaming workstation (latest kernel, \
Mesa), a headless server, and a laptop. The sensitive changes are ROCm / kernel / Mesa / graphics.

You are given the inputs `nix flake update` would bump, EACH WITH AN ACCURATE DESCRIPTION — use the \
description; do NOT guess or invent what an input is. Assess the practical risk for THIS setup: a \
concise risk line per input; an overall verdict (SAFE = routine, REVIEW = has kernel/graphics/ROCm \
changes worth reading release notes on, CAUTION = high chance of breaking inference or boot); and a \
short list of things to check after updating."""

BRIEF_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["SAFE", "REVIEW", "CAUTION"]},
        "per_input": {"type": "array", "items": {
            "type": "object",
            "properties": {"input": {"type": "string"}, "risk": {"type": "string"}},
            "required": ["input", "risk"]}},
        "watch": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["verdict", "per_input", "watch"],
}


def summarize(changes):
    body = {"model": MODEL, "stream": False, "think": False, "format": BRIEF_SCHEMA,
            "options": {"temperature": 0.2},
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": "Inputs that would update:\n"
                          + json.dumps(changes, indent=2)}]}
    req = urllib.request.Request(OLLAMA + "/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return parse_json_reply(json.load(r)["message"]["content"])


def main():
    ts = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    changes, err = diff_updates()
    if err:
        print(f"[update-advisor] {ts} ERROR — {err}")
        sys.exit(1)
    if not changes:
        report = f"# Update advisor — {ts}\n\nNo flake inputs would change; you're up to date.\n"
        verdict = "up-to-date"
    else:
        header = "\n".join(f"- **{c['input']}**: `{c['old']}` → `{c['new']}` (~{c['days_span']}d)"
                           for c in changes)
        try:
            b = summarize(changes)
            rows = "\n".join(f"| {p.get('input', '?')} | {p.get('risk', '')} |"
                             for p in b.get("per_input", []))
            watch = ", ".join(b.get("watch", [])) or "—"
            brief = (f"**Verdict: {b.get('verdict', '?')}**\n\n"
                     f"| Input | Risk |\n|---|---|\n{rows}\n\n"
                     f"**Watch after updating:** {watch}")
        except Exception as e:
            brief = f"(LLM summary failed: {e})"
        report = f"# Update advisor — {ts}\n\n{len(changes)} input(s) would update:\n\n{header}\n\n## Briefing\n\n{brief}\n"
        verdict = f"{len(changes)} updates available"

    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    with open(REPORT, "w") as f:
        f.write(report)
    print(f"[update-advisor] {ts} {verdict} -> {REPORT}")

    if NTFY and changes:
        try:
            req = urllib.request.Request(
                NTFY, data=f"{len(changes)} flake input(s) have updates. Review the advisor report.".encode(),
                headers={"Title": "Flake updates available", "Priority": "default", "Tags": "arrow_up"})
            urllib.request.urlopen(req, timeout=10)
        except Exception:
            pass


if __name__ == "__main__":
    main()
