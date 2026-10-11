#!/usr/bin/env bash
set -e

# Updates the debug script to also print the reformulated keyword query,
# so it's obvious at a glance whether _build_github_query() is running.
# Run this from the root of your research-pilot/ project.

echo "Updating debug script..."

cat > backend/scripts/debug_github_search.py << 'EOF'
"""
Standalone diagnostic for github_research.search_github().

Usage (from backend/, with venv activated):
    python scripts/debug_github_search.py "your research question here"
"""

import sys

sys.path.insert(0, ".")

from app.github_research import search_github, _build_github_query  # noqa: E402


def main():
    if len(sys.argv) < 2:
        print("Usage: python scripts/debug_github_search.py \"your question\"")
        sys.exit(1)

    query = sys.argv[1]
    print(f"Original question: {query!r}")

    try:
        reformulated = _build_github_query(query)
        print(f"Reformulated GitHub query: {reformulated!r}\n")
    except NameError:
        print("(_build_github_query not found — you're running the OLD github_research.py, the query fix hasn't been applied yet)\n")

    try:
        results = search_github(query)
    except Exception as e:
        print(f"search_github() raised: {e}")
        sys.exit(1)

    if not results:
        print("No results returned at all.")
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

echo "Updated backend/scripts/debug_github_search.py"
echo ""
echo "Run it the same way as before:"
echo "  python scripts/debug_github_search.py \"How can custom backoff intervals be configured in requests-based retry implementations?\""
