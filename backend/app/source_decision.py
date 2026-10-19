import json
import re

from app.llm_service import call_llm
from app.json_utils import extract_json_object

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
    try:
        return extract_json_object(raw_text)
    except ValueError as e:
        raise SourceDecisionError(str(e)) from e


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
        if not isinstance(entry, dict):
            continue  # a malformed entry used to crash the run (HTTP 500)
        question = entry.get("question")
        sources = entry.get("sources", [])
        if not isinstance(question, str) or not question:
            continue
        if not isinstance(sources, list):
            sources = []
        valid_sources = [s for s in sources if isinstance(s, str) and s in VALID_SOURCES]
        result[question] = valid_sources if valid_sources else ["web"]

    # Guarantee every original question has an entry, even if the model
    # dropped one — never let a question silently fall out of the plan.
    for q in research_questions:
        if q not in result:
            result[q] = ["web"]

    return result
