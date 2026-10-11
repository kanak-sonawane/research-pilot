import concurrent.futures

import requests

from app.config import GITHUB_TOKEN
from app.llm_service import call_llm
from app.web_research import extract_evidence, ResearchError

GITHUB_SEARCH_URL = "https://api.github.com/search/repositories"

README_FETCH_LIMIT = 3
README_CHARS = 2000

GITHUB_QUERY_SYSTEM_PROMPT = """You generate short keyword queries for GitHub's repository search API.

GitHub repository search matches only against repo name, description, and topics.
Given a research question, output 2-4 short technical keywords or terms most
likely to appear in the name/description/topics of a genuinely relevant
repository (library names, concepts, technology names). Do not include
question words (how, what, which), filler/adjective words (custom, popular),
punctuation, or full sentences.

Respond with ONLY the keywords, space-separated, nothing else. No quotes,
no explanation, no markdown.
"""


def _auth_headers() -> dict:
    return {
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
    }


def _build_github_query(question: str) -> str:
    """
    Reduces a full research question to a small set of keywords, then
    joins them with GitHub's explicit OR operator rather than relying on
    default AND behavior between space-separated terms. Requiring every
    keyword to match the same repo's short metadata fields is too
    strict — OR means matching just one keyword is enough, and results
    are still sorted by stars, so the most relevant/popular repos
    naturally surface even from a broader match.

    Falls back to the original question text if the LLM call fails —
    a degraded search is better than a crash.
    """
    try:
        raw = call_llm(GITHUB_QUERY_SYSTEM_PROMPT, question)
    except Exception:
        return question

    cleaned = raw.strip().strip('"').replace("?", "").replace("\n", " ")
    keywords = [k for k in cleaned.split() if k]

    if not keywords:
        return question

    # Hard cap regardless of what the LLM actually returned. GitHub's
    # search API rejects (422 Unprocessable Entity) any query with more
    # than 5 AND/OR/NOT operators — 4 keywords joined with OR is 3
    # operators, safely under that limit even if the LLM ignores the
    # "2-4 keywords" instruction in the prompt.
    keywords = keywords[:4]

    return " OR ".join(keywords)


def _fetch_readme(full_name: str) -> str:
    url = f"https://api.github.com/repos/{full_name}/readme"
    headers = {**_auth_headers(), "Accept": "application/vnd.github.raw"}
    try:
        response = requests.get(url, headers=headers, timeout=15)
        if response.status_code == 200:
            return response.text[:README_CHARS]
    except requests.RequestException:
        pass
    return ""


def search_github(query: str, max_results: int = 5) -> list[dict]:
    if not GITHUB_TOKEN:
        raise ResearchError("GITHUB_TOKEN is not set. Add it to backend/.env.")

    github_query = _build_github_query(query)

    # No "sort" param: GitHub's default is best-match relevance ranking,
    # which weighs how well the query terms actually match. Explicitly
    # sorting by stars instead would surface huge generic repos that
    # merely contain a keyword somewhere, ahead of small but genuinely
    # relevant ones — exactly the problem this fix addresses.
    params = {"q": github_query, "per_page": max_results}

    try:
        response = requests.get(
            GITHUB_SEARCH_URL, headers=_auth_headers(), params=params, timeout=15
        )
        response.raise_for_status()
    except requests.RequestException as e:
        raise ResearchError(f"GitHub search failed for '{query}': {e}") from e

    items = response.json().get("items", [])

    # README fetches for the top results are independent of each other
    # (different repos, separate API calls) — fetched concurrently
    # instead of one at a time, same reasoning as the per-question
    # parallelism in graph.py.
    to_enrich = [item.get("full_name", "") for item in items[:README_FETCH_LIMIT] if item.get("full_name")]
    readme_by_name: dict[str, str] = {}
    if to_enrich:
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(to_enrich)) as executor:
            future_to_name = {executor.submit(_fetch_readme, name): name for name in to_enrich}
            for future in concurrent.futures.as_completed(future_to_name):
                readme_by_name[future_to_name[future]] = future.result()

    results = []
    for item in items:
        full_name = item.get("full_name", "")
        description = item.get("description") or ""
        readme_text = readme_by_name.get(full_name, "")
        content = f"{description}\n\n{readme_text}" if readme_text else description

        results.append({
            "title": full_name,
            "url": item.get("html_url", ""),
            "content": content,
        })

    return results


def research_question_github(question: str) -> list[dict]:
    results = search_github(question)
    return extract_evidence(question, results, source_type="github")
