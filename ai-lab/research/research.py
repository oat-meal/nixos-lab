#!/usr/bin/env python3
"""Deep-research — search the self-hosted SearXNG, then have a local model
synthesize a cited answer from the results. Stdlib only.

Usage:
    python3 research.py "your question" [--k 6] [--model llama3.3:70b]

Env: SEARX_HOST (default 10.100.0.2:8888), OLLAMA_HOST (default 10.100.0.2:11434).
"""

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
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

SEARX = f"http://{os.environ.get('SEARX_HOST', '10.100.0.2:8888')}"
OLLAMA = f"http://{os.environ.get('OLLAMA_HOST', '10.100.0.2:11434')}"


def search(q: str, k: int) -> list[dict]:
    url = f"{SEARX}/search?{urllib.parse.urlencode({'q': q, 'format': 'json'})}"
    with urllib.request.urlopen(url, timeout=30) as r:
        results = json.loads(r.read()).get("results", [])
    # Keep the top-k that actually have a snippet.
    out = []
    for res in results:
        if res.get("content"):
            out.append({"title": res.get("title", ""), "url": res.get("url", ""),
                        "content": res["content"]})
        if len(out) >= k:
            break
    return out


def synthesize(question: str, sources: list[dict], model: str) -> str:
    refs = "\n".join(
        f"[{i+1}] {s['title']} ({s['url']})\n{s['content']}" for i, s in enumerate(sources)
    )
    prompt = (
        f"Using the numbered web sources below, write a concise, accurate answer to the "
        f"question. Cite sources inline as [n]. If sources conflict or are insufficient, "
        f"say so.\n\nQuestion: {question}\n\nSources:\n{refs}\n\nAnswer:"
    )
    body = json.dumps({"model": model, "prompt": prompt, "stream": False}).encode()
    req = urllib.request.Request(f"{OLLAMA}/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return strip_reasoning(json.loads(r.read())["response"])


def main() -> int:
    ap = argparse.ArgumentParser(description="Deep-research via SearXNG + local model")
    ap.add_argument("question")
    ap.add_argument("--k", type=int, default=6, help="number of sources")
    ap.add_argument("--model", default="llama3.3:70b", help="synthesizer model")
    args = ap.parse_args()

    sources = search(args.question, args.k)
    if not sources:
        print("No search results (SearXNG returned nothing usable).")
        return 1
    print(f"== {len(sources)} sources ==")
    for i, s in enumerate(sources):
        print(f"  [{i+1}] {s['title'][:70]}  {s['url']}")
    print(f"\n== Answer ({args.model}) ==\n{synthesize(args.question, sources, args.model)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
