#!/usr/bin/env bash
set -e

# Phase 7 speed fix.
# Run from the root of your research-pilot/ project, AFTER phase7_setup.sh.
#
# What it changes (all aimed at wall-clock time on a local 8B model):
#   1. llm_service.py : prints one timing line per LLM call (time, tokens in/out,
#                       tokens/sec); turns Qwen3 "thinking" OFF by default; caps
#                       generated tokens; strips <think> blocks; runs only
#                       OLLAMA_CONCURRENCY (default 1) LLM calls at a time.
#   2. graph.py       : prints one timing line per node; retries an unanswered
#                       question ONLY with a source it has not tried yet (instead
#                       of repeating an identical search); skips the evaluator LLM
#                       call when the answer is already known; default extra
#                       rounds lowered from 2 to 1 (MAX_RESEARCH_ROUNDS).
#   3. web_research.py: at most 5 evidence items per call, shorter quotes.
#   4. report.py      : shorter, fewer findings.

echo "Applying Phase 7 speed fix..."

# ---------------------------------------------------------------------------
# config.py
# ---------------------------------------------------------------------------

cat > backend/app/config.py << 'EOF'
import os

from dotenv import load_dotenv

load_dotenv()


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen3:8b")
TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")

# Qwen3 "reasons" before answering by default. Those hidden tokens are slow to
# generate and our tasks (extraction, routing, short JSON) don't need them.
# Set OLLAMA_THINK=true in .env to turn reasoning back on.
OLLAMA_THINK = _env_bool("OLLAMA_THINK", False)

# Safety cap on tokens generated per LLM call (stops runaway generations).
OLLAMA_MAX_TOKENS = int(os.getenv("OLLAMA_MAX_TOKENS", "2048"))

# How many LLM calls may be in flight at once. A single local GPU doesn't
# speed up with parallel requests, so the default is 1.
OLLAMA_CONCURRENCY = max(1, int(os.getenv("OLLAMA_CONCURRENCY", "1")))

# Extra research rounds allowed after the first.
MAX_RESEARCH_ROUNDS = int(os.getenv("MAX_RESEARCH_ROUNDS", "1"))
EOF

if [ -f backend/.env.example ]; then
  for line in "OLLAMA_THINK=false" "OLLAMA_MAX_TOKENS=2048" "OLLAMA_CONCURRENCY=1" "MAX_RESEARCH_ROUNDS=1"; do
    key="${line%%=*}"
    grep -q "^${key}=" backend/.env.example || echo "$line" >> backend/.env.example
  done
fi

# ---------------------------------------------------------------------------
# llm_service.py
# ---------------------------------------------------------------------------

cat > backend/app/llm_service.py << 'EOF'
import re
import threading
import time

import ollama

from app.config import (
    OLLAMA_CONCURRENCY,
    OLLAMA_MAX_TOKENS,
    OLLAMA_MODEL,
    OLLAMA_THINK,
)


class LLMError(Exception):
    """Raised when the LLM call fails or returns something unusable."""


# Limits simultaneous calls into Ollama. Extra threads wait here instead of
# piling onto the server (which can allocate extra memory per parallel slot).
_slots = threading.Semaphore(OLLAMA_CONCURRENCY)

_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL)
_THINK_UNCLOSED = re.compile(r"<think>.*", re.DOTALL)


def _get(obj, name, default=None):
    """Reads a field from an ollama response whether it behaves like a dict or an object."""
    try:
        value = obj[name]
    except Exception:
        value = getattr(obj, name, default)
    return default if value is None else value


def _chat(messages):
    options = {"num_predict": OLLAMA_MAX_TOKENS}

    if OLLAMA_THINK:
        return ollama.chat(model=OLLAMA_MODEL, messages=messages, options=options)

    try:
        return ollama.chat(model=OLLAMA_MODEL, messages=messages, options=options, think=False)
    except (TypeError, ollama.ResponseError):
        # Older client/server without the `think` option: use Qwen3's
        # soft switch in the prompt instead.
        fallback = [dict(m) for m in messages]
        fallback[-1]["content"] = fallback[-1]["content"] + " /no_think"
        return ollama.chat(model=OLLAMA_MODEL, messages=fallback, options=options)


def call_llm(system_prompt: str, user_prompt: str) -> str:
    """
    Single choke point for every Ollama call.

    Prints one timing line per call, for example:
      [llm] 'You are a research evidence extraction assistant.': 41.2s run, 0.0s queued, in=1510 out=402 tok (9.8 tok/s)
    'out' is the number of tokens the model generated; if it is far larger
    than the visible answer, the model is spending time on hidden reasoning.
    """
    first_line = system_prompt.strip().splitlines()[0] if system_prompt.strip() else "llm"
    label = first_line[:60]

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]

    waiting_since = time.perf_counter()
    with _slots:
        started = time.perf_counter()
        try:
            response = _chat(messages)
        except Exception as e:
            raise LLMError(f"LLM call failed: {e}") from e
        finished = time.perf_counter()

    message = _get(response, "message")
    content = _get(message, "content", "") or ""
    content = _THINK_BLOCK.sub("", content)
    content = _THINK_UNCLOSED.sub("", content).strip()

    run_seconds = finished - started
    out_tokens = _get(response, "eval_count", 0)
    in_tokens = _get(response, "prompt_eval_count", 0)
    rate = (out_tokens / run_seconds) if run_seconds > 0 and out_tokens else 0.0
    truncated = " TRUNCATED(hit token cap)" if _get(response, "done_reason", "") == "length" else ""
    print(
        f"[llm] {label!r}: {run_seconds:.1f}s run, {started - waiting_since:.1f}s queued, "
        f"in={in_tokens} out={out_tokens} tok ({rate:.1f} tok/s){truncated}",
        flush=True,
    )

    return content
EOF

# ---------------------------------------------------------------------------
# state.py — adds round_sources
# ---------------------------------------------------------------------------

cat > backend/app/state.py << 'EOF'
from typing import Dict, List, Optional, TypedDict


class ResearchState(TypedDict, total=False):
    """
    Shared state threaded through every node in the LangGraph graph.
    `total=False`: fields are populated incrementally, not all present
    at every point in a run. Read with .get().
    """

    run_id: str
    query: str

    objective: str

    # ALL research questions ever asked, across every round. Never overwritten.
    research_questions: List[str]

    # Only the CURRENT round's questions. Replaced each round.
    active_questions: List[str]

    # CUMULATIVE: every source type each question has been routed to (tried).
    source_decisions: Dict[str, List[str]]

    # THIS ROUND only: which sources to run for each active question.
    # Replaced every round by decide_sources_node.
    round_sources: Dict[str, List[str]]

    # Accumulated across all research nodes and rounds. Each item:
    # {"question", "source_type", "source_title", "source_url", "claim", "quote"}
    evidence: List[dict]
    research_warnings: List[str]

    sufficient: bool
    gap_questions: List[str]

    # Absent == 0. Incremented by prepare_next_round_node.
    research_iteration: int

    report: dict

    error: Optional[str]
EOF

# ---------------------------------------------------------------------------
# graph.py — timing, smarter retries, fewer evaluator calls
# ---------------------------------------------------------------------------

cat > backend/app/graph.py << 'EOF'
import concurrent.futures
import time
from typing import Dict, List

from langgraph.graph import StateGraph, END

from app.config import MAX_RESEARCH_ROUNDS
from app.state import ResearchState
from app.llm_service import LLMError
from app.planning import generate_plan, PlanningError
from app.source_decision import decide_sources, SourceDecisionError
from app.web_research import research_question_web, ResearchError
from app.docs_research import research_question_docs
from app.github_research import research_question_github
from app.evaluation import evaluate_sufficiency, EvaluationError
from app.report import generate_report

# How many questions' research runs concurrently per source-type node.
# (Network searches overlap; LLM calls are serialized by llm_service.)
MAX_WORKERS = 3

# Every source type a question can be tried on.
SOURCES = ("web", "docs", "github")


def _timed(name: str, fn):
    """Wraps a node so each run prints how long it took."""

    def wrapper(state):
        started = time.perf_counter()
        result = fn(state)
        print(f"[node] {name}: {time.perf_counter() - started:.1f}s", flush=True)
        return result

    return wrapper


def plan_node(state: ResearchState) -> dict:
    try:
        plan = generate_plan(state["query"])
        return {
            "objective": plan["objective"],
            "research_questions": plan["research_questions"],
            "active_questions": plan["research_questions"],
        }
    except (PlanningError, LLMError) as e:
        return {"error": f"Planning failed: {e}"}


def decide_sources_node(state: ResearchState) -> dict:
    """
    Decides which sources to run THIS round (round_sources) and keeps a
    cumulative record of everything tried (source_decisions).

    - A new question is routed by the LLM, as before.
    - A question that has already been researched (a retry) is NOT re-routed
      by the LLM and NOT repeated on the same sources: it only gets sources it
      hasn't been tried on yet. Repeating an identical search almost always
      returns the same empty result, so it only burns time.
    """
    if state.get("error"):
        return {}

    active = state.get("active_questions", [])
    previous: Dict[str, List[str]] = state.get("source_decisions", {})

    round_sources: Dict[str, List[str]] = {}
    to_route: List[str] = []
    for q in active:
        if q in previous:
            round_sources[q] = [s for s in SOURCES if s not in previous[q]]
        else:
            to_route.append(q)

    if to_route:
        try:
            round_sources.update(decide_sources(to_route))
        except (SourceDecisionError, LLMError) as e:
            return {"error": f"Source decision failed: {e}"}

    merged = {q: list(srcs) for q, srcs in previous.items()}
    for q, srcs in round_sources.items():
        merged[q] = list(dict.fromkeys(merged.get(q, []) + srcs))

    return {"source_decisions": merged, "round_sources": round_sources}


def _build_research_node(source_type: str, research_fn):
    """
    Researches this round's questions routed to `source_type`, concurrently.
    Worker threads only call research_fn; results are merged into the lists in
    the main thread, so no shared state is mutated concurrently.
    """

    def node(state: ResearchState) -> dict:
        if state.get("error"):
            return {}

        active_questions = state.get("active_questions", [])
        round_sources = state.get("round_sources", {})
        evidence = list(state.get("evidence", []))
        warnings = list(state.get("research_warnings", []))

        questions_to_research = [
            q for q in active_questions if source_type in round_sources.get(q, [])
        ]
        if not questions_to_research:
            return {}

        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            future_to_question = {
                executor.submit(research_fn, q): q for q in questions_to_research
            }
            for future in concurrent.futures.as_completed(future_to_question):
                question = future_to_question[future]
                try:
                    evidence.extend(future.result())
                except (ResearchError, LLMError) as e:
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
    1. Deterministic check first (no LLM call): which questions still have no
       evidence? A question is only worth another round if it has a source it
       hasn't been tried on yet, and the round cap allows it.
    2. Only when every question has evidence is the LLM evaluator called, to
       look for deeper gaps. (If questions are unanswered, we already know the
       answer to "is this sufficient?", so the call would be wasted time.)
    """
    if state.get("error"):
        return {}

    decisions = state.get("source_decisions", {})
    iteration = state.get("research_iteration", 0)
    answered = {e.get("question") for e in state.get("evidence", [])}
    unanswered = [q for q in state.get("research_questions", []) if q not in answered]
    retryable = [q for q in unanswered if any(s not in decisions.get(q, []) for s in SOURCES)]

    if retryable and iteration < MAX_RESEARCH_ROUNDS:
        return {"sufficient": False, "gap_questions": retryable[:3]}

    if unanswered:
        return {"sufficient": False, "gap_questions": []}

    try:
        result = evaluate_sufficiency(
            state.get("objective", ""),
            state.get("research_questions", []),
            state.get("evidence", []),
        )
        return {"sufficient": result["sufficient"], "gap_questions": result["gap_questions"]}
    except (EvaluationError, LLMError) as e:
        warnings = list(state.get("research_warnings", []))
        warnings.append(f"Sufficiency evaluation failed, stopping with current evidence: {e}")
        return {"sufficient": True, "gap_questions": [], "research_warnings": warnings}


def prepare_next_round_node(state: ResearchState) -> dict:
    gap_questions = state.get("gap_questions", [])
    iteration = state.get("research_iteration", 0) + 1
    existing = list(state.get("research_questions", []))
    new_questions = [q for q in gap_questions if q not in existing]

    return {
        "research_iteration": iteration,
        "active_questions": gap_questions,
        "research_questions": existing + new_questions,
    }


def route_after_evaluation(state: ResearchState) -> str:
    if state.get("error"):
        return "end"
    if state.get("sufficient", True):
        return "end"
    if not state.get("gap_questions"):
        return "end"
    if state.get("research_iteration", 0) >= MAX_RESEARCH_ROUNDS:
        return "end"
    return "loop"


def generate_report_node(state: ResearchState) -> dict:
    if state.get("error"):
        return {}
    try:
        return {"report": generate_report(dict(state))}
    except Exception as e:  # noqa: BLE001 — last-resort guard, evidence is never discarded
        warnings = list(state.get("research_warnings", []))
        warnings.append(f"Report generation failed: {e}")
        return {"research_warnings": warnings}


def build_graph():
    """
    plan -> decide_sources -> research_web -> research_docs -> research_github
          -> evaluate_sufficiency -> [conditional]
                 "end"  -> generate_report -> END
                 "loop" -> prepare_next_round -> decide_sources   (bounded cycle)
    """
    graph = StateGraph(ResearchState)

    graph.add_node("plan", _timed("plan", plan_node))
    graph.add_node("decide_sources", _timed("decide_sources", decide_sources_node))
    graph.add_node("research_web", _timed("research_web", research_web_node))
    graph.add_node("research_docs", _timed("research_docs", research_docs_node))
    graph.add_node("research_github", _timed("research_github", research_github_node))
    graph.add_node("evaluate_sufficiency", _timed("evaluate_sufficiency", evaluate_sufficiency_node))
    graph.add_node("prepare_next_round", prepare_next_round_node)
    graph.add_node("generate_report", _timed("generate_report", generate_report_node))

    graph.set_entry_point("plan")
    graph.add_edge("plan", "decide_sources")
    graph.add_edge("decide_sources", "research_web")
    graph.add_edge("research_web", "research_docs")
    graph.add_edge("research_docs", "research_github")
    graph.add_edge("research_github", "evaluate_sufficiency")

    graph.add_conditional_edges(
        "evaluate_sufficiency",
        route_after_evaluation,
        {"end": "generate_report", "loop": "prepare_next_round"},
    )
    graph.add_edge("prepare_next_round", "decide_sources")
    graph.add_edge("generate_report", END)

    return graph.compile()


research_graph = build_graph()
EOF

# ---------------------------------------------------------------------------
# Small targeted patches (each fails loudly if the expected text isn't there)
# ---------------------------------------------------------------------------

python3 - << 'PYEOF'
def patch(path, replacements):
    with open(path) as f:
        content = f.read()
    for old, new in replacements:
        if old not in content:
            raise SystemExit(f"PATCH FAILED in {path}: could not find:\n{old}")
        content = content.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(content)
    print(f"patched {path}")


patch("backend/app/web_research.py", [
    (
        "REATTRIBUTION_MARGIN = 0.15\n",
        "REATTRIBUTION_MARGIN = 0.15\n\n"
        "# Hard cap on evidence items kept per extraction call. Fewer, sharper\n"
        "# claims mean fewer tokens to generate, which is the main cost on a local model.\n"
        "MAX_EVIDENCE_PER_CALL = 5\n",
    ),
    ("a phrase of at most 25 words copied as", "a phrase of at most 15 words copied as"),
    (
        "- Prefer several precise, atomic claims over one broad summary.",
        "- Prefer precise, atomic claims over one broad summary, and return at most 5 evidence items in\n"
        "  total (the ones most relevant to the question).",
    ),
    (
        "        raise ResearchError(f\"'evidence' must be a list: {parsed}\")\n",
        "        raise ResearchError(f\"'evidence' must be a list: {parsed}\")\n"
        "    raw_evidence = raw_evidence[:MAX_EVIDENCE_PER_CALL]\n",
    ),
])

patch("backend/app/report.py", [
    ("MAX_FINDINGS_PER_SUBSECTION = 8", "MAX_FINDINGS_PER_SUBSECTION = 5"),
    (
        "- Group findings into 2 to 5 subsections with clear, topic-appropriate headings.",
        "- Group findings into 2 to 4 subsections with clear, topic-appropriate headings.\n"
        "- Keep each statement under 35 words.",
    ),
    (
        "\"Research stopped at the round limit before the evidence was judged sufficient.\"",
        "\"Research ended before the evidence was judged fully sufficient (round limit reached, or some \"\n"
        "            \"questions could not be answered from any source).\"",
    ),
])

patch("frontend/src/components/ResearchForm.tsx", [
    ('"stopped at round cap"', '"some questions unanswered or round limit reached"'),
])
PYEOF

echo ""
echo "Speed fix applied. Restart the backend (no new dependencies)."
echo ""
echo "Now run ONE query and watch the backend terminal. You will see lines like:"
echo "  [llm]  ...: 38.1s run, in=1500 out=380 tok (9.9 tok/s)"
echo "  [node] research_web: 52.3s"
echo "Paste those lines back (or just the total time and the biggest few lines)."
echo ""
echo "Optional .env settings (defaults are already the fast ones):"
echo "  OLLAMA_THINK=false       set true to re-enable Qwen3 reasoning (slower)"
echo "  MAX_RESEARCH_ROUNDS=1    extra rounds after the first"
echo "  OLLAMA_MAX_TOKENS=2048   per-call generation cap"
