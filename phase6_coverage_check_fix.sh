#!/usr/bin/env bash
set -e

# Phase 6 fix — deterministic zero-evidence backstop in evaluate_sufficiency_node.
# Root cause: the LLM's sufficiency judgment is lenient — it judged BOTH
# verification runs "sufficient" despite each having a question with zero
# evidence. Rather than trying to prompt-engineer the model into never doing
# this, add a code-level check: directly compute which questions have no
# evidence at all, and force another round for those specific questions if
# the round cap allows it, regardless of what the LLM's own judgment said.
# Run this from the root of your research-pilot/ project.

echo "Applying Phase 6 coverage-check fix..."

python3 - << 'PYEOF'
path = "backend/app/graph.py"
with open(path) as f:
    content = f.read()

old = '''def evaluate_sufficiency_node(state: ResearchState) -> dict:
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
        return {"sufficient": True, "gap_questions": [], "research_warnings": warnings}'''

new = '''def evaluate_sufficiency_node(state: ResearchState) -> dict:
    """
    Judges whether accumulated evidence satisfies the objective. On
    evaluation failure itself (not a research failure — the evaluator
    LLM call/parse failing), this fails SAFE: treats the run as
    sufficient and stops, rather than looping forever or discarding
    evidence already gathered. A broken evaluator shouldn't mean the
    user gets nothing.

    After the LLM's own judgment, a DETERMINISTIC backstop runs: compute
    which questions (across the full research_questions history) have
    zero evidence items at all, by checking which questions appear in
    `evidence`. The LLM's sufficiency call judges overall coverage
    toward the objective and can be lenient about individual gaps — in
    testing it twice judged a run "sufficient" despite one question
    having no evidence whatsoever. Rather than trying to prompt-engineer
    that away, this check is unconditional: if any question has zero
    evidence and the round cap hasn't been reached, another round is
    forced for those specific questions regardless of what the LLM said.
    """
    if state.get("error"):
        return {}

    try:
        result = evaluate_sufficiency(
            state.get("objective", ""),
            state.get("research_questions", []),
            state.get("evidence", []),
        )
        sufficient = result["sufficient"]
        gap_questions = result["gap_questions"]
    except EvaluationError as e:
        warnings = list(state.get("research_warnings", []))
        warnings.append(f"Sufficiency evaluation failed, stopping with current evidence: {e}")
        return {"sufficient": True, "gap_questions": [], "research_warnings": warnings}

    answered_questions = {e.get("question") for e in state.get("evidence", [])}
    unanswered = [
        q for q in state.get("research_questions", []) if q not in answered_questions
    ]

    if unanswered and state.get("research_iteration", 0) < MAX_RESEARCH_ROUNDS:
        # Merge the deterministic gaps with whatever the LLM itself
        # proposed, de-duplicated, still capped at 3 total.
        merged_gaps = list(dict.fromkeys(unanswered + gap_questions))[:3]
        return {"sufficient": False, "gap_questions": merged_gaps}

    return {"sufficient": sufficient, "gap_questions": gap_questions}'''

if old not in content:
    raise SystemExit("WARNING: expected evaluate_sufficiency_node block not found — check backend/app/graph.py manually (it may already differ from the expected Phase 6 state).")

content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)

print("Added deterministic zero-evidence backstop to evaluate_sufficiency_node.")
PYEOF

echo ""
echo "Restart the backend, then re-run the SAME two queries from your Phase 6"
echo "verification. Both had a zero-evidence question, so both should now"
echo "show research_rounds >= 2 instead of 1."
