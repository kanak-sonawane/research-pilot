#!/usr/bin/env bash
set -e

# Phase 5 — Docs Discovery & GitHub Research
# Run this from the root of your research-pilot/ project.

echo "Setting up Phase 5 files..."

# ---------------------------------------------------------------------------
# Backend: config - add GITHUB_TOKEN
# ---------------------------------------------------------------------------

cat > backend/app/config.py << 'EOF'
import os

from dotenv import load_dotenv

load_dotenv()

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen3:8b")
TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")
EOF

if [ -f backend/.env.example ] && ! grep -q "GITHUB_TOKEN" backend/.env.example; then
  echo "GITHUB_TOKEN=" >> backend/.env.example
fi

echo ""
echo "IMPORTANT: add your real token to backend/.env (NOT .env.example):"
echo "  GITHUB_TOKEN=your-actual-token-here"
echo ""

# ---------------------------------------------------------------------------
# Backend: web_research.py - generalize for reuse by docs/github modules
# ---------------------------------------------------------------------------

cat > backend/app/web_research.py << 'EOF'
import json

from tavily import TavilyClient

from app.config import TAVILY_API_KEY
from app.llm_service import call_llm
from app.json_utils import extract_json_object

EVIDENCE_SYSTEM_PROMPT = """You are a research evidence extraction assistant. Given a research question
and a numbered set of search results, extract discrete, specific evidence statements
that help answer the question.

Rules:
- Only extract claims that are actually supported by the provided content. Never add outside knowledge.
- Each evidence item must cite exactly one source, by its number, from the provided results.
- If none of the results are relevant, return an empty evidence list.
- Prefer several precise, atomic claims over one broad summary.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"evidence": [{"claim": "...", "source_index": 0}, ...]}
"""


class ResearchError(Exception):
    """
    Generic research failure, shared across every source module (web,
    docs, github). Kept as one exception type rather than one per module
    so graph.py's per-question error handling in research nodes doesn't
    need a growing list of except clauses as more source types are added.
    """


def get_client() -> TavilyClient:
    """
    Public (not underscore-prefixed) because docs_research.py reuses this
    same Tavily client rather than constructing its own — docs discovery
    in this project is implemented as a scoped Tavily search, not a
    separate API integration, so sharing the client avoids a redundant
    second connection/config path.
    """
    if not TAVILY_API_KEY:
        raise ResearchError("TAVILY_API_KEY is not set. Add it to backend/.env.")
    return TavilyClient(api_key=TAVILY_API_KEY)


def search_web(query: str, max_results: int = 5) -> list[dict]:
    try:
        client = get_client()
        response = client.search(query=query, max_results=max_results)
        return response.get("results", [])
    except ResearchError:
        raise
    except Exception as e:
        raise ResearchError(f"Tavily search failed for '{query}': {e}") from e


def extract_evidence(question: str, results: list[dict], source_type: str = "web") -> list[dict]:
    """
    Turns raw search results into structured evidence tied to `question`.
    `source_type` is stamped onto each evidence item as-is — this function
    doesn't care whether results came from Tavily's general web search,
    a docs-scoped search, or GitHub's API; it only needs the common
    {"title", "url", "content"} shape, which every source module
    normalizes its results into before calling this.
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
        raise ResearchError(f"Could not parse evidence output: {e}") from e

    raw_evidence = parsed.get("evidence", [])
    if not isinstance(raw_evidence, list):
        raise ResearchError(f"'evidence' must be a list: {parsed}")

    evidence_items = []
    for item in raw_evidence:
        claim = item.get("claim")
        idx = item.get("source_index")

        if claim is None or not isinstance(idx, int) or not (0 <= idx < len(results)):
            continue

        source = results[idx]
        evidence_items.append({
            "question": question,
            "source_type": source_type,
            "source_title": source.get("title", ""),
            "source_url": source.get("url", ""),
            "claim": claim,
        })

    return evidence_items


def research_question_web(question: str) -> list[dict]:
    results = search_web(question)
    return extract_evidence(question, results, source_type="web")
EOF

# ---------------------------------------------------------------------------
# Backend: docs_research.py - dynamic docs discovery via scoped search
# ---------------------------------------------------------------------------

cat > backend/app/docs_research.py << 'EOF'
from app.web_research import get_client, extract_evidence, ResearchError

# Dynamic discovery, per the PRD, means we don't hardcode a list of docs
# sites per library. Instead we scope a normal web search toward
# documentation specifically by appending this qualifier to the query,
# and let the search engine's own ranking surface the actual official
# docs page for whatever library/tool the question is about.
DOCS_QUERY_SUFFIX = " official documentation"


def search_docs(query: str, max_results: int = 5) -> list[dict]:
    try:
        client = get_client()
        response = client.search(query=query + DOCS_QUERY_SUFFIX, max_results=max_results)
        return response.get("results", [])
    except ResearchError:
        raise
    except Exception as e:
        raise ResearchError(f"Docs search failed for '{query}': {e}") from e


def research_question_docs(question: str) -> list[dict]:
    results = search_docs(question)
    return extract_evidence(question, results, source_type="docs")
EOF

# ---------------------------------------------------------------------------
# Backend: github_research.py - GitHub repository search
# ---------------------------------------------------------------------------

cat > backend/app/github_research.py << 'EOF'
import requests

from app.config import GITHUB_TOKEN
from app.web_research import extract_evidence, ResearchError

GITHUB_SEARCH_URL = "https://api.github.com/search/repositories"


def search_github(query: str, max_results: int = 5) -> list[dict]:
    """
    Searches GitHub repositories (not code search — repo search is more
    stable/less rate-limited and repo descriptions + READMEs top hits
    are usually enough to answer "how is X implemented/used" style
    questions at MVP quality).

    Results are normalized into the same {"title", "url", "content"}
    shape extract_evidence() expects, regardless of source.
    """
    if not GITHUB_TOKEN:
        raise ResearchError("GITHUB_TOKEN is not set. Add it to backend/.env.")

    headers = {
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
    }
    params = {"q": query, "per_page": max_results, "sort": "stars", "order": "desc"}

    try:
        response = requests.get(GITHUB_SEARCH_URL, headers=headers, params=params, timeout=15)
        response.raise_for_status()
    except requests.RequestException as e:
        raise ResearchError(f"GitHub search failed for '{query}': {e}") from e

    items = response.json().get("items", [])
    return [
        {
            "title": item.get("full_name", ""),
            "url": item.get("html_url", ""),
            "content": item.get("description") or "",
        }
        for item in items
    ]


def research_question_github(question: str) -> list[dict]:
    results = search_github(question)
    return extract_evidence(question, results, source_type="github")
EOF

# ---------------------------------------------------------------------------
# Backend: state.py - generalize warnings field name (web + docs + github now)
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
    research_questions: List[str]

    source_decisions: Dict[str, List[str]]

    # Accumulated across research_web / research_docs / research_github.
    # Each item: {"question", "source_type", "source_title", "source_url", "claim"}
    evidence: List[dict]
    # Non-fatal per-question failures from ANY source type (renamed from
    # web_research_warnings now that docs/github contribute here too).
    research_warnings: List[str]

    error: Optional[str]

    # Future phases will add: evaluation, report
EOF

# ---------------------------------------------------------------------------
# Backend: graph.py - shared node factory + three research nodes
# ---------------------------------------------------------------------------

cat > backend/app/graph.py << 'EOF'
from langgraph.graph import StateGraph, END

from app.state import ResearchState
from app.planning import generate_plan, PlanningError
from app.source_decision import decide_sources, SourceDecisionError
from app.web_research import research_question_web, ResearchError
from app.docs_research import research_question_docs
from app.github_research import research_question_github


def plan_node(state: ResearchState) -> dict:
    try:
        plan = generate_plan(state["query"])
        return {
            "objective": plan["objective"],
            "research_questions": plan["research_questions"],
        }
    except PlanningError as e:
        return {"error": f"Planning failed: {e}"}


def decide_sources_node(state: ResearchState) -> dict:
    if state.get("error"):
        return {}
    try:
        decisions = decide_sources(state["research_questions"])
        return {"source_decisions": decisions}
    except SourceDecisionError as e:
        return {"error": f"Source decision failed: {e}"}


def _build_research_node(source_type: str, research_fn):
    """
    Factory for a per-source-type research node. web/docs/github research
    nodes are structurally identical: skip questions not routed to this
    source, run research_fn per question, collect failures as warnings
    instead of aborting the run. Pulled into one factory instead of three
    copy-pasted node functions now that there are three source types.

    Correctness detail: reads state["evidence"]/state["research_warnings"]
    as a starting point and extends them, rather than starting fresh.
    LangGraph merges returned dicts by replacing keys wholesale, not by
    concatenating lists — if this node returned only ITS OWN new evidence
    under the "evidence" key, it would overwrite (delete) whatever prior
    nodes already accumulated there.
    """

    def node(state: ResearchState) -> dict:
        if state.get("error"):
            return {}

        source_decisions = state.get("source_decisions", {})
        evidence = list(state.get("evidence", []))
        warnings = list(state.get("research_warnings", []))

        for question, sources in source_decisions.items():
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


def build_graph():
    """
    plan -> decide_sources -> research_web -> research_docs -> research_github -> END

    Sequential rather than parallel for now — correctness and simplicity
    over speed at this stage. Phase 6 adds the sufficiency-evaluation loop
    as a conditional edge after this chain, before report generation.
    """
    graph = StateGraph(ResearchState)

    graph.add_node("plan", plan_node)
    graph.add_node("decide_sources", decide_sources_node)
    graph.add_node("research_web", research_web_node)
    graph.add_node("research_docs", research_docs_node)
    graph.add_node("research_github", research_github_node)

    graph.set_entry_point("plan")
    graph.add_edge("plan", "decide_sources")
    graph.add_edge("decide_sources", "research_web")
    graph.add_edge("research_web", "research_docs")
    graph.add_edge("research_docs", "research_github")
    graph.add_edge("research_github", END)

    return graph.compile()


research_graph = build_graph()
EOF

# ---------------------------------------------------------------------------
# Backend: routes.py - read the renamed state key, broaden status name
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
        message="Research plan, source routing, and evidence (web/docs/github) gathered.",
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
        evidence=final_state.get("evidence", []),
        warnings=final_state.get("research_warnings"),
    )
EOF

# ---------------------------------------------------------------------------
# Backend: ensure requests is available (used by github_research.py)
# ---------------------------------------------------------------------------

if ! grep -q "^requests" backend/requirements.txt 2>/dev/null; then
  echo "requests" >> backend/requirements.txt
fi

# ---------------------------------------------------------------------------
# Frontend: tag each evidence item with its source type
# ---------------------------------------------------------------------------

python3 - << 'PYEOF'
path = "frontend/src/components/ResearchForm.tsx"
with open(path) as f:
    content = f.read()

old = '''                        {evidenceForQuestion(q).map((ev, j) => (
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
                        ))}'''

new = '''                        {evidenceForQuestion(q).map((ev, j) => (
                          <li key={j}>
                            <span className="text-gray-400 uppercase text-xs mr-1">
                              {ev.source_type}
                            </span>
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
                        ))}'''

if old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("Tagged evidence items with source_type in ResearchForm.tsx")
else:
    print("WARNING: could not find expected evidence-rendering block in ResearchForm.tsx — skipped auto-edit, check the file manually if the source-type tag is missing.")
PYEOF

echo ""
echo "Phase 5 files created/updated:"
echo "  backend/app/config.py (updated: added GITHUB_TOKEN)"
echo "  backend/.env.example (updated: added GITHUB_TOKEN placeholder)"
echo "  backend/app/web_research.py (refactored: ResearchError, get_client, extract_evidence takes source_type)"
echo "  backend/app/docs_research.py (new: scoped-search docs discovery)"
echo "  backend/app/github_research.py (new: GitHub repo search)"
echo "  backend/app/state.py (updated: research_warnings replaces web_research_warnings)"
echo "  backend/app/graph.py (updated: shared _build_research_node factory, 3 research nodes)"
echo "  backend/app/routes.py (updated: status is now research_complete)"
echo "  backend/requirements.txt (ensured requests present)"
echo "  frontend/src/components/ResearchForm.tsx (updated: evidence tagged with source type)"
echo ""
echo "REQUIRED before restarting the backend:"
echo "  1. Add your real token to backend/.env:  GITHUB_TOKEN=your-actual-token-here"
echo "  2. pip install -r backend/requirements.txt"
