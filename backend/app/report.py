"""
Report generation (Phase 7).

Pipeline (see generate_report at the bottom):
  1. build_registry        evidence -> numbered evidence (E1..) + de-duplicated sources (S1..)   [code]
  2. synthesize_findings   LLM groups evidence into cited findings                               [LLM]
  3. validate_findings     drop findings whose evidence ids don't exist                          [code]
  4. build_information_architecture   LLM organises the topic from the validated findings        [LLM]
  5. build_methodology     describes what actually ran, from recorded state                       [code]
  6. validate_report       structural + traceability checks, produces the validation result       [code]

Anything that could be stated as fact from recorded state (methodology,
sources, limitations, unanswered questions) is produced by code, not by the
LLM, so the report cannot claim a tool or step that did not happen.
"""

import logging
from collections import defaultdict
from typing import Dict, List, Tuple

from app.config import OLLAMA_MODEL
from app.json_utils import extract_json_object
from app.llm_json import call_llm_json
from app.llm_service import call_llm, LLMError
from app.web_research import MAX_CONTENT_CHARS

logger = logging.getLogger(__name__)

# Hard caps enforced in code — never trust a count instruction in a prompt.
MAX_EVIDENCE_FOR_REPORT = 50
MAX_SUBSECTIONS = 6
MAX_FINDINGS_PER_SUBSECTION = 5
MAX_ARCH_GROUPS = 6
MAX_ARCH_ITEMS = 6

SOURCE_ORDER = ("web", "docs", "github")

TOOL_DESCRIPTIONS = {
    "web": "Tavily web search",
    "docs": "Tavily web search for documentation-style pages (queries suffixed with 'official documentation'; results are labelled by source, not verified as official)",
    "github": "GitHub repository search (LLM-generated keyword query, README retrieval for top results)",
}

FINDINGS_SYSTEM_PROMPT = """You are a research report writer. You are given a research objective and a
numbered list of evidence items. Each item is a factual claim extracted from a real source.
Write the Findings section of a technical research report.

Rules:
- Use ONLY the provided evidence. Never add outside knowledge.
- Each evidence item names its source. If the source is about a different technology, language or library than the one the objective is about (for example a Java framework when the objective is about Python), do not use that evidence.
- Group findings into 2 to 4 subsections with clear, topic-appropriate headings.
- Keep each statement under 35 words.
- Each finding is one or two sentences synthesizing one or more evidence items, and MUST list
  the ids of the evidence it relies on, exactly as written (for example "E1").
- Never write a finding that has no supporting evidence ids.
- Never claim that something does not exist, is not supported, or is missing unless an evidence item says so explicitly.
- If evidence from different sources disagrees, state the difference.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"subsections": [{"heading": "...", "findings": [{"statement": "...", "evidence_ids": ["E1", "E2"]}]}]}
"""

ARCHITECTURE_SYSTEM_PROMPT = """You are organizing a technical topic for a reader. You are given a research
objective and a list of findings. Produce an Information Architecture: a structured map of the
major concepts, components, or areas of the topic and how they group together.

Rules:
- Base every group and item only on things named in the findings. Never add outside knowledge.
- Produce 2 to 6 groups. Each group has a short name, a one-sentence description, and up to 6
  short items (concrete things named in the findings, such as libraries, parameters, strategies).
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"groups": [{"name": "...", "description": "...", "items": ["...", "..."]}]}
"""


# ---------------------------------------------------------------------------
# 1. Evidence / source registry
# ---------------------------------------------------------------------------

def build_registry(evidence: List[dict]) -> Tuple[List[dict], List[dict]]:
    """
    Assigns stable ids and consolidates duplicates.
    Returns (registry, sources):
      registry: [{"id": "E1", "claim", "quote", "question", "source_id", "source_type"}]
      sources:  [{"id": "S1", "title", "url", "source_types": [...]}]
    Sources are de-duplicated by URL (case-insensitive, trailing slash ignored).
    Identical claims from the same source are collapsed.
    """
    sources_by_key: Dict[str, dict] = {}
    registry: List[dict] = []
    seen = set()

    for item in evidence:
        url = (item.get("source_url") or "").strip()
        claim = (item.get("claim") or "").strip()
        if not url or not claim:
            continue

        key = url.rstrip("/").lower()
        if key not in sources_by_key:
            sources_by_key[key] = {
                "id": f"S{len(sources_by_key) + 1}",
                "title": (item.get("source_title") or "").strip() or url,
                "url": url,
                "source_types": [],
            }
        source = sources_by_key[key]

        source_type = item.get("source_type", "web")
        if source_type not in source["source_types"]:
            source["source_types"].append(source_type)

        dedupe_key = (source["id"], " ".join(claim.lower().split()))
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)

        registry.append({
            "id": f"E{len(registry) + 1}",
            "claim": claim,
            "quote": item.get("quote") or "",
            "question": item.get("question") or "",
            "source_id": source["id"],
            "source_type": source_type,
            "source_title": source["title"],
        })

    return registry, list(sources_by_key.values())


def _select_for_synthesis(registry: List[dict], cap: int) -> List[dict]:
    """
    If there is more evidence than fits in the prompt, take it round-robin
    across questions so no single question crowds out the others.
    """
    if len(registry) <= cap:
        return registry

    queues = defaultdict(list)
    for e in registry:
        queues[e["question"]].append(e)
    lists = list(queues.values())

    picked: List[dict] = []
    while len(picked) < cap and any(lists):
        for q in lists:
            if q and len(picked) < cap:
                picked.append(q.pop(0))
    return picked


# ---------------------------------------------------------------------------
# 2-3. Findings
# ---------------------------------------------------------------------------

def synthesize_findings(objective: str, selected: List[dict]) -> List[dict]:
    """
    LLM call. Returns [{"heading", "findings": [{"statement", "evidence_ids"}]}].
    Raises ValueError / LLMError on failure; the caller falls back.
    """
    evidence_block = "\n".join(
        f"[{e['id']}] ({e['source_type']}; source: {e.get('source_title', '')}) {e['claim']}" for e in selected
    )
    parsed = call_llm_json(FINDINGS_SYSTEM_PROMPT, f"Objective: {objective}\n\nEvidence:\n{evidence_block}")

    subsections = parsed.get("subsections")
    if not isinstance(subsections, list):
        raise ValueError("'subsections' missing or not a list")

    cleaned: List[dict] = []
    for sub in subsections[:MAX_SUBSECTIONS]:
        if not isinstance(sub, dict):
            continue
        heading = str(sub.get("heading", "")).strip()
        raw_findings = sub.get("findings")
        if not isinstance(raw_findings, list):
            continue

        findings: List[dict] = []
        for f in raw_findings[:MAX_FINDINGS_PER_SUBSECTION]:
            if not isinstance(f, dict):
                continue
            statement = str(f.get("statement", "")).strip()
            ids = f.get("evidence_ids")
            ids = [str(i).strip() for i in ids if i] if isinstance(ids, list) else []
            if statement:
                findings.append({"statement": statement, "evidence_ids": ids})

        if heading and findings:
            cleaned.append({"heading": heading, "findings": findings})

    if not cleaned:
        raise ValueError("no usable findings in model output")
    return cleaned


def validate_findings(subsections: List[dict], valid_ids: set) -> Tuple[List[dict], int]:
    """
    Enforces "unsupported claims are not presented as researched fact".
    Removes evidence ids that don't exist, and drops any finding left with
    no valid evidence. Returns (cleaned_subsections, number_of_dropped_findings).
    """
    cleaned: List[dict] = []
    dropped = 0
    for sub in subsections:
        kept = []
        for f in sub["findings"]:
            ids = list(dict.fromkeys(i for i in f["evidence_ids"] if i in valid_ids))
            if ids:
                kept.append({"statement": f["statement"], "evidence_ids": ids})
            else:
                dropped += 1
        if kept:
            cleaned.append({"heading": sub["heading"], "findings": kept})
    return cleaned, dropped


def fallback_findings(registry: List[dict]) -> List[dict]:
    """
    Used when LLM synthesis fails or yields nothing valid: one subsection
    per research question, each extracted claim presented as its own
    finding, citing exactly its own evidence id. No synthesis, but
    every statement is still fully traceable.
    """
    by_question: Dict[str, List[dict]] = defaultdict(list)
    for e in registry:
        by_question[e["question"] or "Collected evidence"].append(e)

    subsections = []
    for question, items in list(by_question.items())[:MAX_SUBSECTIONS]:
        subsections.append({
            "heading": question,
            "findings": [
                {"statement": e["claim"], "evidence_ids": [e["id"]]}
                for e in items[:MAX_FINDINGS_PER_SUBSECTION]
            ],
        })
    return subsections


# ---------------------------------------------------------------------------
# 4. Information architecture
# ---------------------------------------------------------------------------

def build_information_architecture(objective: str, subsections: List[dict]) -> List[dict]:
    findings_block = "\n".join(
        f"- {f['statement']}" for sub in subsections for f in sub["findings"]
    )
    parsed = call_llm_json(ARCHITECTURE_SYSTEM_PROMPT, f"Objective: {objective}\n\nFindings:\n{findings_block}")

    groups = parsed.get("groups")
    if not isinstance(groups, list):
        raise ValueError("'groups' missing or not a list")

    cleaned: List[dict] = []
    for g in groups[:MAX_ARCH_GROUPS]:
        if not isinstance(g, dict):
            continue
        name = str(g.get("name", "")).strip()
        description = str(g.get("description", "")).strip()
        raw_items = g.get("items")
        raw_items = raw_items if isinstance(raw_items, list) else []
        items = [str(i).strip() for i in raw_items if str(i).strip()][:MAX_ARCH_ITEMS]
        if name:
            cleaned.append({"name": name, "description": description, "items": items})

    if not cleaned:
        raise ValueError("no usable groups in model output")
    return cleaned


def fallback_architecture(subsections: List[dict]) -> List[dict]:
    return [
        {
            "name": sub["heading"],
            "description": "Findings grouped under this heading.",
            "items": [],
        }
        for sub in subsections[:MAX_ARCH_GROUPS]
    ]


# ---------------------------------------------------------------------------
# 5. Methodology + limitations (deterministic, from recorded state)
# ---------------------------------------------------------------------------

def build_methodology(state: dict, registry: List[dict], unanswered: List[str], extra_limitations: List[str]) -> dict:
    questions = list(state.get("research_questions", []))
    decisions = state.get("source_decisions", {})
    rounds = state.get("research_iteration", 0) + 1

    routed = {s for q in questions for s in decisions.get(q, [])}
    searched = [s for s in SOURCE_ORDER if s in routed]
    with_evidence = [s for s in SOURCE_ORDER if any(e["source_type"] == s for e in registry)]

    # Only categories that actually produced evidence are listed as tools used.
    tools = [TOOL_DESCRIPTIONS[s] for s in with_evidence]
    tools.append(
        f"Local LLM ({OLLAMA_MODEL} via Ollama) for planning, source routing, evidence extraction, "
        "sufficiency evaluation, and report synthesis"
    )

    strategy = (
        f"The objective was broken into {len(questions)} research question(s) across {rounds} research "
        f"round(s). Each question was routed to one or more source categories "
        f"({', '.join(searched) or 'none'}) and researched independently; claims were then extracted from "
        "the search results by an LLM, and each claim's citation was checked against the text of the "
        "cited source."
    )
    if rounds > 1:
        strategy += (
            " After the first round, an evaluation step identified gaps (including questions with no "
            "evidence) and follow-up questions were researched in later rounds."
        )

    limitations = [
        f"Evidence is extracted from search-result excerpts (up to {MAX_CONTENT_CHARS} characters per "
        "result), not from full pages.",
        "Whether a source is about the same technology as the question is judged by an LLM and is not "
        "guaranteed; check the source title shown next to each citation.",
    ]
    if "github" in searched:
        limitations.append(
            "GitHub research covers repository metadata and README excerpts only, not code search or issues."
        )
    if unanswered:
        limitations.append(
            f"{len(unanswered)} research question(s) produced no usable evidence (listed under unanswered questions)."
        )
    no_evidence_from = [s for s in searched if s not in with_evidence]
    if no_evidence_from:
        limitations.append("No usable evidence was obtained from: " + ", ".join(no_evidence_from) + ".")
    warnings = state.get("research_warnings") or []
    if warnings:
        limitations.append(f"{len(warnings)} research action(s) failed or were skipped.")
    if state.get("sufficient") is False:
        limitations.append("Research ended before the evidence was judged fully sufficient (round limit reached, or some "
            "questions could not be answered from any source).")
    limitations.extend(extra_limitations)

    return {
        "objective": state.get("objective", ""),
        "research_questions": questions,
        "source_categories_searched": searched,
        "source_categories_with_evidence": with_evidence,
        "tools_used": tools,
        "search_strategy": strategy,
        "source_selection_approach": (
            "An LLM assigned each research question to web, docs and/or github sources based on the "
            "question's content; any question without a valid assignment defaulted to web search."
        ),
        "research_rounds": rounds,
        "limitations": limitations,
    }


# ---------------------------------------------------------------------------
# 6. Report validation
# ---------------------------------------------------------------------------

def validate_report(report: dict, extra_issues: List[str], dropped_findings: int) -> dict:
    """
    Checks the assembled report. Does NOT raise: a report with issues is
    still returned, with the issues listed, so the user gets the evidence
    and an honest account of what is wrong with the report.
    """
    issues = list(extra_issues)

    for section in ("findings", "information_architecture", "methodology", "sources"):
        if section not in report:
            issues.append(f"Required section missing: {section}")

    if not report.get("findings"):
        issues.append("No findings supported by evidence were produced.")

    evidence_ids = {e["id"] for e in report.get("evidence", [])}
    source_ids = {s["id"] for s in report.get("sources", [])}

    for sub in report.get("findings", []):
        for f in sub["findings"]:
            if not f["evidence_ids"]:
                issues.append(f"Finding has no supporting evidence: {f['statement'][:60]}")
            for i in f["evidence_ids"]:
                if i not in evidence_ids:
                    issues.append(f"Finding cites unknown evidence id {i}")

    for e in report.get("evidence", []):
        if e["source_id"] not in source_ids:
            issues.append(f"Evidence {e['id']} references unknown source {e['source_id']}")

    if not report.get("methodology", {}).get("limitations"):
        issues.append("Limitations section is empty.")

    return {"passed": not issues, "issues": issues, "dropped_findings": dropped_findings}


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

def generate_report(state: dict) -> dict:
    """
    Builds the full report from a completed ResearchState. Designed not to
    raise on LLM trouble: each LLM step has a deterministic fallback, and
    every degradation is recorded in the validation issues and limitations.
    """
    objective = state.get("objective", "")
    questions = list(state.get("research_questions", []))
    registry, sources = build_registry(state.get("evidence", []))

    answered = {e["question"] for e in registry}
    unanswered = [q for q in questions if q not in answered]

    extra_issues: List[str] = []
    extra_limitations: List[str] = []
    dropped = 0
    findings: List[dict] = []
    architecture: List[dict] = []

    if not registry:
        extra_issues.append("No usable evidence was gathered, so no findings could be produced.")
        extra_limitations.append("No usable evidence was gathered for this topic.")
    else:
        selected = _select_for_synthesis(registry, MAX_EVIDENCE_FOR_REPORT)
        if len(selected) < len(registry):
            extra_limitations.append(
                f"Only {len(selected)} of {len(registry)} evidence items were used for synthesis (prompt size limit); "
                "all evidence remains listed below."
            )

        raw_findings: List[dict] = []
        try:
            raw_findings = synthesize_findings(objective, selected)
        except (LLMError, ValueError) as e:
            logger.warning("Findings synthesis failed: %s", e)

        findings, dropped = validate_findings(raw_findings, {e["id"] for e in registry})

        if dropped:
            msg = f"{dropped} synthesized finding(s) were removed because they cited no valid evidence."
            extra_issues.append(msg)
            extra_limitations.append(msg)

        if not findings:
            findings = fallback_findings(registry)
            msg = (
                "LLM findings synthesis failed or produced no valid findings; findings shown are the "
                "extracted evidence claims grouped by question."
            )
            extra_issues.append(msg)
            extra_limitations.append(msg)

        try:
            architecture = build_information_architecture(objective, findings)
        except (LLMError, ValueError) as e:
            logger.warning("Information architecture generation failed: %s", e)
            architecture = fallback_architecture(findings)
            extra_issues.append(
                f"Information architecture generation failed ({str(e)[:120]}); groups shown are the findings headings."
            )

    methodology = build_methodology(state, registry, unanswered, extra_limitations)

    report = {
        "findings": findings,
        "information_architecture": architecture,
        "methodology": methodology,
        "sources": sources,
        "evidence": registry,
        "unanswered_questions": unanswered,
    }
    report["validation"] = validate_report(report, extra_issues, dropped)
    return report
