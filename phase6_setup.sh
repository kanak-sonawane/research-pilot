#!/usr/bin/env bash
set -e

# Phase 6 — Evidence Evaluation & Sufficiency Loop
# Run this from the root of your research-pilot/ project.

echo "Setting up Phase 6 files..."

# ---------------------------------------------------------------------------
# Backend: state.py - split research_questions/active_questions, add loop fields
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

    run_id: str
    query: str

    objective: str

    # ALL research questions ever asked, across every round (original +
    # every gap-filling round). Grows over time, never overwritten.
    # This is what gets shown to the user as "the plan."
    research_questions: List[str]

    # Only the CURRENT round's questions — what decide_sources_node and
    # the research nodes should actually act on this pass. Replaced each
    # round (by plan_node initially, by prepare_next_round_node after).
    active_questions: List[str]

    # Accumulates across rounds (merged dict, never wholesale replaced) —
    # routing decisions for every question ever asked, not just the
    # current round's.
    source_decisions: Dict[str, List[str]]

    # Accumulated across research_web / research_docs / research_github,
    # across every round. Each item: {"question", "source_type",
    # "source_title", "source_url", "claim"}
    evidence: List[dict]
    research_warnings: List[str]

    # Set by evaluate_sufficiency_node each time it runs (reflects the
    # LATEST judgment, not accumulated).
    sufficient: bool
    gap_questions: List[str]

    # Starts absent (treated as 0). Incremented by prepare_next_round_node
    # each time the loop fires. Used to enforce the bounded-loop cap.
    research_iteration: int

    error: Optional[str]

    # Future phases will add: report
EOF

# ---------------------------------------------------------------------------
# Backend: evaluation.py - sufficiency judgment
# ---------------------------------------------------------------------------

cat > backend/app/evaluation.py << 'EOF'
import json

from app.llm_service import call_llm
from app.json_utils import extract_json_object

EVALUATION_SYSTEM_PROMPT = """You are a research sufficiency evaluator. Given a research objective,
the research questions already explored, and the evidence gathered so far, decide whether
the evidence is sufficient to satisfy the objective.

Rules:
- Consider both coverage (does the evidence address the objective's key aspects) and
  concreteness (are claims specific, not vague).
- If insufficient, propose up to 3 NEW, specific follow-up research questions that would
  fill the most important remaining gaps. Do not repeat questions already explored.
- If sufficient, or if you cannot think of a genuinely useful follow-up question, return
  an empty gap_questions list.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"sufficient": true, "gap_questions": []}
"""

# Hard cap on evidence items included in the evaluation prompt. A long
# research run could accumulate dozens of evidence items across rounds;
# bounding this keeps the prompt a reasonable size for an 8B local model
# rather than growing unbounded with every loop iteration.
MAX_EVIDENCE_IN_PROMPT = 40


class EvaluationError(Exception):
    """Raised when sufficiency evaluation fails or its output can't be parsed."""


def evaluate_sufficiency(objective: str, research_questions: list[str], evidence: list[dict]) -> dict:
    """
    Returns {"sufficient": bool, "gap_questions": [str, ...]} (capped at 3
    gap questions regardless of what the model returns — same
    code-level-cap lesson as github_research.py's keyword limit: never
    trust a count instruction in a prompt to be a guarantee).
    """
    questions_block = "\n".join(f"- {q}" for q in research_questions) or "(none)"

    evidence_subset = evidence[:MAX_EVIDENCE_IN_PROMPT]
    evidence_block = "\n".join(
        f"- [{e.get('source_type', '?')}] {e.get('claim', '')}" for e in evidence_subset
    ) or "(no evidence gathered)"

    user_prompt = (
        f"Objective: {objective}\n\n"
        f"Questions already explored:\n{questions_block}\n\n"
        f"Evidence gathered so far:\n{evidence_block}"
    )

    raw = call_llm(EVALUATION_SYSTEM_PROMPT, user_prompt)

    try:
        parsed = extract_json_object(raw)
    except (ValueError, json.JSONDecodeError) as e:
        raise EvaluationError(f"Could not parse sufficiency evaluation: {e}") from e

    sufficient = bool(parsed.get("sufficient", True))
    gap_questions = parsed.get("gap_questions", [])
    if not isinstance(gap_questions, list):
        gap_questions = []

    return {
        "sufficient": sufficient,
        "gap_questions": [str(q) for q in gap_questions if q][:3],
    }
EOF

# ---------------------------------------------------------------------------
# Backend: graph.py - add evaluate_sufficiency node, conditional loop edge
# ---------------------------------------------------------------------------

cat > backend/app/graph.py << 'EOF'
from langgraph.graph import StateGraph, END

from app.state import ResearchState
from app.planning import generate_plan, PlanningError
from app.source_decision import decide_sources, SourceDecisionError
from app.web_research import research_question_web, ResearchError
from app.docs_research import research_question_docs
from app.github_research import research_question_github
from app.evaluation import evaluate_sufficiency, EvaluationError

# Hard cap on extra research rounds beyond the first. This is the bounded-
# loop guarantee the PRD requires: no matter how often evaluate_sufficiency
# judges the evidence insufficient, the graph will reach END once this many
# additional rounds have run, with whatever evidence exists at that point.
MAX_RESEARCH_ROUNDS = 2


def plan_node(state: ResearchState) -> dict:
    """Entry node. Sets BOTH research_questions (full history) and
    active_questions (this round's work) to the same initial list."""
    try:
        plan = generate_plan(state["query"])
        return {
            "objective": plan["objective"],
            "research_questions": plan["research_questions"],
            "active_questions": plan["research_questions"],
        }
    except PlanningError as e:
        return {"error": f"Planning failed: {e}"}


def decide_sources_node(state: ResearchState) -> dict:
    """
    Routes sources for THIS round's active_questions only, then merges
    the result into the accumulated source_decisions dict rather than
    replacing it — so routing decisions from earlier rounds aren't lost
    when a later round only routes its own (smaller) set of questions.
    """
    if state.get("error"):
        return {}
    try:
        new_decisions = decide_sources(state["active_questions"])
        merged = dict(state.get("source_decisions", {}))
        merged.update(new_decisions)
        return {"source_decisions": merged}
    except SourceDecisionError as e:
        return {"error": f"Source decision failed: {e}"}


def _build_research_node(source_type: str, research_fn):
    """
    Iterates `active_questions` (NOT all of source_decisions) so each
    round only researches its own questions, not every question ever
    asked across the whole run — source_decisions accumulates historical
    routing, but re-researching already-covered questions every loop
    would waste calls and duplicate evidence.
    """

    def node(state: ResearchState) -> dict:
        if state.get("error"):
            return {}

        active_questions = state.get("active_questions", [])
        source_decisions = state.get("source_decisions", {})
        evidence = list(state.get("evidence", []))
        warnings = list(state.get("research_warnings", []))

        for question in active_questions:
            sources = source_decisions.get(question, [])
            if source_type not in sources:
                continue
            try:
                evidence.extend(research_fn(question))
            except ResearchError as e:
                warnings.append(f"'{question}' ({source_type}): {e}")

        result: dict = {"evidence": evidence}
        if warnings:
            result["research_warnings"] = warnings
        return result

    return node


research_web_node = _build_research_node("web", research_question_web)
research_docs_node = _build_research_node("docs", research_question_docs)
research_github_node = _build_research_node("github", research_question_github)


def evaluate_sufficiency_node(state: ResearchState) -> dict:
    """
    Judges whether accumulated evidence satisfies the objective. On
    evaluation failure itself (not a research failure — the evaluator
    LLM call/parse failing), this fails SAFE: treats the run as
    sufficient and stops, rather than looping forever or discarding
    evidence already gathered. A broken evaluator shouldn't mean the
    user gets nothing.
    """
    if state.get("error"):
        return {}

    try:
        result = evaluate_sufficiency(
            state.get("objective", ""),
            state.get("research_questions", []),
            state.get("evidence", []),
        )
        return {"sufficient": result["sufficient"], "gap_questions": result["gap_questions"]}
    except EvaluationError as e:
        warnings = list(state.get("research_warnings", []))
        warnings.append(f"Sufficiency evaluation failed, stopping with current evidence: {e}")
        return {"sufficient": True, "gap_questions": [], "research_warnings": warnings}


def prepare_next_round_node(state: ResearchState) -> dict:
    """
    Only reached when looping back. Promotes gap_questions into
    active_questions for the next round, and appends them to the
    cumulative research_questions history. Increments the iteration
    counter, which route_after_evaluation uses to enforce the cap.
    """
    gap_questions = state.get("gap_questions", [])
    iteration = state.get("research_iteration", 0) + 1

    return {
        "research_iteration": iteration,
        "active_questions": gap_questions,
        "research_questions": list(state.get("research_questions", [])) + gap_questions,
    }


def route_after_evaluation(state: ResearchState) -> str:
    """
    Conditional edge function. LangGraph calls this after
    evaluate_sufficiency_node and routes to whichever node name is
    returned (mapped via add_conditional_edges' path_map below).
    """
    if state.get("error"):
        return "end"
    if state.get("sufficient", True):
        return "end"
    if not state.get("gap_questions"):
        return "end"
    if state.get("research_iteration", 0) >= MAX_RESEARCH_ROUNDS:
        return "end"
    return "loop"


def build_graph():
    """
    plan -> decide_sources -> research_web -> research_docs -> research_github
          -> evaluate_sufficiency -> [conditional]
                 "end"  -> END
                 "loop" -> prepare_next_round -> decide_sources  (cycle back)

    This is the first cyclic part of the graph. The cycle is bounded by
    MAX_RESEARCH_ROUNDS via route_after_evaluation — no matter what the
    evaluator decides, the graph cannot loop indefinitely.
    """
    graph = StateGraph(ResearchState)

    graph.add_node("plan", plan_node)
    graph.add_node("decide_sources", decide_sources_node)
    graph.add_node("research_web", research_web_node)
    graph.add_node("research_docs", research_docs_node)
    graph.add_node("research_github", research_github_node)
    graph.add_node("evaluate_sufficiency", evaluate_sufficiency_node)
    graph.add_node("prepare_next_round", prepare_next_round_node)

    graph.set_entry_point("plan")
    graph.add_edge("plan", "decide_sources")
    graph.add_edge("decide_sources", "research_web")
    graph.add_edge("research_web", "research_docs")
    graph.add_edge("research_docs", "research_github")
    graph.add_edge("research_github", "evaluate_sufficiency")

    graph.add_conditional_edges(
        "evaluate_sufficiency",
        route_after_evaluation,
        {"end": END, "loop": "prepare_next_round"},
    )
    graph.add_edge("prepare_next_round", "decide_sources")

    return graph.compile()


research_graph = build_graph()
EOF

# ---------------------------------------------------------------------------
# Backend: schemas.py - expose sufficiency + round count in the response
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
    # Full history across all rounds — see ResearchState.research_questions.
    research_questions: List[str]


class EvidenceItem(BaseModel):
    question: str
    source_type: str
    source_title: str
    source_url: str
    claim: str


class ResearchRunResponse(BaseModel):
    run_id: str
    status: str
    query: str
    message: str
    plan: Optional[Plan] = None
    source_decisions: Optional[Dict[str, List[str]]] = None
    evidence: Optional[List[EvidenceItem]] = None
    warnings: Optional[List[str]] = None
    # New in Phase 6:
    sufficient: Optional[bool] = None
    # How many research rounds actually ran (1 = no looping occurred,
    # 2+ = the sufficiency loop fired at least once).
    research_rounds: Optional[int] = None
EOF

# ---------------------------------------------------------------------------
# Backend: routes.py - surface sufficient/research_rounds
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
        status="research_complete",
        query=payload.query,
        message="Research plan, source routing, and evidence gathered.",
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
        evidence=final_state.get("evidence", []),
        warnings=final_state.get("research_warnings"),
        sufficient=final_state.get("sufficient"),
        research_rounds=final_state.get("research_iteration", 0) + 1,
    )
EOF

# ---------------------------------------------------------------------------
# Frontend: show sufficiency + round count
# ---------------------------------------------------------------------------

python3 - << 'PYEOF'
path = "frontend/src/components/ResearchForm.tsx"
with open(path) as f:
    content = f.read()

old_interface = '''interface ResearchRunResponse {
  run_id: string;
  status: string;
  query: string;
  message: string;
  plan: Plan | null;
  source_decisions: Record<string, string[]> | null;
  evidence: EvidenceItem[] | null;
  warnings: string[] | null;
}'''

new_interface = '''interface ResearchRunResponse {
  run_id: string;
  status: string;
  query: string;
  message: string;
  plan: Plan | null;
  source_decisions: Record<string, string[]> | null;
  evidence: EvidenceItem[] | null;
  warnings: string[] | null;
  sufficient: boolean | null;
  research_rounds: number | null;
}'''

old_status_block = '''          <p><strong>Status:</strong> {result.status}</p>
          <p><strong>Run ID:</strong> {result.run_id}</p>'''

new_status_block = '''          <p><strong>Status:</strong> {result.status}</p>
          <p><strong>Run ID:</strong> {result.run_id}</p>
          {result.research_rounds !== null && (
            <p>
              <strong>Research rounds:</strong> {result.research_rounds}
              {result.sufficient !== null && (
                <span className="text-gray-500">
                  {" "}({result.sufficient ? "evidence judged sufficient" : "stopped at round cap"})
                </span>
              )}
            </p>
          )}'''

if old_interface in content and old_status_block in content:
    content = content.replace(old_interface, new_interface)
    content = content.replace(old_status_block, new_status_block)
    with open(path, "w") as f:
        f.write(content)
    print("Updated ResearchForm.tsx with sufficiency/round display.")
else:
    print("WARNING: expected blocks not found in ResearchForm.tsx — check the file manually.")
PYEOF

echo ""
echo "Phase 6 files created/updated:"
echo "  backend/app/state.py (updated: active_questions, sufficient, gap_questions, research_iteration)"
echo "  backend/app/evaluation.py (new: evaluate_sufficiency)"
echo "  backend/app/graph.py (updated: evaluate_sufficiency + prepare_next_round nodes, conditional loop edge)"
echo "  backend/app/schemas.py (updated: sufficient, research_rounds)"
echo "  backend/app/routes.py (updated: surfaces sufficient/research_rounds)"
echo "  frontend/src/components/ResearchForm.tsx (updated: shows research rounds + sufficiency)"
echo ""
echo "No new dependencies, no .env changes. Just restart the backend + frontend."
