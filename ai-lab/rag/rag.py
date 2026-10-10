#!/usr/bin/env python3
"""Minimal RAG over the lab's local stack — embeddings via Ollama (nomic-embed-text),
vector store in ChromaDB, answers from a local model. Stdlib only.

Usage:
    python3 rag.py ingest <file> [<file> ...]
    python3 rag.py query "your question"
    python3 rag.py reset

Env: OLLAMA_HOST (default 10.100.0.2:11434), CHROMA_HOST (default 10.100.0.2:8000).
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request

# Ollama 0.40 + qwen3 can return reasoning inside the answer even with think:false —
# either a full <think>…</think> block or reasoning ending in a bare </think> (seen
# 2026-10-10). Keep only what follows it. A no-op for models that never emit it.
_THINK_BLOCK = re.compile(r"(?s)<think>.*?</think>")


def strip_reasoning(text: str) -> str:
    text = _THINK_BLOCK.sub("", text)
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    return text.strip()

OLLAMA = f"http://{os.environ.get('OLLAMA_HOST', '10.100.0.2:11434')}"
CHROMA = f"http://{os.environ.get('CHROMA_HOST', '10.100.0.2:8000')}"
EMBED_MODEL = os.environ.get("RAG_EMBED_MODEL", "nomic-embed-text")
ANSWER_MODEL = os.environ.get("RAG_ANSWER_MODEL", "qwen2.5:7b")
COLLECTION = "lab"
TENANT, DB = "default_tenant", "default_database"
COLL_BASE = f"{CHROMA}/api/v2/tenants/{TENANT}/databases/{DB}/collections"


def _req(url, payload=None, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        body = r.read()
        return json.loads(body) if body else {}


def embed(text: str) -> list[float]:
    r = _req(f"{OLLAMA}/api/embeddings", {"model": EMBED_MODEL, "prompt": text})
    return r["embedding"]


def collection_id() -> str:
    # get_or_create is idempotent: returns the existing collection's id, or makes it.
    r = _req(COLL_BASE, {"name": COLLECTION, "get_or_create": True})
    return r["id"]


def chunk(text: str, size: int = 1200) -> list[str]:
    # Split on blank lines, then pack paragraphs up to ~size chars.
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks, cur = [], ""
    for p in paras:
        if len(cur) + len(p) + 1 > size and cur:
            chunks.append(cur)
            cur = p
        else:
            cur = f"{cur}\n{p}" if cur else p
    if cur:
        chunks.append(cur)
    return chunks


def ingest(paths: list[str]) -> int:
    cid = collection_id()
    total = 0
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        chunks = chunk(text)
        ids, embs, docs, metas = [], [], [], []
        for i, c in enumerate(chunks):
            cid_hash = hashlib.sha1(f"{path}:{i}:{c}".encode()).hexdigest()
            ids.append(cid_hash)
            embs.append(embed(c))
            docs.append(c)
            metas.append({"source": os.path.basename(path), "chunk": i})
        _req(f"{COLL_BASE}/{cid}/add",
             {"ids": ids, "embeddings": embs, "documents": docs, "metadatas": metas})
        print(f"  ingested {len(chunks):3d} chunks from {path}")
        total += len(chunks)
    print(f"== {total} chunks in collection '{COLLECTION}' ==")
    return 0


def query(question: str, k: int = 4) -> int:
    cid = collection_id()
    res = _req(f"{COLL_BASE}/{cid}/query",
               {"query_embeddings": [embed(question)], "n_results": k,
                "include": ["documents", "metadatas", "distances"]})
    docs = res.get("documents", [[]])[0]
    metas = res.get("metadatas", [[]])[0]
    if not docs:
        print("No matches — ingest some documents first.")
        return 1
    print(f"== {len(docs)} retrieved chunks ==")
    for d, m in zip(docs, metas):
        print(f"  [{m.get('source')}#{m.get('chunk')}] {d[:80].strip()}...")
    context = "\n\n".join(f"[{m.get('source')}] {d}" for d, m in zip(docs, metas))
    prompt = (
        f"Answer the question using ONLY the context below. If the context is "
        f"insufficient, say so.\n\nContext:\n{context}\n\nQuestion: {question}\n\nAnswer:"
    )
    ans = _req(f"{OLLAMA}/api/generate",
               {"model": ANSWER_MODEL, "prompt": prompt, "stream": False})["response"]
    ans = strip_reasoning(ans)
    print(f"\n== Answer ({ANSWER_MODEL}) ==\n{ans.strip()}")
    return 0


def reset() -> int:
    try:
        _req(f"{COLL_BASE}/{COLLECTION}", method="DELETE")
        print(f"deleted collection '{COLLECTION}'")
    except Exception as e:  # noqa: BLE001
        print(f"(nothing to delete: {e})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Local RAG (Ollama + ChromaDB)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pi = sub.add_parser("ingest"); pi.add_argument("files", nargs="+")
    pq = sub.add_parser("query"); pq.add_argument("question")
    sub.add_parser("reset")
    args = ap.parse_args()
    if args.cmd == "ingest":
        return ingest(args.files)
    if args.cmd == "query":
        return query(args.question)
    if args.cmd == "reset":
        return reset()
    return 2


if __name__ == "__main__":
    sys.exit(main())
