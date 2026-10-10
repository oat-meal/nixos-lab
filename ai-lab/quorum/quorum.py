#!/usr/bin/env python3
"""Model quorum — ask several local models the same question independently, then
reconcile their answers: agreement raises confidence, disagreement is flagged.
The point is cross-referencing to reduce hallucinations, not debate.

Stdlib only. Talks to Ollama's HTTP API over the WireGuard mesh.

Usage:
    OLLAMA_HOST=10.100.0.2:11434 python3 quorum.py "your question"
    python3 quorum.py --members qwen2.5:7b,llama3.3:70b "your question"
"""

import argparse
import json
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
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

HOST = os.environ.get("OLLAMA_HOST", "10.100.0.2:11434")
BASE = f"http://{HOST}"
DEFAULT_MEMBERS = ["qwen2.5:7b", "qwen2.5-coder:32b", "llama3.3:70b"]
DEFAULT_JUDGE = "llama3.3:70b"


def generate(model: str, prompt: str, timeout: int = 300) -> str:
    """One non-streaming completion from a model."""
    body = json.dumps({"model": model, "prompt": prompt, "stream": False}).encode()
    req = urllib.request.Request(
        f"{BASE}/api/generate", data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return strip_reasoning(json.loads(r.read())["response"])


def ask_member(model: str, question: str) -> tuple[str, str]:
    try:
        return model, generate(model, question)
    except Exception as e:  # noqa: BLE001 - report, don't crash the quorum
        return model, f"[error: {e}]"


def main() -> int:
    ap = argparse.ArgumentParser(description="Local model quorum (cross-reference for accuracy)")
    ap.add_argument("question", help="the prompt to put to the quorum")
    ap.add_argument("--members", help="comma-separated model list",
                    default=",".join(DEFAULT_MEMBERS))
    ap.add_argument("--judge", default=DEFAULT_JUDGE, help="reconciler model")
    args = ap.parse_args()

    members = [m.strip() for m in args.members.split(",") if m.strip()]
    print(f"== Quorum ({len(members)} members) on {HOST} ==\n")

    # Ask each member independently, concurrently.
    with ThreadPoolExecutor(max_workers=len(members)) as pool:
        answers = list(pool.map(lambda m: ask_member(m, args.question), members))

    for model, ans in answers:
        print(f"--- {model} ---\n{ans}\n")

    # Reconcile: cross-reference the independent answers, flag disagreement.
    transcript = "\n\n".join(f"### Answer from {m}:\n{a}" for m, a in answers)
    judge_prompt = (
        f"Question:\n{args.question}\n\n"
        f"{len(members)} models answered the question independently below. Cross-reference "
        f"them and produce the most accurate answer:\n"
        f"- Keep only claims corroborated across models or clearly correct.\n"
        f"- Explicitly flag where the models DISAGREE (treat those as low-confidence).\n"
        f"- Drop anything unsupported or contradicted — do not invent.\n\n"
        f"{transcript}\n\n### Reconciled answer (note any disagreements):"
    )
    print(f"== Reconciled answer (judge: {args.judge}) ==\n")
    try:
        print(generate(args.judge, judge_prompt))
    except Exception as e:  # noqa: BLE001
        print(f"[judge error: {e}]")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
