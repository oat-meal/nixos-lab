"""AI Lab OpenAPI tool server.

Exposes the local lab tools (model quorum, document RAG, deep web research) as
OpenAPI endpoints so Open WebUI's tool-calling (and any OpenAPI client) can invoke
them. Each tool shells out to the existing `ai-lab/*` CLI via interpreter + script
paths passed in the environment (set by the NixOS module). wg0-only.

The host-health tools are intentionally NOT here — they need system privileges and
live in the Claude Code MCP instead.
"""

import os
import subprocess

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(
    title="AI Lab Tools",
    version="1.0.0",
    description=(
        "Private, local lab tools running on the home server over WireGuard: "
        "multi-model quorum (cross-checked answers), document RAG, and deep web "
        "research with citations."
    ),
)

LAB_PY = os.environ.get("LAB_PY", "python3")


def run(script_env: str, *args: str, timeout: int = 900) -> str:
    """Run a lab CLI (interpreter + script path come from the environment)."""
    script = os.environ.get(script_env)
    if not script:
        return f"ERROR: {script_env} not configured"
    try:
        r = subprocess.run(
            [LAB_PY, script, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return (r.stdout.strip() or r.stderr.strip()) or "(no output)"
    except subprocess.TimeoutExpired:
        return f"ERROR: tool timed out after {timeout}s"


class Question(BaseModel):
    question: str


@app.post("/quorum", operation_id="lab_quorum", summary="Multi-model quorum (cross-checked answer)")
def quorum(body: Question):
    """Ask the same question to several local models independently, then reconcile
    their answers into one cross-referenced response to reduce hallucinations. Use
    for high-stakes or factual questions where accuracy matters more than speed."""
    return {"result": run("QUORUM_PY", "--", body.question)}


@app.post("/rag", operation_id="lab_rag_query", summary="Query the local document knowledge base (RAG)")
def rag(body: Question):
    """Answer a question grounded in the local ingested documents/notes
    (retrieval-augmented generation via ChromaDB + local embeddings). Use when the
    answer should come from the user's own knowledge base rather than general knowledge."""
    return {"result": run("RAG_PY", "query", "--", body.question)}


@app.post("/research", operation_id="lab_research", summary="Deep web research with citations")
def research(body: Question):
    """Search the web via the private SearXNG instance, read the top sources, and
    synthesize a cited answer. Use for current events or information likely outside
    the model's training data. May take up to a minute."""
    return {"result": run("RESEARCH_PY", "--", body.question)}


@app.get("/", include_in_schema=False)
def root():
    return {"status": "ok", "tools": ["lab_quorum", "lab_rag_query", "lab_research"]}
