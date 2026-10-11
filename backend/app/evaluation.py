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
