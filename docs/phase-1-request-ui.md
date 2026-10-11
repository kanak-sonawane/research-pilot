# Phase 1 — Research Request UI & Backend Entry Point

**Status:** Complete
**Depends on:** Phase 0

## Overview

Established the first real request/response contract between frontend and backend: a form that submits a research topic, and a `POST /research` endpoint that validates it and returns a placeholder run. No LLM planning or orchestration yet — this phase only proves the request pipeline (UI → validation → structured response) works end to end.

## What Was Implemented

- `backend/app/schemas.py` — `ResearchRequest` (input) and `ResearchRunResponse` (output) Pydantic models
- `backend/app/routes.py` — `POST /research` endpoint, wired into `main.py` via `app.include_router(router)`
- `frontend/src/components/ResearchForm.tsx` — controlled input + submit button, calls the backend, shows loading/error/success states
- `frontend/src/app/page.tsx` — now renders `ResearchForm` instead of the Phase 0 connectivity-test button

## Important Code/Config Explanations

- **`ResearchRequest` strips and rejects blank queries via a `field_validator`.** The frontend also blocks empty submits, but the backend re-validates independently — never trust client-side checks alone, since the API can be hit directly.
- **`ResearchRunResponse` is deliberately generic (`run_id`, `status`, `query`, `message`) even though Phase 1 has nothing real to report.** The shape is meant to stay stable as later phases add fields (e.g. `plan`, `report`), so the frontend doesn't need a breaking rewrite each phase — new fields get added, not renamed.
- **`status: "received"` is a placeholder value.** Later phases will introduce real status transitions (e.g. `planning`, `researching`, `complete`) — don't hardcode against `"received"` anywhere in the frontend beyond this phase.
- **The router lives in `app/routes.py`, not directly in `main.py`.** `main.py` is kept as just app setup (CORS, router registration) so it doesn't grow unwieldy as more endpoints are added in later phases.
- **Known cosmetic issue (not fixed yet):** the result box text is low-contrast (light text on white). Flagged for a later UI polish pass, not blocking functionality.

## Dependencies/Tools Added

None beyond Phase 0 — this phase only added application code, no new packages.

## How to Run / Verify This Phase

Same two-terminal setup as Phase 0 (backend + frontend running concurrently).

**Verification checklist:**
- [ ] `http://localhost:3000` shows "Research Pilot" with a text input and "Start Research" button
- [ ] Submitting an empty query shows a client-side error, no network call made
- [ ] Submitting a real topic returns `run_id`, `status: received`, and the placeholder message
- [ ] `http://localhost:8000/docs` shows `POST /research` with `ResearchRequest`/`ResearchRunResponse` schemas listed

## Known Follow-ups

- Result box styling needs a contrast fix (low-priority, cosmetic)
