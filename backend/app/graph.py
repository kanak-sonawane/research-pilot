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
