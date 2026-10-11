#!/usr/bin/env bash
set -e

# Debug helper — inspect what search_github() actually returns, bypassing
# the LLM evidence-extraction step entirely, to isolate whether the empty
# github evidence is a query-relevance issue or a code bug.
# Run this from the root of your research-pilot/ project.

echo "Creating debug script..."

mkdir -p backend/scripts

cat > backend/scripts/debug_github_search.py << 'EOF'
"""
Standalone diagnostic for github_research.search_github().

Usage (from backend/, with venv activated):
    python scripts/debug_github_search.py "your research question here"

Prints each result's title, URL, and how much content was gathered
(description length vs. content length after README enrichment), plus
a snippet of the actual content — so we can see directly whether
GitHub is returning relevant repos with usable content, or not.
"""

import sys

sys.path.insert(0, ".")  # so `app.*` imports resolve when run from backend/

from app.github_research import search_github  # noqa: E402


def main():
    if len(sys.argv) < 2:
        print("Usage: python scripts/debug_github_search.py \"your question\"")
        sys.exit(1)

    query = sys.argv[1]
    print(f"Query: {query!r}\n")

    try:
        results = search_github(query)
    except Exception as e:
        print(f"search_github() raised: {e}")
        sys.exit(1)

    if not results:
        print("No results returned at all — GitHub search itself found nothing.")
        sys.exit(0)

    for i, r in enumerate(results):
        content = r.get("content", "")
        print(f"--- Result {i} ---")
        print(f"Title: {r.get('title')}")
        print(f"URL: {r.get('url')}")
        print(f"Content length: {len(content)} chars")
        print(f"Content preview: {content[:300]!r}")
        print()


if __name__ == "__main__":
    main()
EOF

echo ""
echo "Created backend/scripts/debug_github_search.py"
echo ""
echo "Run it like this:"
echo "  cd backend"
echo "  source venv/bin/activate"
echo "  python scripts/debug_github_search.py \"How can custom backoff intervals be configured in requests-based retry implementations?\""
echo ""
echo "Paste the output back and we'll know exactly what's happening."
