# Phase 0 — Project Foundation & Development Setup

**Status:** Complete
**Depends on:** None

## Overview

Established the baseline development environment: a Next.js frontend, a FastAPI backend, and a local LLM (Ollama running Qwen3 8B), with verified connectivity between all three. No research logic, LangGraph, or external research tools exist yet — this phase only proves the plumbing works.

## What Was Implemented

- Git repo with `frontend/` and `backend/` as separate top-level app layers
- FastAPI backend with a `/health` endpoint
- Next.js (App Router) + Tailwind frontend with a test page that calls the backend
- Python virtual environment for the backend, with dependencies tracked in `requirements.txt`
- Ollama installed locally, `qwen3:8b` pulled
- `/health/llm` backend endpoint that round-trips a prompt through Ollama to confirm the model responds via code (not just the CLI)
- `.env.example` (backend) and `.env.local.example` (frontend) as config templates
- `.gitignore` covering venv, node_modules, .next, and all `.env` variants

## Important Code/Config Explanations

- **CORS is hardcoded to `http://localhost:3000` in `main.py`.** This is intentional for local dev — it will need to become an environment-driven setting before any deployment, but for MVP local use a hardcoded origin is simpler and avoids accidentally leaving `*` open.
- **`/health/llm` exists separately from `/health`.** `/health` only proves FastAPI is alive; `/health/llm` proves the *entire* LLM chain (backend → Ollama → model → response parsing) works. Keeping them separate makes it obvious which layer failed if something breaks in a later phase.
- **The model is called directly with `ollama.chat(model="qwen3:8b", ...)` inline in `main.py` for now.** This is deliberately temporary — Phase 2 replaces this with a reusable LLM service module. Don't build on top of this inline call; it exists only to prove connectivity.
- **`qwen3:8b` is the fixed model choice for this project**, despite the original PRD text referencing 14B — 8B is what's actually configured in Ollama and referenced in `.env.example`. Keep this consistent in all future phases.
- **No database, no Docker, no LangGraph** — all explicitly out of scope until later phases (LangGraph starts Phase 3, Docker is deferred to V1).

## Dependencies/Tools Added

**Backend (`requirements.txt`):**
- `fastapi`
- `uvicorn`
- `python-dotenv`
- `pydantic`
- `ollama`

**Frontend:** default `create-next-app` deps (TypeScript, Tailwind, ESLint) — nothing extra added yet.

**System-level:** Ollama (local install), `qwen3:8b` model pulled via `ollama pull qwen3:8b`.

## How to Run / Verify This Phase

Two long-running terminals, plus a spare for one-off commands:

**Terminal 1 — Backend**
```bash
cd backend
source venv/bin/activate
uvicorn main:app --reload --port 8000
```

**Terminal 2 — Frontend**
```bash
cd frontend
npm run dev
```

**Verification checklist:**
- [ ] `http://localhost:8000/health` → `{"status":"ok"}`
- [ ] `http://localhost:8000/health/llm` → `{"status":"ok","model":"qwen3:8b","reply":"..."}`
- [ ] `http://localhost:3000` loads, clicking "Check backend connection" shows `backend says: ok`
- [ ] `ollama run qwen3:8b "..."` responds directly from CLI
- [ ] `git status` shows no `.env` files staged
