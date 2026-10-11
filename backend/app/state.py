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
