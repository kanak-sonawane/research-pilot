#!/usr/bin/env bash
set -e

# Phase 5 fix #3 — use OR-joined keywords for GitHub search.
# Root cause: even a well-chosen 5-keyword query still requires ALL
# terms to match (GitHub's default AND behavior) against only a repo's
# name/description/topics — too strict for almost any real repo to
# satisfy. Joining keywords with GitHub's explicit OR operator means
# matching just one term is enough, and star-sort surfaces the most
# relevant/popular repos even from a looser match.
# Run this from the root of your research-pilot/ project.

echo "Applying Phase 5 GitHub OR-query fix..."

cat > backend/app/github_research.py << 'EOF'
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

    params = {"q": github_query, "per_page": max_results, "sort": "stars", "order": "desc"}

    try:
        response = requests.get(
            GITHUB_SEARCH_URL, headers=_auth_headers(), params=params, timeout=15
        )
        response.raise_for_status()
    except requests.RequestException as e:
        raise ResearchError(f"GitHub search failed for '{query}': {e}") from e

    items = response.json().get("items", [])

    results = []
    for i, item in enumerate(items):
        full_name = item.get("full_name", "")
        description = item.get("description") or ""

        content = description
        if i < README_FETCH_LIMIT and full_name:
            readme_text = _fetch_readme(full_name)
            if readme_text:
                content = f"{description}\n\n{readme_text}"

        results.append({
            "title": full_name,
            "url": item.get("html_url", ""),
            "content": content,
        })

    return results


def research_question_github(question: str) -> list[dict]:
    results = search_github(question)
    return extract_evidence(question, results, source_type="github")
EOF

echo ""
echo "Fixed: backend/app/github_research.py now joins keywords with OR"
echo "instead of GitHub's default AND, and trims the keyword prompt to"
echo "2-4 core terms only (dropping filler/adjective words)."
echo ""
echo "Restart the backend, then re-run the debug script:"
echo "  python scripts/debug_github_search.py \"How can custom backoff intervals be configured in requests-based retry implementations?\""
