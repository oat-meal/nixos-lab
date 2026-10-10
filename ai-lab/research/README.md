# Deep-research

Search the self-hosted SearXNG, then have a local model synthesize a **cited** answer from the
results. Stdlib-only Python over HTTP.

## Usage

```sh
python3 research.py "your question"
python3 research.py --k 8 --model llama3.3:70b "your question"
```

Env: `SEARX_HOST` (default `10.100.0.2:8888`), `OLLAMA_HOST` (default `10.100.0.2:11434`).
Default synthesizer is `llama3.3:70b` (quality); use `qwen2.5:7b` for speed.

## How it works
1. Query SearXNG (`format=json`), keep the top-k results that have a snippet.
2. Feed numbered sources (title/url/snippet) to the model, which answers with inline `[n]` cites.

## Notes
- Uses SearXNG result snippets (no page fetching) — fast and dependency-free. A future version
  could fetch + extract full pages for deeper synthesis.
- SearXNG serves API engines only (crossref, openalex, wikipedia, arxiv, pubmed …); general web
  engines are disabled — see `docs/searxng-engines-degraded.md`.
