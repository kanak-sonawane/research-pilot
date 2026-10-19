import logging
import re

from tavily import TavilyClient

from app.config import TAVILY_API_KEY
from app.llm_service import call_llm, LLMError
from app.json_utils import extract_json_object
from app.llm_json import call_llm_json

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

# Hard cap on evidence items kept per extraction call. Fewer, sharper
# claims mean fewer tokens to generate, which is the main cost on a local model.
MAX_EVIDENCE_PER_CALL = 5

EVIDENCE_SYSTEM_PROMPT = """You are a research evidence extraction assistant. Given a research question
and a numbered set of search results, extract discrete, specific evidence statements
that help answer the question.

Rules:
- Only extract claims that are actually supported by the provided content. Never add outside knowledge.
- If the research question names a specific technology, language or library, skip results and claims about a different one, even if they describe a similar concept.
- Each evidence item must cite exactly one source, by its number, from the provided results.
- Each evidence item must include a short "quote": a phrase of at most 15 words copied as
  closely as possible from the cited result's text that supports the claim.
- Never put double-quote characters or backslashes inside the claim or quote text; use single
  quotes instead.
- If none of the results are relevant, return an empty evidence list.
- Prefer precise, atomic claims over one broad summary, and return at most 5 evidence items in
  total (the ones most relevant to the question).
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
        parsed = call_llm_json(EVIDENCE_SYSTEM_PROMPT, user_prompt)
    except LLMError as e:
        raise ResearchError(f"Evidence extraction LLM call failed: {e}") from e
    except ValueError as e:
        raise ResearchError(f"Could not parse evidence output after retry: {e}") from e

    raw_evidence = parsed.get("evidence", [])
    if not isinstance(raw_evidence, list):
        raise ResearchError(f"'evidence' must be a list: {parsed}")
    raw_evidence = raw_evidence[:MAX_EVIDENCE_PER_CALL]

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
