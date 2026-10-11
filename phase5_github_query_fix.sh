#!/usr/bin/env bash
set -e

# Phase 5 fix #2 — reformulate questions into GitHub-friendly keyword
# queries before searching.
# Root cause: GitHub's repository search ANDs every term in the query
# against only name/description/topics — a full natural-language question
# essentially never matches anything. This adds an LLM step that reduces
# the question to a short keyword query first.
# Run this from the root of your research-pilot/ project.

echo "Applying Phase 5 GitHub query fix..."

cat > backend/app/github_research.py << 'EOF'
import requests

from app.config import GITHUB_TOKEN
from app.llm_service import call_llm
from app.web_research import extract_evidence, ResearchError

GITHUB_SEARCH_URL = "https://api.github.com/search/repositories"

README_FETCH_LIMIT = 3
README_CHARS = 2000

GITHUB_QUERY_SYSTEM_PROMPT = """You generate short keyword queries for GitHub's repository search API.

GitHub repository search matches only against repo name, description, and topics,
and requires every term to match (AND logic) — a full natural-language question
will almost never match anything.

Given a research question, output 2-5 short technical keywords or terms most
likely to appear in the name/description/topics of a genuinely relevant
repository (library names, concepts, technology names). Do not include
question words (how, what, which), punctuation, or full sentences.

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
    Reduces a full research question to a short keyword query GitHub's
    repository search can actually match against. Falls back to the
    original question text if the LLM returns something empty/unusable —
    a degraded search is better than a crash.
    """
    try:
        raw = call_llm(GITHUB_QUERY_SYSTEM_PROMPT, question)
    except Exception:
        return question

    cleaned = raw.strip().strip('"').replace("?", "").replace("\n", " ")
    return cleaned if cleaned else question


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
    """
    `query` here is the ORIGINAL research question — reformulation into
    GitHub-friendly keywords happens inside this function, not at the
    call site, so callers (research_question_github) don't need to know
    about this GitHub-specific quirk.
    """
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
echo "Fixed: backend/app/github_research.py now reformulates the research"
echo "question into a short keyword query before hitting GitHub's search API."
echo ""
echo "No new dependencies. Restart the backend to pick up the change, then"
echo "re-run the debug script to confirm results now come back non-empty:"
echo ""
echo "  cd backend && source venv/bin/activate"
echo "  python scripts/debug_github_search.py \"How can custom backoff intervals be configured in requests-based retry implementations?\""
