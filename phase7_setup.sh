#!/usr/bin/env bash
set -e

# Phase 7 — Report Generation, Traceability & Validation
# Run this from the root of your research-pilot/ project.
#
# NOTE: this script fully REWRITES backend/app/graph.py, so the end state is
# well-defined regardless of which earlier Phase 6 fix scripts you applied.
# The rewrite includes the Phase 6 performance fix (thread pool), the Phase 6
# coverage backstop, and the new Phase 7 changes.

echo "Setting up Phase 7 files..."

# ---------------------------------------------------------------------------
# Backend: web_research.py — citation verification + LLMError handling
# ---------------------------------------------------------------------------

cat > backend/app/web_research.py << 'EOF'
import logging
import re

from tavily import TavilyClient

from app.config import TAVILY_API_KEY
from app.llm_service import call_llm, LLMError
from app.json_utils import extract_json_object

logger = logging.getLogger(__name__)

# How much of each search result's text the LLM is shown. Also the text a
# claim is verified against, so "what the model saw" and "what we check
# against" can never drift apart.
MAX_CONTENT_CHARS = 1000

# Minimum fraction of a claim's (or quote's) word tokens that must appear in
# the cited source's text for the citation to be accepted. A verbatim quote
# is held to a higher bar than a paraphrased claim.
QUOTE_SUPPORT_THRESHOLD = 0.75
CLAIM_SUPPORT_THRESHOLD = 0.4

# A different result must beat the cited one by at least this much (in
# support ratio) before a claim is moved to it.
REATTRIBUTION_MARGIN = 0.15

EVIDENCE_SYSTEM_PROMPT = """You are a research evidence extraction assistant. Given a research question
and a numbered set of search results, extract discrete, specific evidence statements
that help answer the question.

Rules:
- Only extract claims that are actually supported by the provided content. Never add outside knowledge.
- Each evidence item must cite exactly one source, by its number, from the provided results.
- Each evidence item must include a short "quote": a phrase of at most 25 words copied as
  closely as possible from the cited result's text that supports the claim.
- If none of the results are relevant, return an empty evidence list.
- Prefer several precise, atomic claims over one broad summary.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"evidence": [{"claim": "...", "source_index": 0, "quote": "..."}, ...]}
"""


class ResearchError(Exception):
    """
    Generic research failure, shared across every source module (web,
    docs, github). One exception type so graph.py's per-question error
    handling doesn't need a growing list of except clauses.
    """


def get_client() -> TavilyClient:
    if not TAVILY_API_KEY:
        raise ResearchError("TAVILY_API_KEY is not set. Add it to backend/.env.")
    return TavilyClient(api_key=TAVILY_API_KEY)


def search_web(query: str, max_results: int = 5) -> list[dict]:
    try:
        client = get_client()
        response = client.search(query=query, max_results=max_results)
        return response.get("results", [])
    except ResearchError:
        raise
    except Exception as e:
        raise ResearchError(f"Tavily search failed for '{query}': {e}") from e


_TOKEN_RE = re.compile(r"[a-z0-9]+")


def _tokens(text: str) -> set:
    """
    Lowercased alphanumeric word tokens, length >= 3, with a crude plural
    strip (trailing 's') so "macros"/"macro" and "delays"/"delay" match.
    Used only for the citation-support check below.
    """
    tokens = set()
    for token in _TOKEN_RE.findall(text.lower()):
        if len(token) < 3:
            continue
        if len(token) > 3 and token.endswith("s"):
            token = token[:-1]
        tokens.add(token)
    return tokens


def _resolve_source(support_text: str, cited_idx: int, source_tokens: list, threshold: float):
    """
    Decides which result a claim really belongs to.
    - If the cited result supports the claim well enough, keep it.
    - Otherwise look for another result that does, and re-attribute to it.
      (The extraction LLM sometimes picks the wrong source_index for a
      correct claim.)
    - If no result supports it, return None and the claim is dropped.
    """
    support = _tokens(support_text)
    if not support:
        return cited_idx  # nothing checkable; keep as cited

    def ratio(i: int) -> float:
        return len(support & source_tokens[i]) / len(support)

    cited_ratio = ratio(cited_idx)
    best = max(range(len(source_tokens)), key=ratio)
    best_ratio = ratio(best)

    # Another result that fits clearly better wins, even if the cited one
    # also clears the threshold: generic words ("exponential", "backoff")
    # can make a wrong source look acceptable on its own.
    if best != cited_idx and best_ratio >= threshold and best_ratio - cited_ratio >= REATTRIBUTION_MARGIN:
        return best
    if cited_ratio >= threshold:
        return cited_idx
    return None


def extract_evidence(question: str, results: list[dict], source_type: str = "web") -> list[dict]:
    """
    Turns raw search results into structured evidence tied to `question`.
    `source_type` is stamped onto each item as-is; this function doesn't
    care which source produced the results, only that they use the common
    {"title", "url", "content"} shape.

    Phase 7 addition: every claim's citation is VERIFIED in code against
    the text of the cited result (and re-attributed or dropped if it
    doesn't hold up) instead of trusting the LLM's source_index.
    """
    if not results:
        return []

    numbered = "\n\n".join(
        f"[{i}] Title: {r.get('title', '')}\n"
        f"URL: {r.get('url', '')}\n"
        f"Content: {(r.get('content') or '')[:MAX_CONTENT_CHARS]}"
        for i, r in enumerate(results)
    )
    user_prompt = f"Research question: {question}\n\nSearch results:\n{numbered}"

    try:
        raw = call_llm(EVIDENCE_SYSTEM_PROMPT, user_prompt)
    except LLMError as e:
        raise ResearchError(f"Evidence extraction LLM call failed: {e}") from e

    try:
        parsed = extract_json_object(raw)
    except ValueError as e:
        raise ResearchError(f"Could not parse evidence output: {e}") from e

    raw_evidence = parsed.get("evidence", [])
    if not isinstance(raw_evidence, list):
        raise ResearchError(f"'evidence' must be a list: {parsed}")

    source_tokens = [
        _tokens(f"{r.get('title', '')} {(r.get('content') or '')[:MAX_CONTENT_CHARS]}")
        for r in results
    ]

    evidence_items = []
    dropped = 0
    for item in raw_evidence:
        if not isinstance(item, dict):
            continue

        claim = item.get("claim")
        idx = item.get("source_index")
        if (
            not isinstance(claim, str)
            or not claim.strip()
            or not isinstance(idx, int)
            or not (0 <= idx < len(results))
        ):
            continue

        claim = claim.strip()
        quote = item.get("quote")
        quote = quote.strip() if isinstance(quote, str) else ""

        support_text = quote or claim
        threshold = QUOTE_SUPPORT_THRESHOLD if quote else CLAIM_SUPPORT_THRESHOLD

        final_idx = _resolve_source(support_text, idx, source_tokens, threshold)
        if final_idx is None:
            dropped += 1
            continue

        source = results[final_idx]
        evidence_items.append({
            "question": question,
            "source_type": source_type,
            "source_title": source.get("title", ""),
            "source_url": source.get("url", ""),
            "claim": claim,
            "quote": quote,
        })

    if dropped:
        logger.warning(
            "Dropped %d evidence item(s) for question %r: claim not supported by any result's text",
            dropped,
            question,
        )

    return evidence_items


def research_question_web(question: str) -> list[dict]:
    results = search_web(question)
    return extract_evidence(question, results, source_type="web")
EOF

# ---------------------------------------------------------------------------
# Backend: state.py — add report
# ---------------------------------------------------------------------------

cat > backend/app/state.py << 'EOF'
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

    # ALL research questions ever asked, across every round. Grows, never
    # overwritten. Shown to the user as "the plan".
    research_questions: List[str]

    # Only the CURRENT round's questions. Replaced each round.
    active_questions: List[str]

    # Accumulates across rounds (merged dict).
    source_decisions: Dict[str, List[str]]

    # Accumulated across all research nodes and rounds. Each item:
    # {"question", "source_type", "source_title", "source_url", "claim", "quote"}
    evidence: List[dict]
    research_warnings: List[str]

    # Latest evaluate_sufficiency_node judgment.
    sufficient: bool
    gap_questions: List[str]

    # Absent == 0. Incremented by prepare_next_round_node.
    research_iteration: int

    # Set by generate_report_node (Phase 7): the final structured report.
    report: dict

    error: Optional[str]
EOF

# ---------------------------------------------------------------------------
# Backend: report.py — report generation, traceability, validation
# ---------------------------------------------------------------------------

cat > backend/app/report.py << 'EOF'
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
from app.llm_service import call_llm, LLMError
from app.web_research import MAX_CONTENT_CHARS

logger = logging.getLogger(__name__)

# Hard caps enforced in code — never trust a count instruction in a prompt.
MAX_EVIDENCE_FOR_REPORT = 50
MAX_SUBSECTIONS = 6
MAX_FINDINGS_PER_SUBSECTION = 8
MAX_ARCH_GROUPS = 6
MAX_ARCH_ITEMS = 6

SOURCE_ORDER = ("web", "docs", "github")

TOOL_DESCRIPTIONS = {
    "web": "Tavily web search",
    "docs": "Tavily web search scoped to official documentation (queries suffixed with 'official documentation')",
    "github": "GitHub repository search (LLM-generated keyword query, README retrieval for top results)",
}

FINDINGS_SYSTEM_PROMPT = """You are a research report writer. You are given a research objective and a
numbered list of evidence items. Each item is a factual claim extracted from a real source.
Write the Findings section of a technical research report.

Rules:
- Use ONLY the provided evidence. Never add outside knowledge.
- Group findings into 2 to 5 subsections with clear, topic-appropriate headings.
- Each finding is one or two sentences synthesizing one or more evidence items, and MUST list
  the ids of the evidence it relies on, exactly as written (for example "E1").
- Never write a finding that has no supporting evidence ids.
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
        f"[{e['id']}] ({e['source_type']}) {e['claim']}" for e in selected
    )
    raw = call_llm(FINDINGS_SYSTEM_PROMPT, f"Objective: {objective}\n\nEvidence:\n{evidence_block}")
    parsed = extract_json_object(raw)

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
    raw = call_llm(ARCHITECTURE_SYSTEM_PROMPT, f"Objective: {objective}\n\nFindings:\n{findings_block}")
    parsed = extract_json_object(raw)

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

    tools = [TOOL_DESCRIPTIONS[s] for s in searched]
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
        "result), not from full pages."
    ]
    if "github" in searched:
        limitations.append(
            "GitHub research covers repository metadata and README excerpts only, not code search or issues."
        )
    if unanswered:
        limitations.append(
            f"{len(unanswered)} research question(s) produced no usable evidence (listed under unanswered questions)."
        )
    warnings = state.get("research_warnings") or []
    if warnings:
        limitations.append(f"{len(warnings)} research action(s) failed or were skipped.")
    if state.get("sufficient") is False:
        limitations.append("Research stopped at the round limit before the evidence was judged sufficient.")
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
                "Information architecture generation failed; groups shown are the findings headings."
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
EOF

# ---------------------------------------------------------------------------
# Backend: graph.py — full rewrite (Phase 6 fixes + Phase 7 report node)
# ---------------------------------------------------------------------------

cat > backend/app/graph.py << 'EOF'
import concurrent.futures

from langgraph.graph import StateGraph, END

from app.state import ResearchState
from app.llm_service import LLMError
from app.planning import generate_plan, PlanningError
from app.source_decision import decide_sources, SourceDecisionError
from app.web_research import research_question_web, ResearchError
from app.docs_research import research_question_docs
from app.github_research import research_question_github
from app.evaluation import evaluate_sufficiency, EvaluationError
from app.report import generate_report

# Hard cap on extra research rounds beyond the first (bounded-loop guarantee).
MAX_RESEARCH_ROUNDS = 2

# How many questions' research runs concurrently per source-type node.
MAX_WORKERS = 3


def plan_node(state: ResearchState) -> dict:
    """Entry node. Sets research_questions (history) and active_questions (this round)."""
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
    """Routes THIS round's questions and merges into the accumulated source_decisions."""
    if state.get("error"):
        return {}
    try:
        new_decisions = decide_sources(state["active_questions"])
        merged = dict(state.get("source_decisions", {}))
        merged.update(new_decisions)
        return {"source_decisions": merged}
    except (SourceDecisionError, LLMError) as e:
        return {"error": f"Source decision failed: {e}"}


def _build_research_node(source_type: str, research_fn):
    """
    Researches the active questions routed to `source_type`, concurrently.
    Each question's research is independent, so they run in a thread pool.
    Worker threads only call research_fn; results are merged into the
    evidence/warnings lists in the main thread after each future completes,
    so no shared state is mutated concurrently.
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
    LLM sufficiency judgment, followed by a deterministic zero-evidence
    backstop: any question with no evidence forces another round (if the
    cap allows), regardless of the LLM's judgment. Fails safe if the
    evaluator itself breaks.
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
    except (EvaluationError, LLMError) as e:
        warnings = list(state.get("research_warnings", []))
        warnings.append(f"Sufficiency evaluation failed, stopping with current evidence: {e}")
        return {"sufficient": True, "gap_questions": [], "research_warnings": warnings}

    answered_questions = {e.get("question") for e in state.get("evidence", [])}
    unanswered = [
        q for q in state.get("research_questions", []) if q not in answered_questions
    ]

    if unanswered and state.get("research_iteration", 0) < MAX_RESEARCH_ROUNDS:
        merged_gaps = list(dict.fromkeys(unanswered + gap_questions))[:3]
        return {"sufficient": False, "gap_questions": merged_gaps}

    return {"sufficient": sufficient, "gap_questions": gap_questions}


def prepare_next_round_node(state: ResearchState) -> dict:
    """
    Promotes gap_questions to active_questions for the next round and
    appends only genuinely NEW questions to the history (a re-asked
    unanswered question must not appear twice in the plan).
    """
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
    """Conditional edge: 'loop' for another round, 'end' to proceed to the report."""
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
    """
    Final stage. generate_report() has deterministic fallbacks for its LLM
    steps, so it normally doesn't raise; the broad except is a last-resort
    guard so an unexpected report bug never discards the gathered evidence.
    """
    if state.get("error"):
        return {}
    try:
        return {"report": generate_report(dict(state))}
    except Exception as e:  # noqa: BLE001 — deliberate last-resort guard
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

    graph.add_node("plan", plan_node)
    graph.add_node("decide_sources", decide_sources_node)
    graph.add_node("research_web", research_web_node)
    graph.add_node("research_docs", research_docs_node)
    graph.add_node("research_github", research_github_node)
    graph.add_node("evaluate_sufficiency", evaluate_sufficiency_node)
    graph.add_node("prepare_next_round", prepare_next_round_node)
    graph.add_node("generate_report", generate_report_node)

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
# Backend: schemas.py — report models
# ---------------------------------------------------------------------------

cat > backend/app/schemas.py << 'EOF'
from typing import Dict, List, Optional

from pydantic import BaseModel, field_validator


class ResearchRequest(BaseModel):
    query: str

    @field_validator("query")
    @classmethod
    def query_must_not_be_blank(cls, v: str) -> str:
        normalized = v.strip()
        if not normalized:
            raise ValueError("Research query cannot be empty.")
        return normalized


class Plan(BaseModel):
    objective: str
    research_questions: List[str]


class EvidenceItem(BaseModel):
    question: str
    source_type: str
    source_title: str
    source_url: str
    claim: str
    quote: str = ""


# ---- Report (Phase 7) ----------------------------------------------------

class ReportFinding(BaseModel):
    statement: str
    evidence_ids: List[str]


class FindingsSubsection(BaseModel):
    heading: str
    findings: List[ReportFinding]


class ArchitectureGroup(BaseModel):
    name: str
    description: str = ""
    items: List[str] = []


class ReportEvidence(BaseModel):
    id: str
    claim: str
    quote: str = ""
    question: str
    source_id: str
    source_type: str


class ReportSource(BaseModel):
    id: str
    title: str
    url: str
    source_types: List[str]


class Methodology(BaseModel):
    objective: str
    research_questions: List[str]
    source_categories_searched: List[str]
    source_categories_with_evidence: List[str]
    tools_used: List[str]
    search_strategy: str
    source_selection_approach: str
    research_rounds: int
    limitations: List[str]


class ValidationResult(BaseModel):
    passed: bool
    issues: List[str]
    dropped_findings: int


class Report(BaseModel):
    findings: List[FindingsSubsection]
    information_architecture: List[ArchitectureGroup]
    methodology: Methodology
    sources: List[ReportSource]
    evidence: List[ReportEvidence]
    unanswered_questions: List[str]
    validation: ValidationResult


class ResearchRunResponse(BaseModel):
    run_id: str
    status: str
    query: str
    message: str
    plan: Optional[Plan] = None
    source_decisions: Optional[Dict[str, List[str]]] = None
    evidence: Optional[List[EvidenceItem]] = None
    warnings: Optional[List[str]] = None
    sufficient: Optional[bool] = None
    research_rounds: Optional[int] = None
    report: Optional[Report] = None
EOF

# ---------------------------------------------------------------------------
# Backend: routes.py — surface the report
# ---------------------------------------------------------------------------

cat > backend/app/routes.py << 'EOF'
import uuid

from fastapi import APIRouter

from app.schemas import ResearchRequest, ResearchRunResponse, Plan
from app.graph import research_graph

router = APIRouter()


@router.post("/research", response_model=ResearchRunResponse)
def start_research(payload: ResearchRequest):
    run_id = str(uuid.uuid4())

    final_state = research_graph.invoke({
        "run_id": run_id,
        "query": payload.query,
    })

    if final_state.get("error"):
        return ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=payload.query,
            message=final_state["error"],
        )

    return ResearchRunResponse(
        run_id=run_id,
        status="research_complete",
        query=payload.query,
        message="Research complete. Report generated from the gathered evidence.",
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
        evidence=final_state.get("evidence", []),
        warnings=final_state.get("research_warnings"),
        sufficient=final_state.get("sufficient"),
        research_rounds=final_state.get("research_iteration", 0) + 1,
        report=final_state.get("report"),
    )
EOF

# ---------------------------------------------------------------------------
# Frontend: ReportView.tsx (plain report rendering; Phase 8 polishes this)
# ---------------------------------------------------------------------------

cat > frontend/src/components/ReportView.tsx << 'EOF'
"use client";

export interface ReportFinding {
  statement: string;
  evidence_ids: string[];
}
export interface FindingsSubsection {
  heading: string;
  findings: ReportFinding[];
}
export interface ArchitectureGroup {
  name: string;
  description: string;
  items: string[];
}
export interface ReportEvidence {
  id: string;
  claim: string;
  quote: string;
  question: string;
  source_id: string;
  source_type: string;
}
export interface ReportSource {
  id: string;
  title: string;
  url: string;
  source_types: string[];
}
export interface Methodology {
  objective: string;
  research_questions: string[];
  source_categories_searched: string[];
  source_categories_with_evidence: string[];
  tools_used: string[];
  search_strategy: string;
  source_selection_approach: string;
  research_rounds: number;
  limitations: string[];
}
export interface ValidationResult {
  passed: boolean;
  issues: string[];
  dropped_findings: number;
}
export interface Report {
  findings: FindingsSubsection[];
  information_architecture: ArchitectureGroup[];
  methodology: Methodology;
  sources: ReportSource[];
  evidence: ReportEvidence[];
  unanswered_questions: string[];
  validation: ValidationResult;
}

export default function ReportView({ report }: { report: Report }) {
  const evidenceById = new Map(report.evidence.map((e) => [e.id, e]));
  const sourceById = new Map(report.sources.map((s) => [s.id, s]));

  return (
    <article className="flex flex-col gap-6">
      {report.validation.passed ? (
        <p className="text-green-800 bg-green-50 border border-green-200 rounded p-2">
          Report validation passed: every finding cites stored evidence, and every citation maps to a source.
        </p>
      ) : (
        <div className="text-amber-800 bg-amber-50 border border-amber-200 rounded p-2">
          <strong>Report validation notes</strong>
          <ul className="list-disc list-inside mt-1">
            {report.validation.issues.map((issue, i) => (
              <li key={i}>{issue}</li>
            ))}
          </ul>
        </div>
      )}

      <section>
        <h2 className="text-lg font-semibold mb-2">1. Findings</h2>
        {report.findings.length === 0 ? (
          <p className="text-gray-600">No findings supported by evidence were produced.</p>
        ) : (
          report.findings.map((sub, i) => (
            <div key={i} className="mb-4">
              <h3 className="font-semibold mb-1">{sub.heading}</h3>
              <ul className="flex flex-col gap-2">
                {sub.findings.map((f, j) => {
                  const sourceIds = Array.from(
                    new Set(
                      f.evidence_ids
                        .map((id) => evidenceById.get(id)?.source_id)
                        .filter((x): x is string => Boolean(x))
                    )
                  );
                  return (
                    <li key={j} className="list-disc ml-5">
                      {f.statement}{" "}
                      {sourceIds.map((sid) => (
                        <a key={sid} href={`#source-${sid}`} className="text-blue-600 underline mr-1">
                          [{sid}]
                        </a>
                      ))}
                      <details className="text-gray-700">
                        <summary className="cursor-pointer text-xs">
                          Evidence ({f.evidence_ids.length})
                        </summary>
                        <ul className="mt-1 ml-4 list-disc">
                          {f.evidence_ids.map((id) => {
                            const ev = evidenceById.get(id);
                            if (!ev) return null;
                            const src = sourceById.get(ev.source_id);
                            return (
                              <li key={id} className="text-xs">
                                <strong>{id}</strong> ({ev.source_type}): {ev.claim}{" "}
                                {src && (
                                  <a
                                    href={src.url}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="text-blue-600 underline"
                                  >
                                    [{src.title}]
                                  </a>
                                )}
                                {ev.quote && <div className="italic text-gray-500">&ldquo;{ev.quote}&rdquo;</div>}
                              </li>
                            );
                          })}
                        </ul>
                      </details>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))
        )}
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-2">2. Information Architecture</h2>
        {report.information_architecture.length === 0 ? (
          <p className="text-gray-600">Not available.</p>
        ) : (
          <ul className="flex flex-col gap-3">
            {report.information_architecture.map((g, i) => (
              <li key={i}>
                <strong>{g.name}</strong>
                {g.description && <span>: {g.description}</span>}
                {g.items.length > 0 && (
                  <ul className="list-disc ml-6 mt-1">
                    {g.items.map((item, j) => (
                      <li key={j}>{item}</li>
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-2">3. Research Methodology / Approach</h2>
        <div className="flex flex-col gap-2">
          <p><strong>Objective:</strong> {report.methodology.objective}</p>
          <p><strong>Strategy:</strong> {report.methodology.search_strategy}</p>
          <p><strong>Source selection:</strong> {report.methodology.source_selection_approach}</p>
          <p>
            <strong>Source categories searched:</strong>{" "}
            {report.methodology.source_categories_searched.join(", ") || "none"}
            {" | "}
            <strong>with evidence:</strong>{" "}
            {report.methodology.source_categories_with_evidence.join(", ") || "none"}
          </p>
          <div>
            <strong>Tools used</strong>
            <ul className="list-disc ml-6">
              {report.methodology.tools_used.map((t, i) => (
                <li key={i}>{t}</li>
              ))}
            </ul>
          </div>
          <div>
            <strong>Limitations</strong>
            <ul className="list-disc ml-6">
              {report.methodology.limitations.map((l, i) => (
                <li key={i}>{l}</li>
              ))}
            </ul>
          </div>
          {report.unanswered_questions.length > 0 && (
            <div>
              <strong>Unanswered questions</strong>
              <ul className="list-disc ml-6">
                {report.unanswered_questions.map((q, i) => (
                  <li key={i}>{q}</li>
                ))}
              </ul>
            </div>
          )}
        </div>
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-2">4. Sources &amp; Citations</h2>
        {report.sources.length === 0 ? (
          <p className="text-gray-600">No sources.</p>
        ) : (
          <ol className="flex flex-col gap-1">
            {report.sources.map((s) => (
              <li key={s.id} id={`source-${s.id}`}>
                <strong>[{s.id}]</strong>{" "}
                <a href={s.url} target="_blank" rel="noopener noreferrer" className="text-blue-600 underline">
                  {s.title}
                </a>{" "}
                <span className="text-gray-500 text-xs uppercase">{s.source_types.join(", ")}</span>
              </li>
            ))}
          </ol>
        )}
      </section>
    </article>
  );
}
EOF

# ---------------------------------------------------------------------------
# Frontend: ResearchForm.tsx — full rewrite, now renders the report
# ---------------------------------------------------------------------------

cat > frontend/src/components/ResearchForm.tsx << 'EOF'
"use client";

import { useState } from "react";
import ReportView, { type Report } from "@/components/ReportView";

type RunStatus = "idle" | "loading" | "success" | "error";

interface Plan {
  objective: string;
  research_questions: string[];
}

interface EvidenceItem {
  question: string;
  source_type: string;
  source_title: string;
  source_url: string;
  claim: string;
  quote?: string;
}

interface ResearchRunResponse {
  run_id: string;
  status: string;
  query: string;
  message: string;
  plan: Plan | null;
  source_decisions: Record<string, string[]> | null;
  evidence: EvidenceItem[] | null;
  warnings: string[] | null;
  sufficient: boolean | null;
  research_rounds: number | null;
  report: Report | null;
}

const API_BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:8000";

export default function ResearchForm() {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<RunStatus>("idle");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [result, setResult] = useState<ResearchRunResponse | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!query.trim()) {
      setStatus("error");
      setErrorMessage("Please enter a research topic before submitting.");
      return;
    }

    setStatus("loading");
    setErrorMessage("");
    setResult(null);

    try {
      const res = await fetch(`${API_BASE_URL}/research`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query }),
      });

      if (!res.ok) {
        const errBody = await res.json().catch(() => null);
        throw new Error(
          errBody?.detail?.[0]?.msg || "The research request could not be submitted."
        );
      }

      const data: ResearchRunResponse = await res.json();
      setResult(data);
      setStatus("success");
    } catch (err) {
      setStatus("error");
      setErrorMessage(
        err instanceof Error ? err.message : "Something went wrong. Please try again."
      );
    }
  };

  const evidenceForQuestion = (question: string) =>
    result?.evidence?.filter((e) => e.question === question) ?? [];

  return (
    <div className="w-full max-w-3xl flex flex-col gap-4">
      <form onSubmit={handleSubmit} className="flex flex-col gap-3">
        <label htmlFor="research-query" className="font-medium text-gray-900">
          Technical research topic
        </label>
        <input
          id="research-query"
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="e.g. How does LangGraph handle cyclic workflows?"
          className="border rounded px-3 py-2 text-gray-900 placeholder:text-gray-400 bg-white"
          // Keeps the native input on light styling regardless of OS dark mode.
          style={{ colorScheme: "light" }}
          disabled={status === "loading"}
        />
        <button
          type="submit"
          disabled={status === "loading"}
          className="rounded bg-black px-4 py-2 text-white disabled:opacity-50"
        >
          {status === "loading" ? "Researching..." : "Start Research"}
        </button>
      </form>

      {status === "error" && (
        <p className="text-red-600 text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      {status === "success" && result && (
        <div className="text-sm border rounded p-4 bg-gray-50 text-gray-900 flex flex-col gap-4">
          <p><strong>Status:</strong> {result.status}</p>
          <p><strong>Run ID:</strong> {result.run_id}</p>
          {result.research_rounds !== null && (
            <p>
              <strong>Research rounds:</strong> {result.research_rounds}
              {result.sufficient !== null && (
                <span className="text-gray-500">
                  {" "}({result.sufficient ? "evidence judged sufficient" : "stopped at round cap"})
                </span>
              )}
            </p>
          )}

          {result.warnings && result.warnings.length > 0 && (
            <div className="text-amber-700 bg-amber-50 border border-amber-200 rounded p-2">
              <strong>Warnings:</strong>
              <ul className="list-disc list-inside mt-1">
                {result.warnings.map((w, i) => <li key={i}>{w}</li>)}
              </ul>
            </div>
          )}

          {result.status === "failed" && (
            <p className="text-red-600">{result.message}</p>
          )}

          {result.report && <ReportView report={result.report} />}

          {result.plan && (
            <details>
              <summary className="cursor-pointer font-semibold">
                Raw evidence by research question
              </summary>
              <div className="flex flex-col gap-3 mt-2">
                <p><strong>Objective:</strong> {result.plan.objective}</p>
                {result.plan.research_questions.map((q, i) => (
                  <div key={i} className="border-l-2 border-gray-300 pl-3">
                    <p className="font-medium">
                      {q}
                      {result.source_decisions?.[q] && (
                        <span className="text-gray-500 font-normal">
                          {" "}[{result.source_decisions[q].join(", ")}]
                        </span>
                      )}
                    </p>
                    {evidenceForQuestion(q).length > 0 ? (
                      <ul className="list-disc list-inside mt-1 flex flex-col gap-1">
                        {evidenceForQuestion(q).map((ev, j) => (
                          <li key={j}>
                            <span className="text-gray-400 uppercase text-xs mr-1">
                              {ev.source_type}
                            </span>
                            {ev.claim}{" "}
                            <a
                              href={ev.source_url}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="text-blue-600 underline"
                            >
                              [{ev.source_title || "source"}]
                            </a>
                          </li>
                        ))}
                      </ul>
                    ) : (
                      <p className="text-gray-500 mt-1">No evidence gathered.</p>
                    )}
                  </div>
                ))}
              </div>
            </details>
          )}
        </div>
      )}
    </div>
  );
}
EOF

echo ""
echo "Phase 7 files created/updated:"
echo "  backend/app/web_research.py   (citation verification, LLMError handling, quote field)"
echo "  backend/app/state.py          (added report)"
echo "  backend/app/report.py         (new: report generation, traceability, validation)"
echo "  backend/app/graph.py          (rewritten: generate_report node, LLMError handling, de-duplicated next-round questions)"
echo "  backend/app/schemas.py        (report models, quote on EvidenceItem)"
echo "  backend/app/routes.py         (returns the report)"
echo "  frontend/src/components/ReportView.tsx   (new)"
echo "  frontend/src/components/ResearchForm.tsx (rewritten: renders the report, raw evidence collapsed)"
echo ""
echo "No new dependencies, no .env changes. Restart the backend and frontend."
