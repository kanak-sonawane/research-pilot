#!/usr/bin/env bash
set -e

# Phase 2 — Ollama-Powered Planning
# Run this from the root of your research-pilot/ project.

echo "Setting up Phase 2 files..."

# ---------------------------------------------------------------------------
# Backend: config loader
# ---------------------------------------------------------------------------

cat > backend/app/config.py << 'EOF'
import os

from dotenv import load_dotenv

load_dotenv()

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen3:8b")
EOF

# ---------------------------------------------------------------------------
# Backend: LLM service wrapper
# ---------------------------------------------------------------------------

cat > backend/app/llm_service.py << 'EOF'
import ollama

from app.config import OLLAMA_MODEL


class LLMError(Exception):
    """Raised when the LLM call fails or returns something unusable."""


def call_llm(system_prompt: str, user_prompt: str) -> str:
    """
    Thin wrapper around ollama.chat.

    Kept intentionally dumb (no retries, no streaming) for Phase 2 —
    this is the single choke point every future LLM call routes through,
    so retry/timeout/logging behavior can be added here later without
    touching call sites.
    """
    try:
        response = ollama.chat(
            model=OLLAMA_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        )
        return response["message"]["content"]
    except Exception as e:
        raise LLMError(f"LLM call failed: {e}") from e
EOF

# ---------------------------------------------------------------------------
# Backend: planning module
# ---------------------------------------------------------------------------

cat > backend/app/planning.py << 'EOF'
import json
import re

from app.llm_service import call_llm, LLMError

PLANNING_SYSTEM_PROMPT = """You are a research planning assistant. Given a technical research topic, produce:
1. A one-sentence objective describing what the research should establish.
2. A list of 3 to 5 precise, non-overlapping research questions that together satisfy the objective.

Rules:
- Research questions must be specific and answerable through documentation, web sources, or code repositories — not opinion.
- Do not include more than 5 questions. Prefer fewer, sharper questions over many broad ones.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"objective": "...", "research_questions": ["...", "..."]}
"""


class PlanningError(Exception):
    """Raised when planning fails or the model output can't be parsed into a plan."""


def _extract_json(raw_text: str) -> dict:
    """
    Models frequently wrap JSON in ```json fences or add stray text
    despite instructions. This strips fences and grabs the first
    {...} block rather than assuming the response is clean JSON.
    """
    text = raw_text.strip()
    text = re.sub(r"^```(?:json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise PlanningError(f"No JSON object found in model output: {raw_text!r}")

    return json.loads(match.group(0))


def generate_plan(query: str) -> dict:
    """
    Calls the LLM to turn a raw query into an objective + research questions.
    Returns a dict shaped like {"objective": str, "research_questions": [str, ...]}.
    """
    raw = call_llm(PLANNING_SYSTEM_PROMPT, query)

    try:
        parsed = _extract_json(raw)
    except (json.JSONDecodeError, PlanningError) as e:
        raise PlanningError(f"Could not parse plan from model output: {e}") from e

    if "objective" not in parsed or "research_questions" not in parsed:
        raise PlanningError(f"Plan JSON missing required keys: {parsed}")

    if not isinstance(parsed["research_questions"], list) or not parsed["research_questions"]:
        raise PlanningError(f"research_questions must be a non-empty list: {parsed}")

    return {
        "objective": parsed["objective"],
        "research_questions": parsed["research_questions"][:5],
    }
EOF

# ---------------------------------------------------------------------------
# Backend: update schemas to include the plan
# ---------------------------------------------------------------------------

cat > backend/app/schemas.py << 'EOF'
from typing import List, Optional

from pydantic import BaseModel, field_validator


class ResearchRequest(BaseModel):
    """
    Incoming payload for POST /research.
    """
    query: str

    @field_validator("query")
    @classmethod
    def query_must_not_be_blank(cls, v: str) -> str:
        normalized = v.strip()
        if not normalized:
            raise ValueError("Research query cannot be empty.")
        return normalized


class Plan(BaseModel):
    """
    Output of the planning step (Phase 2).
    """
    objective: str
    research_questions: List[str]


class ResearchRunResponse(BaseModel):
    """
    Response contract for POST /research.

    `plan` is optional/None when planning fails — the endpoint still
    returns a valid response with `status: "planning_failed"` rather
    than a raw 500, so the frontend has something structured to show.
    """
    run_id: str
    status: str
    query: str
    message: str
    plan: Optional[Plan] = None
EOF

# ---------------------------------------------------------------------------
# Backend: update routes to call planning
# ---------------------------------------------------------------------------

cat > backend/app/routes.py << 'EOF'
import uuid

from fastapi import APIRouter

from app.schemas import ResearchRequest, ResearchRunResponse, Plan
from app.planning import generate_plan, PlanningError

router = APIRouter()


@router.post("/research", response_model=ResearchRunResponse)
def start_research(payload: ResearchRequest):
    """
    Phase 2: validates the request, then calls the LLM to produce a
    research plan (objective + research questions). Actual research
    execution (LangGraph, sources) still doesn't exist yet — that's
    Phase 3+.
    """
    run_id = str(uuid.uuid4())

    try:
        plan_data = generate_plan(payload.query)
        return ResearchRunResponse(
            run_id=run_id,
            status="planned",
            query=payload.query,
            message="Research plan generated.",
            plan=Plan(**plan_data),
        )
    except PlanningError as e:
        # Planning failure is a known, expected failure mode (bad model
        # output, etc.) — surfaced as a normal response, not a 500, so
        # the frontend can show a clear message instead of a generic error.
        return ResearchRunResponse(
            run_id=run_id,
            status="planning_failed",
            query=payload.query,
            message=f"Could not generate a research plan: {e}",
            plan=None,
        )
EOF

# ---------------------------------------------------------------------------
# Backend: ensure python-dotenv is present
# ---------------------------------------------------------------------------

if ! grep -q "^python-dotenv" backend/requirements.txt 2>/dev/null; then
  echo "python-dotenv" >> backend/requirements.txt
fi

# ---------------------------------------------------------------------------
# Frontend: display the plan in ResearchForm
# ---------------------------------------------------------------------------

cat > frontend/src/components/ResearchForm.tsx << 'EOF'
"use client";

import { useState } from "react";

type RunStatus = "idle" | "loading" | "success" | "error";

interface Plan {
  objective: string;
  research_questions: string[];
}

interface ResearchRunResponse {
  run_id: string;
  status: string;
  query: string;
  message: string;
  plan: Plan | null;
}

const API_BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:8000";

export default function ResearchForm() {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<RunStatus>("idle");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [result, setResult] = useState<ResearchRunResponse | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!query.trim()) {
      setStatus("error");
      setErrorMessage("Please enter a research topic before submitting.");
      return;
    }

    setStatus("loading");
    setErrorMessage("");
    setResult(null);

    try {
      const res = await fetch(`${API_BASE_URL}/research`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query }),
      });

      if (!res.ok) {
        const errBody = await res.json().catch(() => null);
        throw new Error(
          errBody?.detail?.[0]?.msg || "The research request could not be submitted."
        );
      }

      const data: ResearchRunResponse = await res.json();
      setResult(data);
      setStatus("success");
    } catch (err) {
      setStatus("error");
      setErrorMessage(
        err instanceof Error ? err.message : "Something went wrong. Please try again."
      );
    }
  };

  return (
    <div className="w-full max-w-xl flex flex-col gap-4">
      <form onSubmit={handleSubmit} className="flex flex-col gap-3">
        <label htmlFor="research-query" className="font-medium text-gray-900">
          Technical research topic
        </label>
        <input
          id="research-query"
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="e.g. How does LangGraph handle cyclic workflows?"
          className="border rounded px-3 py-2 text-gray-900 placeholder:text-gray-400"
          disabled={status === "loading"}
        />
        <button
          type="submit"
          disabled={status === "loading"}
          className="rounded bg-black px-4 py-2 text-white disabled:opacity-50"
        >
          {status === "loading" ? "Planning..." : "Start Research"}
        </button>
      </form>

      {status === "error" && (
        <p className="text-red-600 text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      {status === "success" && result && (
        <div className="text-sm border rounded p-4 bg-gray-50 text-gray-900 flex flex-col gap-3">
          <p><strong>Status:</strong> {result.status}</p>
          <p><strong>Run ID:</strong> {result.run_id}</p>

          {result.plan ? (
            <>
              <div>
                <strong>Objective</strong>
                <p className="mt-1">{result.plan.objective}</p>
              </div>
              <div>
                <strong>Research Questions</strong>
                <ul className="list-disc list-inside mt-1 flex flex-col gap-1">
                  {result.plan.research_questions.map((q, i) => (
                    <li key={i}>{q}</li>
                  ))}
                </ul>
              </div>
            </>
          ) : (
            <p className="text-red-600">{result.message}</p>
          )}
        </div>
      )}
    </div>
  );
}
EOF

echo ""
echo "Phase 2 files created/updated:"
echo "  backend/app/config.py"
echo "  backend/app/llm_service.py"
echo "  backend/app/planning.py"
echo "  backend/app/schemas.py (updated: added Plan)"
echo "  backend/app/routes.py (updated: calls generate_plan)"
echo "  backend/requirements.txt (ensured python-dotenv present)"
echo "  frontend/src/components/ResearchForm.tsx (updated: renders plan, fixed low-contrast text)"
echo ""
echo "Don't forget: activate your venv and run 'pip install -r backend/requirements.txt'"
echo "before restarting the backend, in case python-dotenv wasn't already installed."
