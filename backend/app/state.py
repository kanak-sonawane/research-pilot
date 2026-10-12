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
