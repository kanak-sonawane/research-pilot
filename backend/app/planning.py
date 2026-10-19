import json
import re

from app.llm_service import call_llm
from app.json_utils import extract_json_object

PLANNING_SYSTEM_PROMPT = """You are a research planning assistant. Given a technical research topic, produce:
1. A one-sentence objective describing what the research should establish.
2. A list of 3 to 5 precise, non-overlapping research questions that together satisfy the objective.

Rules:
- Research questions must be specific and answerable through documentation, web sources, or code repositories — not opinion.
- Every question must be self-contained: name the specific technology, library or language it is about (for example: in Python's requests library), so it still makes sense on its own and works as a search query.
- Do not include more than 5 questions. Prefer fewer, sharper questions over many broad ones.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"objective": "...", "research_questions": ["...", "..."]}
"""


class PlanningError(Exception):
    """Raised when planning fails or the model output can't be parsed into a plan."""


def _extract_json(raw_text: str) -> dict:
    try:
        return extract_json_object(raw_text)
    except ValueError as e:
        raise PlanningError(str(e)) from e


def generate_plan(query: str) -> dict:
    """
    Calls the LLM to turn a raw query into an objective + research questions.
    Returns a dict shaped like {"objective": str, "research_questions": [str, ...]}.
    """
    raw = call_llm(PLANNING_SYSTEM_PROMPT, query)

    try:
        parsed = _extract_json(raw)
    except (json.JSONDecodeError, PlanningError) as e:
        raise PlanningError(f"Could not parse plan from model output: {e}") from e

    if "objective" not in parsed or "research_questions" not in parsed:
        raise PlanningError(f"Plan JSON missing required keys: {parsed}")

    if not isinstance(parsed["research_questions"], list) or not parsed["research_questions"]:
        raise PlanningError(f"research_questions must be a non-empty list: {parsed}")

    # The model's output is validated, not trusted: keep only non-empty string questions and a
    # string objective (non-string values used to crash the run with an HTTP 500).
    questions = [" ".join(q.split()) for q in parsed["research_questions"] if isinstance(q, str) and q.strip()]
    if not questions:
        raise PlanningError("The plan contained no usable research questions.")

    objective = parsed["objective"]
    if not isinstance(objective, str) or not objective.strip():
        objective = " ".join(query.split())

    return {"objective": objective, "research_questions": questions[:5]}
