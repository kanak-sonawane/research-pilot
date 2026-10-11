# Phase 2 — Ollama-Powered Planning

**Status:** Complete
**Depends on:** Phase 1

## Overview

This phase replaced the Phase 1 placeholder response with a real planning step powered by the local LLM (Qwen3 8B via Ollama). Given a raw research topic, the backend now produces a structured **objective** and a small set of **research questions** — this is the first point in the system where the LLM does actual reasoning rather than just being connectivity-tested.

This is also the phase that establishes the pattern every future LLM interaction will follow: a single call point, a strict system prompt demanding JSON, and defensive parsing on the way back out. Phases 4–7 (evidence extraction, sufficiency evaluation, report generation) will all reuse this same pattern rather than inventing a new one each time.

## Architecture / Flow Change

**Phase 1 flow:**
```
POST /research → validate query → return placeholder run_id/status
```

**Phase 2 flow:**
```
POST /research
  → validate query (ResearchRequest)
  → generate_plan(query)
      → call_llm(PLANNING_SYSTEM_PROMPT, query)   [app/llm_service.py]
      → Ollama (qwen3:8b) returns raw text
      → _extract_json() strips fences / finds {...} block
      → validate required keys exist
  → build Plan(objective, research_questions)
  → return ResearchRunResponse(status="planned", plan=Plan)
```

If planning fails at any point (bad/unparseable model output, missing keys), the endpoint does **not** 500 — it catches `PlanningError` and returns `status: "planning_failed"` with the failure reason in `message`, `plan: null`. This matters architecturally: from Phase 3 onward, orchestration logic (and eventually the frontend) can treat "the LLM didn't cooperate" as a normal, expected state to branch on, not an exception to catch ad hoc everywhere.

## Key Files / Components

### `backend/app/config.py`
Centralizes environment config (`OLLAMA_HOST`, `OLLAMA_MODEL`) via `python-dotenv`. Nothing else in the backend reads `os.environ` directly — everything imports from here, so there's one place to check/change model or host settings.

### `backend/app/llm_service.py`
```python
def call_llm(system_prompt: str, user_prompt: str) -> str:
    response = ollama.chat(model=OLLAMA_MODEL, messages=[...])
    return response["message"]["content"]
```
Deliberately thin — no retries, no streaming, no timeout handling yet. The point of this file isn't sophistication, it's that it's the **only** place in the codebase that calls `ollama.chat`. Every future feature that needs the LLM (source decisions, evidence evaluation, report writing) calls through here, so retry/timeout/logging can be added once, centrally, later — instead of duplicated across a dozen call sites.

### `backend/app/planning.py`
Two things worth calling out:

1. **`PLANNING_SYSTEM_PROMPT` hardcodes the JSON output contract** (`{"objective": "...", "research_questions": [...]}`) and caps questions at 3–5. This cap is intentional per the PRD's "small set of precise research questions" requirement — it stops the model from turning one topic into a 15-question sprawl that later phases would have to research against.

2. **`_extract_json()` doesn't trust the model to return clean JSON.** Even with explicit instructions, local models frequently wrap output in ` ```json ` fences or add a stray sentence before/after. Rather than fail on that, this function strips fences and regex-extracts the first `{...}` block before attempting `json.loads`. This is a defensive pattern, not a correctness guarantee — it will still fail (intentionally, as `PlanningError`) if the model returns something with no JSON object in it at all.

`generate_plan()` also validates that `research_questions` is a non-empty list and truncates to 5 even if the model ignores the cap — never assume the model followed instructions exactly.

### `backend/app/schemas.py`
Added `Plan` (`objective: str`, `research_questions: List[str]`) and extended `ResearchRunResponse` with `plan: Optional[Plan] = None`. Kept optional/nullable rather than required, specifically to support the `planning_failed` path returning a valid response with no plan.

### `backend/app/routes.py`
`POST /research` now branches on `generate_plan()` success/failure, but the response model (`ResearchRunResponse`) is the same either way — the frontend only needs to check `status` and whether `plan` is `null`, not handle two different response shapes.

### `frontend/src/components/ResearchForm.tsx`
Renders `plan.objective` and `plan.research_questions` when present, falls back to showing `message` in red when `plan` is `null` (i.e. `planning_failed`). Button label changes to "Planning..." during the request to reflect that real work (an LLM call) is now happening, not just a network round-trip.

## Dependencies / Configuration Added

- `python-dotenv` (backend) — loads `.env` for `OLLAMA_MODEL`/`OLLAMA_HOST`
- No new frontend dependencies
- Requires `backend/.env` to exist locally (copied from `.env.example`) with at minimum:
  ```env
  OLLAMA_MODEL=qwen3:8b
  OLLAMA_HOST=http://localhost:11434
  ```

## How to Run / Verify This Phase

1. `pip install -r backend/requirements.txt` (picks up `python-dotenv`)
2. Restart backend + frontend
3. Submit a real topic → expect `status: "planned"`, a one-sentence objective, and 3–5 research questions
4. `http://localhost:8000/docs` → confirm `ResearchRunResponse` schema shows the `plan` field

## Known Issues / Follow-ups

- **Dark-mode contrast bug:** on systems with `prefers-color-scheme: dark`, the input label and placeholder text render near-invisible (dark text implied against a dark input background), even though the result box itself is readable. Root cause is Tailwind's default dark-mode media query interacting with hardcoded light-theme text classes — not fixed in this phase, deferred to a UI polish pass.
- `call_llm()` has no timeout or retry — a hung Ollama process will hang the request indefinitely. Worth revisiting once orchestration (Phase 3+) makes failure modes more visible.
