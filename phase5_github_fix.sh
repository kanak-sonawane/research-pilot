#!/usr/bin/env bash
set -e

# Phase 5 fix — enrich GitHub search results with README content
# Root cause: repo `description` alone is too thin for evidence extraction
# to pull specific claims from. This fetches each top result's README and
# includes a chunk of it as real content.
# Run this from the root of your research-pilot/ project.

echo "Applying Phase 5 GitHub research fix..."

cat > backend/app/github_research.py << 'EOF'
import requests

from app.config import GITHUB_TOKEN
from app.web_research import extract_evidence, ResearchError

GITHUB_SEARCH_URL = "https://api.github.com/search/repositories"

# How many of the top search results to fetch READMEs for. Each fetch is
# a separate API call, so this is kept small to control rate-limit usage
# and latency — the top few results are almost always the most relevant
# anyway (results are sorted by stars).
README_FETCH_LIMIT = 3
README_CHARS = 2000


def _auth_headers() -> dict:
    return {
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github+json",
    }


def _fetch_readme(full_name: str) -> str:
    """
    Fetches a repo's README as raw text. Returns "" on any failure
    (missing README, rate limit, etc.) rather than raising — a missing
    README for one repo shouldn't break search results for the others,
    it just means that repo falls back to description-only content.
    """
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
    Searches GitHub repositories, then enriches the top results with
    README content so extract_evidence() has enough substance to pull
    real implementation-detail claims from — a bare repo description is
    usually just a one-line tagline, not enough to answer "how do
    popular projects implement X" style questions.
    """
    if not GITHUB_TOKEN:
        raise ResearchError("GITHUB_TOKEN is not set. Add it to backend/.env.")

    params = {"q": query, "per_page": max_results, "sort": "stars", "order": "desc"}

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
echo "Fixed: backend/app/github_research.py now fetches README content"
echo "for the top 3 search results per question, giving evidence extraction"
echo "real substance to work with instead of just one-line descriptions."
echo ""
echo "No new dependencies. Just restart the backend to pick up the change."
