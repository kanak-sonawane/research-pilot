#!/usr/bin/env bash
set -e

# Phase 5 fix #4 — use GitHub's default best-match relevance ranking
# instead of sorting by star count.
# Root cause: explicit sort=stars overrides relevance entirely, so huge
# generic megaprojects (awesome-lists, git itself) that merely CONTAIN
# one OR'd keyword somewhere in their README outrank small, genuinely
# relevant libraries with far fewer stars. Omitting sort/order restores
# GitHub's default "best match" ranking, which actually weighs how well
# the query matches.
# Run this from the root of your research-pilot/ project.

echo "Applying Phase 5 GitHub relevance-sort fix..."

python3 - << 'PYEOF'
path = "backend/app/github_research.py"
with open(path) as f:
    content = f.read()

old = '''    params = {"q": github_query, "per_page": max_results, "sort": "stars", "order": "desc"}'''
new = '''    # No "sort" param: GitHub's default is best-match relevance ranking,
    # which weighs how well the query terms actually match. Explicitly
    # sorting by stars instead would surface huge generic repos that
    # merely contain a keyword somewhere, ahead of small but genuinely
    # relevant ones — exactly the problem this fix addresses.
    params = {"q": github_query, "per_page": max_results}'''

if old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("Removed explicit sort=stars — now using GitHub's default best-match ranking.")
else:
    print("WARNING: expected params line not found — file may already be in an unexpected state. Check backend/app/github_research.py manually.")
PYEOF

echo ""
echo "Restart the backend, then re-run the debug script:"
echo "  python scripts/debug_github_search.py \"How can custom backoff intervals be configured in requests-based retry implementations?\""
