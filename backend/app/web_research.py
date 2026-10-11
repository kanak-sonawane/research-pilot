import json

from tavily import TavilyClient

from app.config import TAVILY_API_KEY
from app.llm_service import call_llm
from app.json_utils import extract_json_object

EVIDENCE_SYSTEM_PROMPT = """You are a research evidence extraction assistant. Given a research question
and a numbered set of search results, extract discrete, specific evidence statements
that help answer the question.

Rules:
- Only extract claims that are actually supported by the provided content. Never add outside knowledge.
- Each evidence item must cite exactly one source, by its number, from the provided results.
- If none of the results are relevant, return an empty evidence list.
- Prefer several precise, atomic claims over one broad summary.
- Respond with ONLY valid JSON, no markdown formatting, no commentary, in this exact shape:
{"evidence": [{"claim": "...", "source_index": 0}, ...]}
"""


class ResearchError(Exception):
    """
    Generic research failure, shared across every source module (web,
    docs, github). Kept as one exception type rather than one per module
    so graph.py's per-question error handling in research nodes doesn't
    need a growing list of except clauses as more source types are added.
    """


def get_client() -> TavilyClient:
    """
    Public (not underscore-prefixed) because docs_research.py reuses this
    same Tavily client rather than constructing its own — docs discovery
    in this project is implemented as a scoped Tavily search, not a
    separate API integration, so sharing the client avoids a redundant
    second connection/config path.
    """
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


def extract_evidence(question: str, results: list[dict], source_type: str = "web") -> list[dict]:
    """
    Turns raw search results into structured evidence tied to `question`.
    `source_type` is stamped onto each evidence item as-is — this function
    doesn't care whether results came from Tavily's general web search,
    a docs-scoped search, or GitHub's API; it only needs the common
    {"title", "url", "content"} shape, which every source module
    normalizes its results into before calling this.
    """
    if not results:
        return []

    numbered = "\n\n".join(
        f"[{i}] Title: {r.get('title', '')}\n"
        f"URL: {r.get('url', '')}\n"
        f"Content: {(r.get('content') or '')[:1000]}"
        for i, r in enumerate(results)
    )
    user_prompt = f"Research question: {question}\n\nSearch results:\n{numbered}"

    raw = call_llm(EVIDENCE_SYSTEM_PROMPT, user_prompt)

    try:
        parsed = extract_json_object(raw)
    except (ValueError, json.JSONDecodeError) as e:
        raise ResearchError(f"Could not parse evidence output: {e}") from e

    raw_evidence = parsed.get("evidence", [])
    if not isinstance(raw_evidence, list):
        raise ResearchError(f"'evidence' must be a list: {parsed}")

    evidence_items = []
    for item in raw_evidence:
        claim = item.get("claim")
        idx = item.get("source_index")

        if claim is None or not isinstance(idx, int) or not (0 <= idx < len(results)):
            continue

        source = results[idx]
        evidence_items.append({
            "question": question,
            "source_type": source_type,
            "source_title": source.get("title", ""),
            "source_url": source.get("url", ""),
            "claim": claim,
        })

    return evidence_items


def research_question_web(question: str) -> list[dict]:
    results = search_web(question)
    return extract_evidence(question, results, source_type="web")
