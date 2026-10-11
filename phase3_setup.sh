#!/usr/bin/env bash
set -e

# Phase 3 — LangGraph StateGraph & Shared Research State
# Run this from the root of your research-pilot/ project.

echo "Setting up Phase 3 files..."

# ---------------------------------------------------------------------------
# Backend: shared research state
# ---------------------------------------------------------------------------

cat > backend/app/state.py << 'EOF'
from typing import Dict, List, Optional, TypedDict


class ResearchState(TypedDict, total=False):
    """
    Shared state threaded through every node in the LangGraph graph.

    `total=False` is deliberate: fields are populated incrementally as
    the graph progresses (plan -> source decisions -> [future: evidence,
    evaluation, report]), so not every field exists at every point in
    the run. Nodes must use .get() with defaults, never direct indexing,
    when reading fields another node may not have set yet.
    """

    # Set at graph invocation
    run_id: str
    query: str

    # Set by plan_node
    objective: str
    research_questions: List[str]

    # Set by decide_sources_node
    # e.g. {"How does X work?": ["web", "docs"]}
    source_decisions: Dict[str, List[str]]

    # Set by any node on failure; short-circuits downstream nodes
    error: Optional[str]

    # Future phases will add: evidence, evaluation, report, status history
EOF

# ---------------------------------------------------------------------------
# Backend: source decision module (structured decision-making)
# ---------------------------------------------------------------------------

cat > backend/app/source_decision.py << 'EOF'
import json
import re

from app.llm_service import call_llm

VALID_SOURCES = {"web", "docs", "github"}

SOURCE_DECISION_SYSTEM_PROMPT = """You are a research routing assistant. Given a list of research questions,
decide which source types are appropriate for answering each one.

Valid source types (use only these, lowercase, exactly as written):
- "web": general web search, for broad/contextual/comparative information
- "docs": official documentation, for framework/library/API specifics
- "github": code repositories, for implementation details, real usage, issues

Rules:
- Each question maps to a list of 1-3 source types.
- Prefer the smallest set of sources that would actually answer the question.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"decisions": [{"question": "...", "sources": ["web"]}, ...]}
One entry per input question, in the same order.
"""


class SourceDecisionError(Exception):
    """Raised when source-routing decisions can't be produced or parsed."""


def _extract_json(raw_text: str) -> dict:
    text = raw_text.strip()
    text = re.sub(r"^```(?:json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise SourceDecisionError(f"No JSON object found in model output: {raw_text!r}")

    return json.loads(match.group(0))


def decide_sources(research_questions: list[str]) -> dict:
    """
    Returns {question: [source_type, ...]} for every input question.
    Falls back to ["web"] for any question the model skips or gives an
    invalid/empty source list for — every question must have somewhere
    to be researched, and "web" is the safest general-purpose default.
    """
    if not research_questions:
        raise SourceDecisionError("Cannot decide sources for an empty question list.")

    user_prompt = "Research questions:\n" + "\n".join(
        f"- {q}" for q in research_questions
    )

    raw = call_llm(SOURCE_DECISION_SYSTEM_PROMPT, user_prompt)

    try:
        parsed = _extract_json(raw)
    except (json.JSONDecodeError, SourceDecisionError) as e:
        raise SourceDecisionError(f"Could not parse source decisions: {e}") from e

    decisions = parsed.get("decisions")
    if not isinstance(decisions, list):
        raise SourceDecisionError(f"Missing/invalid 'decisions' list: {parsed}")

    result: dict[str, list[str]] = {}
    for entry in decisions:
        question = entry.get("question")
        sources = entry.get("sources", [])
        if not question:
            continue
        valid_sources = [s for s in sources if s in VALID_SOURCES]
        result[question] = valid_sources if valid_sources else ["web"]

    # Guarantee every original question has an entry, even if the model
    # dropped one — never let a question silently fall out of the plan.
    for q in research_questions:
        if q not in result:
            result[q] = ["web"]

    return result
EOF

# ---------------------------------------------------------------------------
# Backend: the graph itself
# ---------------------------------------------------------------------------

cat > backend/app/graph.py << 'EOF'
from langgraph.graph import StateGraph, END

from app.state import ResearchState
from app.planning import generate_plan, PlanningError
from app.source_decision import decide_sources, SourceDecisionError


def plan_node(state: ResearchState) -> dict:
    """Entry node. Turns the raw query into an objective + research questions."""
    try:
        plan = generate_plan(state["query"])
        return {
            "objective": plan["objective"],
            "research_questions": plan["research_questions"],
        }
    except PlanningError as e:
        return {"error": f"Planning failed: {e}"}


def decide_sources_node(state: ResearchState) -> dict:
    """
    Decides which source types to use per research question.
    Short-circuits if plan_node already failed — no point routing
    sources for questions that don't exist.
    """
    if state.get("error"):
        return {}

    try:
        decisions = decide_sources(state["research_questions"])
        return {"source_decisions": decisions}
    except SourceDecisionError as e:
        return {"error": f"Source decision failed: {e}"}


def build_graph():
    """
    Builds and compiles the research graph.

    Currently linear (plan -> decide_sources -> END) with only two real
    nodes. This is intentionally a scaffold: Phase 4/5 add source-research
    nodes after decide_sources, Phase 6 adds the evaluation/sufficiency
    loop (a conditional edge back into research), and Phase 7 adds report
    generation before END. The graph structure is the reason those phases
    can be added without restructuring how state flows through the system.
    """
    graph = StateGraph(ResearchState)

    graph.add_node("plan", plan_node)
    graph.add_node("decide_sources", decide_sources_node)

    graph.set_entry_point("plan")
    graph.add_edge("plan", "decide_sources")
    graph.add_edge("decide_sources", END)

    return graph.compile()


# Compiled once at import time and reused across requests — recompiling
# per-request would be wasted work, since the graph structure never
# changes at runtime.
research_graph = build_graph()
EOF

# ---------------------------------------------------------------------------
# Backend: update schemas to include source_decisions
# ---------------------------------------------------------------------------

cat > backend/app/schemas.py << 'EOF'
from typing import Dict, List, Optional

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
    objective: str
    research_questions: List[str]


class ResearchRunResponse(BaseModel):
    """
    Response contract for POST /research.

    `source_decisions` maps each research question to its chosen source
    types (e.g. {"How does X work?": ["web", "docs"]}). It's `None` when
    planning failed before source routing ever ran.
    """
    run_id: str
    status: str
    query: str
    message: str
    plan: Optional[Plan] = None
    source_decisions: Optional[Dict[str, List[str]]] = None
EOF

# ---------------------------------------------------------------------------
# Backend: routes now invoke the graph instead of calling generate_plan directly
# ---------------------------------------------------------------------------

cat > backend/app/routes.py << 'EOF'
import uuid

from fastapi import APIRouter

from app.schemas import ResearchRequest, ResearchRunResponse, Plan
from app.graph import research_graph

router = APIRouter()


@router.post("/research", response_model=ResearchRunResponse)
def start_research(payload: ResearchRequest):
    """
    Phase 3: request handling is now a thin wrapper around invoking the
    LangGraph graph. The route no longer knows *how* planning or source
    routing happen internally — it just passes in initial state and reads
    the final state back out. This is what makes it possible to slot in
    Phase 4+ nodes (actual source research) without touching this file.
    """
    run_id = str(uuid.uuid4())

    final_state = research_graph.invoke({
        "run_id": run_id,
        "query": payload.query,
    })

    if final_state.get("error"):
        return ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=payload.query,
            message=final_state["error"],
            plan=None,
            source_decisions=None,
        )

    return ResearchRunResponse(
        run_id=run_id,
        status="sources_planned",
        query=payload.query,
        message="Research plan and source routing generated.",
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
    )
EOF

# ---------------------------------------------------------------------------
# Backend: add langgraph to requirements
# ---------------------------------------------------------------------------

if ! grep -q "^langgraph" backend/requirements.txt 2>/dev/null; then
  echo "langgraph" >> backend/requirements.txt
fi

# ---------------------------------------------------------------------------
# Frontend: render source decisions alongside the plan
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
  source_decisions: Record<string, string[]> | null;
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
                <strong>Research Questions & Sources</strong>
                <ul className="list-disc list-inside mt-1 flex flex-col gap-1">
                  {result.plan.research_questions.map((q, i) => (
                    <li key={i}>
                      {q}
                      {result.source_decisions?.[q] && (
                        <span className="text-gray-500">
                          {" "}
                          [{result.source_decisions[q].join(", ")}]
                        </span>
                      )}
                    </li>
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
echo "Phase 3 files created/updated:"
echo "  backend/app/state.py (new: ResearchState)"
echo "  backend/app/source_decision.py (new: decide_sources)"
echo "  backend/app/graph.py (new: LangGraph StateGraph)"
echo "  backend/app/schemas.py (updated: added source_decisions)"
echo "  backend/app/routes.py (updated: invokes research_graph instead of generate_plan directly)"
echo "  backend/requirements.txt (ensured langgraph present)"
echo "  frontend/src/components/ResearchForm.tsx (updated: shows sources per question)"
echo ""
echo "Don't forget: activate your venv and run 'pip install -r backend/requirements.txt'"
echo "before restarting the backend, since langgraph is a new dependency."
