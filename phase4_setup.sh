#!/usr/bin/env bash
set -e

# Phase 4 — Tavily Web Research & Evidence Extraction
# Run this from the root of your research-pilot/ project.

echo "Setting up Phase 4 files..."

# ---------------------------------------------------------------------------
# Backend: shared JSON-extraction helper (DRY-ing up a pattern used 3x now)
# ---------------------------------------------------------------------------

cat > backend/app/json_utils.py << 'EOF'
import json
import re


def extract_json_object(raw_text: str) -> dict:
    """
    Shared defensive JSON extraction, used by every module that asks the
    LLM for structured output (planning, source_decision, web_research).

    Strips ```json fences and grabs the first {...} block rather than
    assuming the model returned clean JSON — local models frequently
    don't, even with explicit instructions not to add extra text.

    Raises ValueError (not a domain-specific exception) so each caller
    wraps it in whatever exception type makes sense for that module.
    """
    text = raw_text.strip()
    text = re.sub(r"^```(?:json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise ValueError(f"No JSON object found in model output: {raw_text!r}")

    return json.loads(match.group(0))
EOF

# Update planning.py and source_decision.py to use the shared helper
python3 - << 'PYEOF'
import re

for path, err_cls in [
    ("backend/app/planning.py", "PlanningError"),
    ("backend/app/source_decision.py", "SourceDecisionError"),
]:
    with open(path) as f:
        content = f.read()

    # Replace the local _extract_json function body with an import + thin wrapper
    content = re.sub(
        r"def _extract_json\(raw_text: str\) -> dict:.*?return json\.loads\(match\.group\(0\)\)\n",
        (
            "def _extract_json(raw_text: str) -> dict:\n"
            "    try:\n"
            "        return extract_json_object(raw_text)\n"
            f"    except ValueError as e:\n"
            f"        raise {err_cls}(str(e)) from e\n"
        ),
        content,
        flags=re.DOTALL,
    )

    if "from app.json_utils import extract_json_object" not in content:
        content = content.replace(
            "from app.llm_service import call_llm",
            "from app.llm_service import call_llm\nfrom app.json_utils import extract_json_object",
        )

    with open(path, "w") as f:
        f.write(content)

print("Refactored planning.py and source_decision.py to use shared json_utils.")
PYEOF

# ---------------------------------------------------------------------------
# Backend: config - add TAVILY_API_KEY
# ---------------------------------------------------------------------------

cat > backend/app/config.py << 'EOF'
import os

from dotenv import load_dotenv

load_dotenv()

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen3:8b")
TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "")
EOF

# Add TAVILY_API_KEY to the env example if not already present
if [ -f backend/.env.example ] && ! grep -q "TAVILY_API_KEY" backend/.env.example; then
  echo "TAVILY_API_KEY=" >> backend/.env.example
fi

echo ""
echo "IMPORTANT: add your real key to backend/.env (NOT .env.example):"
echo "  TAVILY_API_KEY=your-actual-key-here"
echo ""

# ---------------------------------------------------------------------------
# Backend: web research module (Tavily search + evidence extraction)
# ---------------------------------------------------------------------------

cat > backend/app/web_research.py << 'EOF'
import json

from tavily import TavilyClient

from app.config import TAVILY_API_KEY
from app.llm_service import call_llm
from app.json_utils import extract_json_object

EVIDENCE_SYSTEM_PROMPT = """You are a research evidence extraction assistant. Given a research question
and a numbered set of web search results, extract discrete, specific evidence statements
that help answer the question.

Rules:
- Only extract claims that are actually supported by the provided content. Never add outside knowledge.
- Each evidence item must cite exactly one source, by its number, from the provided results.
- If none of the results are relevant, return an empty evidence list.
- Prefer several precise, atomic claims over one broad summary.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"evidence": [{"claim": "...", "source_index": 0}, ...]}
"""


class WebResearchError(Exception):
    """Raised when a Tavily search or evidence extraction fails for a question."""


_client = None


def _get_client() -> TavilyClient:
    """
    Lazily constructs the Tavily client on first use rather than at import
    time, so importing this module doesn't hard-fail just because the key
    isn't set yet (e.g. during early setup before .env is filled in).
    """
    global _client
    if _client is None:
        if not TAVILY_API_KEY:
            raise WebResearchError(
                "TAVILY_API_KEY is not set. Add it to backend/.env."
            )
        _client = TavilyClient(api_key=TAVILY_API_KEY)
    return _client


def search_web(query: str, max_results: int = 5) -> list[dict]:
    """Returns Tavily's raw result list: [{"title", "url", "content", ...}, ...]."""
    try:
        client = _get_client()
        response = client.search(query=query, max_results=max_results)
        return response.get("results", [])
    except WebResearchError:
        raise
    except Exception as e:
        raise WebResearchError(f"Tavily search failed for '{query}': {e}") from e


def extract_evidence(question: str, results: list[dict]) -> list[dict]:
    """
    Turns raw search results into structured evidence tied to `question`.
    Returns [] immediately if there are no results — no point calling the
    LLM with nothing to extract from.
    """
    if not results:
        return []

    numbered = "\n\n".join(
        f"[{i}] Title: {r.get('title', '')}\n"
        f"URL: {r.get('url', '')}\n"
        f"Content: {(r.get('content') or '')[:1000]}"
        for i, r in enumerate(results)
    )
    user_prompt = f"Research question: {question}\n\nSearch results:\n{numbered}"

    raw = call_llm(EVIDENCE_SYSTEM_PROMPT, user_prompt)

    try:
        parsed = extract_json_object(raw)
    except (ValueError, json.JSONDecodeError) as e:
        raise WebResearchError(f"Could not parse evidence output: {e}") from e

    raw_evidence = parsed.get("evidence", [])
    if not isinstance(raw_evidence, list):
        raise WebResearchError(f"'evidence' must be a list: {parsed}")

    evidence_items = []
    for item in raw_evidence:
        claim = item.get("claim")
        idx = item.get("source_index")

        # Skip anything malformed or pointing at a source index that
        # doesn't exist, rather than raising — one bad evidence item
        # shouldn't discard every other valid one for this question.
        if claim is None or not isinstance(idx, int) or not (0 <= idx < len(results)):
            continue

        source = results[idx]
        evidence_items.append({
            "question": question,
            "source_type": "web",
            "source_title": source.get("title", ""),
            "source_url": source.get("url", ""),
            "claim": claim,
        })

    return evidence_items


def research_question_web(question: str) -> list[dict]:
    """Full per-question pipeline: search Tavily, then extract evidence from results."""
    results = search_web(question)
    return extract_evidence(question, results)
EOF

# ---------------------------------------------------------------------------
# Backend: extend shared state with evidence + partial-failure warnings
# ---------------------------------------------------------------------------

cat > backend/app/state.py << 'EOF'
from typing import Dict, List, Optional, TypedDict


class ResearchState(TypedDict, total=False):
    """
    Shared state threaded through every node in the LangGraph graph.
    `total=False`: fields are populated incrementally, not all present
    at every point in a run. Read with .get(), never direct indexing,
    unless an earlier node in the same path is guaranteed to have run.
    """

    # Set at graph invocation
    run_id: str
    query: str

    # Set by plan_node
    objective: str
    research_questions: List[str]

    # Set by decide_sources_node
    source_decisions: Dict[str, List[str]]

    # Set by research_web_node (Phase 4)
    # Each item: {"question", "source_type", "source_title", "source_url", "claim"}
    evidence: List[dict]
    # Non-fatal per-question failures (e.g. one Tavily call failed) —
    # distinct from `error`, which represents a fatal, run-stopping failure.
    web_research_warnings: List[str]

    # Set by any node on fatal failure; short-circuits downstream nodes
    error: Optional[str]

    # Future phases will add: docs/github evidence, evaluation, report
EOF

# ---------------------------------------------------------------------------
# Backend: graph - add research_web node
# ---------------------------------------------------------------------------

cat > backend/app/graph.py << 'EOF'
from langgraph.graph import StateGraph, END

from app.state import ResearchState
from app.planning import generate_plan, PlanningError
from app.source_decision import decide_sources, SourceDecisionError
from app.web_research import research_question_web, WebResearchError


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
    """Decides which source types to use per research question."""
    if state.get("error"):
        return {}

    try:
        decisions = decide_sources(state["research_questions"])
        return {"source_decisions": decisions}
    except SourceDecisionError as e:
        return {"error": f"Source decision failed: {e}"}


def research_web_node(state: ResearchState) -> dict:
    """
    For every question routed to "web", searches Tavily and extracts
    evidence. Per-question failures are collected as warnings rather
    than aborting the whole run via `error` — a single bad search
    shouldn't discard evidence already gathered for other questions.
    Questions not routed to "web" are skipped here entirely; they're
    Phase 5's responsibility (docs/github).
    """
    if state.get("error"):
        return {}

    source_decisions = state.get("source_decisions", {})
    all_evidence: list[dict] = []
    warnings: list[str] = []

    for question, sources in source_decisions.items():
        if "web" not in sources:
            continue
        try:
            all_evidence.extend(research_question_web(question))
        except WebResearchError as e:
            warnings.append(f"'{question}': {e}")

    result: dict = {"evidence": all_evidence}
    if warnings:
        result["web_research_warnings"] = warnings
    return result


def build_graph():
    """
    plan -> decide_sources -> research_web -> END

    Phase 5 adds research_docs/research_github nodes in parallel with
    research_web (or sequenced after it). Phase 6 adds the sufficiency
    loop as a conditional edge back into research. Phase 7 adds report
    generation before END.
    """
    graph = StateGraph(ResearchState)

    graph.add_node("plan", plan_node)
    graph.add_node("decide_sources", decide_sources_node)
    graph.add_node("research_web", research_web_node)

    graph.set_entry_point("plan")
    graph.add_edge("plan", "decide_sources")
    graph.add_edge("decide_sources", "research_web")
    graph.add_edge("research_web", END)

    return graph.compile()


research_graph = build_graph()
EOF

# ---------------------------------------------------------------------------
# Backend: schemas - add EvidenceItem + evidence/warnings on the response
# ---------------------------------------------------------------------------

cat > backend/app/schemas.py << 'EOF'
from typing import Dict, List, Optional

from pydantic import BaseModel, field_validator


class ResearchRequest(BaseModel):
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


class EvidenceItem(BaseModel):
    question: str
    source_type: str
    source_title: str
    source_url: str
    claim: str


class ResearchRunResponse(BaseModel):
    """
    `evidence` is None only when the run failed before research_web ran.
    An empty list (`[]`) is a real, valid outcome — it means research ran
    but found nothing usable, which is different from "never got there."
    `warnings` carries non-fatal per-question failures; None means no
    warnings occurred (not the same as an empty list, but both render
    the same way on the frontend for now).
    """
    run_id: str
    status: str
    query: str
    message: str
    plan: Optional[Plan] = None
    source_decisions: Optional[Dict[str, List[str]]] = None
    evidence: Optional[List[EvidenceItem]] = None
    warnings: Optional[List[str]] = None
EOF

# ---------------------------------------------------------------------------
# Backend: routes - reflect the new final state shape
# ---------------------------------------------------------------------------

cat > backend/app/routes.py << 'EOF'
import uuid

from fastapi import APIRouter

from app.schemas import ResearchRequest, ResearchRunResponse, Plan
from app.graph import research_graph

router = APIRouter()


@router.post("/research", response_model=ResearchRunResponse)
def start_research(payload: ResearchRequest):
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
        )

    return ResearchRunResponse(
        run_id=run_id,
        status="web_research_complete",
        query=payload.query,
        message="Research plan, source routing, and web evidence gathered.",
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
        evidence=final_state.get("evidence", []),
        warnings=final_state.get("web_research_warnings"),
    )
EOF

# ---------------------------------------------------------------------------
# Backend: add tavily-python to requirements
# ---------------------------------------------------------------------------

if ! grep -q "^tavily-python" backend/requirements.txt 2>/dev/null; then
  echo "tavily-python" >> backend/requirements.txt
fi

# ---------------------------------------------------------------------------
# Frontend: fix dark-mode input contrast + render evidence per question
# ---------------------------------------------------------------------------

cat > frontend/src/components/ResearchForm.tsx << 'EOF'
"use client";

import { useState } from "react";

type RunStatus = "idle" | "loading" | "success" | "error";

interface Plan {
  objective: string;
  research_questions: string[];
}

interface EvidenceItem {
  question: string;
  source_type: string;
  source_title: string;
  source_url: string;
  claim: string;
}

interface ResearchRunResponse {
  run_id: string;
  status: string;
  query: string;
  message: string;
  plan: Plan | null;
  source_decisions: Record<string, string[]> | null;
  evidence: EvidenceItem[] | null;
  warnings: string[] | null;
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

  const evidenceForQuestion = (question: string) =>
    result?.evidence?.filter((e) => e.question === question) ?? [];

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
          className="border rounded px-3 py-2 text-gray-900 placeholder:text-gray-400 bg-white"
          // Forces the native input to stay on light form-control styling
          // regardless of OS/browser dark mode. Without this, browsers
          // that auto-apply a dark `color-scheme` to inputs render the
          // typed text in a dark color against a dark background —
          // unreadable, even though our own Tailwind classes are correct.
          style={{ colorScheme: "light" }}
          disabled={status === "loading"}
        />
        <button
          type="submit"
          disabled={status === "loading"}
          className="rounded bg-black px-4 py-2 text-white disabled:opacity-50"
        >
          {status === "loading" ? "Researching..." : "Start Research"}
        </button>
      </form>

      {status === "error" && (
        <p className="text-red-600 text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      {status === "success" && result && (
        <div className="text-sm border rounded p-4 bg-gray-50 text-gray-900 flex flex-col gap-4">
          <p><strong>Status:</strong> {result.status}</p>
          <p><strong>Run ID:</strong> {result.run_id}</p>

          {result.warnings && result.warnings.length > 0 && (
            <div className="text-amber-700 bg-amber-50 border border-amber-200 rounded p-2">
              <strong>Warnings:</strong>
              <ul className="list-disc list-inside mt-1">
                {result.warnings.map((w, i) => <li key={i}>{w}</li>)}
              </ul>
            </div>
          )}

          {result.plan ? (
            <>
              <div>
                <strong>Objective</strong>
                <p className="mt-1">{result.plan.objective}</p>
              </div>

              <div className="flex flex-col gap-3">
                <strong>Research Questions & Evidence</strong>
                {result.plan.research_questions.map((q, i) => (
                  <div key={i} className="border-l-2 border-gray-300 pl-3">
                    <p className="font-medium">
                      {q}
                      {result.source_decisions?.[q] && (
                        <span className="text-gray-500 font-normal">
                          {" "}[{result.source_decisions[q].join(", ")}]
                        </span>
                      )}
                    </p>
                    {evidenceForQuestion(q).length > 0 ? (
                      <ul className="list-disc list-inside mt-1 flex flex-col gap-1">
                        {evidenceForQuestion(q).map((ev, j) => (
                          <li key={j}>
                            {ev.claim}{" "}
                            <a
                              href={ev.source_url}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="text-blue-600 underline"
                            >
                              [{ev.source_title || "source"}]
                            </a>
                          </li>
                        ))}
                      </ul>
                    ) : (
                      <p className="text-gray-500 mt-1">No evidence gathered yet.</p>
                    )}
                  </div>
                ))}
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
echo "Phase 4 files created/updated:"
echo "  backend/app/json_utils.py (new: shared extract_json_object)"
echo "  backend/app/planning.py, source_decision.py (refactored to use json_utils)"
echo "  backend/app/config.py (updated: added TAVILY_API_KEY)"
echo "  backend/.env.example (updated: added TAVILY_API_KEY placeholder)"
echo "  backend/app/web_research.py (new: Tavily search + evidence extraction)"
echo "  backend/app/state.py (updated: added evidence, web_research_warnings)"
echo "  backend/app/graph.py (updated: added research_web node)"
echo "  backend/app/schemas.py (updated: added EvidenceItem, evidence, warnings)"
echo "  backend/app/routes.py (updated: status is now web_research_complete)"
echo "  backend/requirements.txt (ensured tavily-python present)"
echo "  frontend/src/components/ResearchForm.tsx (updated: dark-mode input fix + evidence display)"
echo ""
echo "REQUIRED before restarting the backend:"
echo "  1. Add your real key to backend/.env:  TAVILY_API_KEY=your-actual-key-here"
echo "  2. pip install -r backend/requirements.txt"
