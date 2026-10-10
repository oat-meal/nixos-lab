# RAG (local memory)

Retrieval-augmented generation over the lab's own stack: embeddings via Ollama
(`nomic-embed-text`), vector store in ChromaDB (`10.100.0.2:8000`), answers from a local model.
Stdlib-only Python over HTTP APIs.

## Usage (server, or any host on the mesh with python3)

```sh
python3 rag.py ingest <file> [<file> ...]   # chunk + embed + store
python3 rag.py query "your question"        # retrieve top-k + grounded answer
python3 rag.py reset                         # drop the collection
```

Env: `OLLAMA_HOST` (default `10.100.0.2:11434`), `CHROMA_HOST` (default `10.100.0.2:8000`),
`RAG_ANSWER_MODEL` (default `qwen2.5:7b`), `RAG_EMBED_MODEL` (default `nomic-embed-text`).

## How it works
- `ingest`: splits each file into ~1200-char chunks, embeds each, stores in the `lab` collection
  with source metadata.
- `query`: embeds the question, pulls the top-k nearest chunks, and asks the answer model to
  respond using only that context.

## Notes
- Chroma data persists in `/var/lib/chromadb` on the server (small; models keep the `/storage`
  dataset).
- Wrapped as `lab-rag`; deep-research is in `ai-lab/research/`.
