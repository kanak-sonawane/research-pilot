#!/usr/bin/env bash
set -e

# Phase 6 performance fix — parallelize independent per-question work.
# Root cause of multi-minute runs: every question's research (search +
# LLM extraction) runs one at a time in a sequential loop, even though
# different questions' research is completely independent of each other.
# This change runs each source type's questions concurrently via a
# thread pool, without changing what gets searched, what gets extracted,
# or how sufficiency is judged — same research quality, less wall-clock
# time spent waiting on sequential I/O and LLM calls.
# Run this from the root of your research-pilot/ project.

echo "Applying Phase 6 performance fix..."

# ---------------------------------------------------------------------------
# graph.py — parallelize the per-question loop inside each research node
# ---------------------------------------------------------------------------

python3 - << 'PYEOF'
path = "backend/app/graph.py"
with open(path) as f:
    content = f.read()

old_imports = '''from langgraph.graph import StateGraph, END'''
new_imports = '''import concurrent.futures

from langgraph.graph import StateGraph, END'''

old_constant_block = '''MAX_RESEARCH_ROUNDS = 2'''
new_constant_block = '''MAX_RESEARCH_ROUNDS = 2

# Bounds how many questions' research runs concurrently per source-type
# node. Kept modest (not "as many as possible") for two reasons: a local
# Ollama instance can only usefully handle a limited number of concurrent
# generate requests before they start queuing anyway (depends on hardware
# and OLLAMA_NUM_PARALLEL), and external APIs (Tavily, GitHub) have their
# own rate limits that many simultaneous requests could trip.
MAX_WORKERS = 3'''

old_factory = '''def _build_research_node(source_type: str, research_fn):
    """
    Iterates `active_questions` (NOT all of source_decisions) so each
    round only researches its own questions, not every question ever
    asked across the whole run — source_decisions accumulates historical
    routing, but re-researching already-covered questions every loop
    would waste calls and duplicate evidence.
    """

    def node(state: ResearchState) -> dict:
        if state.get("error"):
            return {}

        active_questions = state.get("active_questions", [])
        source_decisions = state.get("source_decisions", {})
        evidence = list(state.get("evidence", []))
        warnings = list(state.get("research_warnings", []))

        for question in active_questions:
            sources = source_decisions.get(question, [])
            if source_type not in sources:
                continue
            try:
                evidence.extend(research_fn(question))
            except ResearchError as e:
                warnings.append(f"'{question}' ({source_type}): {e}")

        result: dict = {"evidence": evidence}
        if warnings:
            result["research_warnings"] = warnings
        return result

    return node'''

new_factory = '''def _build_research_node(source_type: str, research_fn):
    """
    Iterates `active_questions` (NOT all of source_decisions) so each
    round only researches its own questions, not every question ever
    asked across the whole run — source_decisions accumulates historical
    routing, but re-researching already-covered questions every loop
    would waste calls and duplicate evidence.

    Questions routed to this source type are researched CONCURRENTLY via
    a thread pool, not one at a time in a loop. Each question's research
    (a search call + an LLM extraction call, and for github an extra
    query-reformulation call) is completely independent of every other
    question's — nothing about researching question A depends on having
    already finished question B. Previously N questions took roughly N
    times one question's worth of sequential wall-clock time; now they
    take roughly 1x, bounded by MAX_WORKERS. This is a pure latency
    optimization — it changes nothing about what gets searched, what
    gets extracted, or what evidence looks like; only how much wall-clock
    time it takes to gather it.

    Thread-safety note: each thread only calls research_fn(question),
    which does its own independent network/LLM calls and returns a
    result — no shared mutable state is touched inside the threads.
    Results are merged into `evidence`/`warnings` only in the main
    thread, after each future completes, so there's no concurrent
    write hazard on those lists.
    """

    def node(state: ResearchState) -> dict:
        if state.get("error"):
            return {}

        active_questions = state.get("active_questions", [])
        source_decisions = state.get("source_decisions", {})
        evidence = list(state.get("evidence", []))
        warnings = list(state.get("research_warnings", []))

        questions_to_research = [
            q for q in active_questions if source_type in source_decisions.get(q, [])
        ]

        if not questions_to_research:
            return {}

        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            future_to_question = {
                executor.submit(research_fn, q): q for q in questions_to_research
            }
            for future in concurrent.futures.as_completed(future_to_question):
                question = future_to_question[future]
                try:
                    evidence.extend(future.result())
                except ResearchError as e:
                    warnings.append(f"'{question}' ({source_type}): {e}")

        result: dict = {"evidence": evidence}
        if warnings:
            result["research_warnings"] = warnings
        return result

    return node'''

assert old_imports in content, "import block not found"
assert old_constant_block in content, "constant block not found"
assert old_factory in content, "_build_research_node not found"

content = content.replace(old_imports, new_imports)
content = content.replace(old_constant_block, new_constant_block)
content = content.replace(old_factory, new_factory)

with open(path, "w") as f:
    f.write(content)

print("Updated graph.py: per-question research now runs concurrently (MAX_WORKERS=3).")
PYEOF

# ---------------------------------------------------------------------------
# github_research.py — parallelize README fetching for the top results
# ---------------------------------------------------------------------------

python3 - << 'PYEOF'
path = "backend/app/github_research.py"
with open(path) as f:
    content = f.read()

old_import = '''import requests

from app.config import GITHUB_TOKEN'''
new_import = '''import concurrent.futures

import requests

from app.config import GITHUB_TOKEN'''

old_loop = '''    items = response.json().get("items", [])

    results = []
    for i, item in enumerate(items):
        full_name = item.get("full_name", "")
        description = item.get("description") or ""

        content = description
        if i < README_FETCH_LIMIT and full_name:
            readme_text = _fetch_readme(full_name)
            if readme_text:
                content = f"{description}\\n\\n{readme_text}"

        results.append({
            "title": full_name,
            "url": item.get("html_url", ""),
            "content": content,
        })

    return results'''

new_loop = '''    items = response.json().get("items", [])

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
        content = f"{description}\\n\\n{readme_text}" if readme_text else description

        results.append({
            "title": full_name,
            "url": item.get("html_url", ""),
            "content": content,
        })

    return results'''

assert old_import in content, "import block not found in github_research.py"
assert old_loop in content, "README-fetch loop not found in github_research.py — file may differ from expected state"

content = content.replace(old_import, new_import)
content = content.replace(old_loop, new_loop)

with open(path, "w") as f:
    f.write(content)

print("Updated github_research.py: README fetches for top results now run concurrently.")
PYEOF

echo ""
echo "Performance fix applied. No new dependencies (concurrent.futures is in"
echo "the Python standard library). Restart the backend to pick up the change."
echo ""
echo "Optional further speed-up (not a code change, just an Ollama setting):"
echo "if your machine has the RAM/compute to spare, running Ollama with"
echo "OLLAMA_NUM_PARALLEL set above its default lets it actually process"
echo "more than one of these concurrent LLM calls at once, instead of"
echo "queuing them internally even though the code now sends them together."
echo "This is optional and hardware-dependent — skip it if unsure."
