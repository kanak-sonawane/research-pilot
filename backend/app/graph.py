import concurrent.futures

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

# Bounds how many questions' research runs concurrently per source-type
# node. Kept modest (not "as many as possible") for two reasons: a local
# Ollama instance can only usefully handle a limited number of concurrent
# generate requests before they start queuing anyway (depends on hardware
# and OLLAMA_NUM_PARALLEL), and external APIs (Tavily, GitHub) have their
# own rate limits that many simultaneous requests could trip.
MAX_WORKERS = 3


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

    Questions routed to this source type are researched CONCURRENTLY via
    a thread pool, not one at a time in a loop. Each question's research
    (a search call + an LLM extraction call, and for github an extra
    query-reformulation call) is completely independent of every other
    question's — nothing about researching question A depends on having
    already finished question B. Previously N questions took roughly N
    times one question's worth of sequential wall-clock time; now they
    take roughly 1x, bounded by MAX_WORKERS. This is a pure latency
    optimization — it changes nothing about what gets searched, what
    gets extracted, or what evidence looks like; only how much wall-clock
    time it takes to gather it.

    Thread-safety note: each thread only calls research_fn(question),
    which does its own independent network/LLM calls and returns a
    result — no shared mutable state is touched inside the threads.
    Results are merged into `evidence`/`warnings` only in the main
    thread, after each future completes, so there's no concurrent
    write hazard on those lists.
    """

    def node(state: ResearchState) -> dict:
        if state.get("error"):
            return {}

        active_questions = state.get("active_questions", [])
        source_decisions = state.get("source_decisions", {})
        evidence = list(state.get("evidence", []))
        warnings = list(state.get("research_warnings", []))

        questions_to_research = [
            q for q in active_questions if source_type in source_decisions.get(q, [])
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
