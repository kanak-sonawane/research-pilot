#!/usr/bin/env bash
set -e

# Phase 5 fix #5 — hard-cap the number of OR'd keywords sent to GitHub.
# Root cause: GitHub's search API rejects (422) any query with more than
# 5 AND/OR/NOT operators. The prompt asks the LLM for "2-4 keywords" but
# nothing enforced that in code — this time it returned 7, producing 6
# OR operators and tripping the limit. Same lesson as generate_plan() in
# Phase 2: never trust the model to obey a count instruction exactly;
# enforce it in code as a hard backstop.
# Run this from the root of your research-pilot/ project.

echo "Applying Phase 5 GitHub keyword-cap fix..."

python3 - << 'PYEOF'
path = "backend/app/github_research.py"
with open(path) as f:
    content = f.read()

old = '''    cleaned = raw.strip().strip('"').replace("?", "").replace("\\n", " ")
    keywords = [k for k in cleaned.split() if k]

    if not keywords:
        return question

    return " OR ".join(keywords)'''

new = '''    cleaned = raw.strip().strip('"').replace("?", "").replace("\\n", " ")
    keywords = [k for k in cleaned.split() if k]

    if not keywords:
        return question

    # Hard cap regardless of what the LLM actually returned. GitHub's
    # search API rejects (422 Unprocessable Entity) any query with more
    # than 5 AND/OR/NOT operators — 4 keywords joined with OR is 3
    # operators, safely under that limit even if the LLM ignores the
    # "2-4 keywords" instruction in the prompt.
    keywords = keywords[:4]

    return " OR ".join(keywords)'''

if old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("Added hard cap: keywords[:4] before joining with OR.")
else:
    print("WARNING: expected code block not found — check backend/app/github_research.py manually.")
PYEOF

echo ""
echo "Restart the backend. This fix is defensive/backstop in nature —"
echo "you likely won't need to re-trigger the exact same failure to confirm it,"
echo "but feel free to retry the same query if you want to see it directly."
