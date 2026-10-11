# Phase 5 — Docs Discovery & GitHub Research

**Status:** Complete
**Depends on:** Phase 4

## Overview

Phase 4 built `research_web`, which searches Tavily and extracts evidence for questions routed to `"web"`. Phase 5 fills in the two remaining source types: `"docs"` (official documentation, via a scoped Tavily search) and `"github"` (repository search via GitHub's REST API). Both reuse Phase 4's `extract_evidence()` unchanged — the only new work per source type is getting raw, *usable* content into the same `{"title", "url", "content"}` shape Phase 4 already knows how to process.

**This phase took five iterations to get right**, all on the GitHub side — docs discovery worked essentially on the first try. That's not a sign of a bad plan; it's a direct consequence of the fact that GitHub's search API works nothing like a general web/semantic search engine, and every mismatch between "how we assumed it worked" and "how it actually works" surfaced as a distinct, real bug. Each is documented below in the order it was found, because the debugging path itself is useful history — several of these bugs would have been very confusing to hit cold, without the context of what was tried before.

## Architecture / Flow Change

**Phase 4 flow:**
```
plan → decide_sources → research_web → END
```

**Phase 5 flow:**
```
plan → decide_sources → research_web → research_docs → research_github → END
```

**Key refactor accompanying this phase:** the per-question research loop (skip if source not routed here, try/except into warnings, accumulate evidence) was pulled out of `research_web_node` into one shared factory, `_build_research_node(source_type, research_fn)`, in `graph.py`. With three source types now sharing the identical loop shape, the alternative was three near-copies of the same function — the same DRY judgment call as `json_utils.py` in Phase 4.

**Correctness detail in that factory, worth calling out explicitly:** each node reads `state.get("evidence", [])` and `state.get("research_warnings", [])` as its *starting point* and extends them, rather than building a fresh list. LangGraph merges a node's returned dict into state by **replacing** each key wholesale, not by concatenating lists. If `research_docs_node` returned only its own new evidence under `"evidence"`, it would silently delete everything `research_web_node` had already gathered. This is the same category of subtlety as `total=False` on `ResearchState` in Phase 3 — a LangGraph mechanic that's easy to get wrong silently.

## Key Files / Components

### `backend/app/docs_research.py` (new)
Implements "dynamic discovery" (per the PRD — no hardcoded docs-site list) as a **scoped Tavily search**: the research question gets `" official documentation"` appended before searching, and the search engine's own ranking does the actual discovery of which library/tool's docs are relevant. This reuses `get_client()` and `extract_evidence()` from `web_research.py` directly — `get_client()` was made non-underscore-prefixed specifically so this module could share the same Tavily client construction rather than duplicating it. Worked correctly with no debugging needed, because Tavily (a real search engine) handles natural-language queries the same way regardless of the extra suffix.

### `backend/app/github_research.py` (new, rewritten five times)
This file's final state reflects five real, distinct problems found via live testing (not from documentation-reading in advance) — each one only visible once the previous one was fixed and a new failure mode was exposed underneath.

**Bug 1 — thin content from repo descriptions alone.**
Initial version populated each result's `content` from only the repo's one-line `description` field (e.g. "A simple, yet elegant, HTTP library."). That's nowhere near enough substance for `extract_evidence()`'s LLM call to pull a specific, detailed claim from — unlike web/docs results, which carry up to 1000 characters of real page content.
*Fix:* for the top `README_FETCH_LIMIT` (3) results, fetch each repo's actual README via a second API call (`GET /repos/{full_name}/readme` with `Accept: application/vnd.github.raw`) and append a chunk of it (`README_CHARS` = 2000) to the content. Capped at 3 to bound the extra API calls per question.

**Bug 2 — zero results, root cause invisible without direct API testing.**
Even with richer content ready to use, searches were returning **zero repos at all** — confirmed via a standalone debug script (`scripts/debug_github_search.py`) that calls `search_github()` directly, bypassing the LLM entirely, specifically built to distinguish "bad query" from "code bug." It showed `No results returned at all` for a full natural-language question passed straight through as the search query.
*Root cause:* GitHub's repository search matches only against a repo's **name, description, and topics** (not full-text/body content), and defaults every space-separated term to **AND** logic. A 12-word question requires all 12 words to appear across those short fields on some repo — which essentially never happens.
*Fix:* added `_build_github_query()` — an LLM call that reduces the question to 2–4 short technical keywords before searching, instead of passing the raw question through.

**Bug 3 — reformulation worked, but still zero results.**
The debug script confirmed a good keyword set (`'requests retry backoff custom exponential'`) was being generated — but search still returned nothing.
*Root cause:* space-separated terms still default to AND. Five well-chosen keywords still requires *all five* to appear together on one repo's short metadata fields — still too strict.
*Fix:* join keywords with GitHub's explicit `OR` operator instead of relying on default AND. Matching just one keyword is now enough to surface a result.

**Bug 4 — results came back, but irrelevant.**
With OR-joined keywords, searches started returning real repos — but the top hits were massive, generic projects (`sindresorhus/awesome`, `git/git`, `openwrt/openwrt`) that merely happened to contain one keyword somewhere in a huge README, while the genuinely relevant `psf/requests` was buried at position 3.
*Root cause:* the code explicitly set `sort=stars`, which **overrides GitHub's relevance ranking entirely** and just returns the most-starred matching repos — popularity, not relevance, decided the ordering. Any repo containing even one OR'd term, if popular enough, would dominate regardless of actual fit.
*Fix:* removed the explicit `sort`/`order` params. GitHub's default (no `sort` param) is "best match" relevance ranking, which weighs how well the query terms actually match — exactly what was needed. Confirmed via the debug script: results shifted to `litl/backoff`, `ihrwein/backoff`, `cenkalti/backoff` — precisely on-topic libraries.

**Bug 5 — 422 Unprocessable Entity on a different question, in the same run.**
Live end-to-end testing (not just the debug script) surfaced a fifth issue: a different question in the same research run failed with a `422` from GitHub, surfaced correctly as a non-fatal warning (not a crash) rather than aborting the run.
*Root cause:* GitHub's search API rejects any query containing more than 5 `AND`/`OR`/`NOT` operators. The LLM returned 7 keywords that run (`exponential`, `backoff`, `base`, `delay`, `max`, `retries`, `jitter`) → 6 `OR` operators → over the limit. The prompt asks for "2–4 keywords," but nothing in the code enforced that — the same category of mistake as trusting `generate_plan()`'s question count in Phase 2, except this time the model's over-generation had a hard external consequence (an API rejection) rather than just an internal state concern.
*Fix:* hard-cap `keywords[:4]` in code after the LLM call, regardless of what the model actually returned. Never trust a count instruction in a prompt to be a code-level guarantee.

**Net result:** `search_github()` now (a) enriches top results with README content, (b) reformulates the question into a small keyword set via LLM, (c) hard-caps that set at 4 keywords, (d) joins them with `OR`, and (e) omits any explicit sort, letting GitHub's relevance ranking do the work.

### `backend/scripts/debug_github_search.py` (new, dev-only)
Not part of the request-serving path — a standalone script that calls `search_github()`/`_build_github_query()` directly and prints raw results (title, URL, content length/preview), bypassing the LLM evidence-extraction step. This was the single most useful tool in this phase: it let each hypothesis (bad content → bad query → bad operator → bad sort) get tested in isolation, in seconds, without waiting on a full plan → decide_sources → research chain and an LLM extraction call just to see whether the *search itself* was returning anything sane. Worth keeping around for any future GitHub-search-related debugging.

### `backend/app/state.py`
`web_research_warnings` renamed to `research_warnings`, since docs and GitHub research now both contribute to the same non-fatal warning channel Phase 4 introduced for web-only. No new fields.

### `backend/app/routes.py`
Status renamed from `"web_research_complete"` to `"research_complete"`, since research now covers all three source types, not just web.

## Dependencies / Configuration Added

- `requests` (backend) — used by `github_research.py` for GitHub's REST API
- `GITHUB_TOKEN` — required in `backend/.env`; a classic personal access token with **no scopes checked** is sufficient (public repo search only), since the only benefit of authentication here is the higher rate limit (5,000/hr vs. 60/hr unauthenticated)

## How to Run / Verify This Phase

1. Confirm `backend/.env` has a real `GITHUB_TOKEN`
2. `pip install -r backend/requirements.txt`
3. Restart backend + frontend
4. Submit a topic likely to route across all three source types, e.g.:
   *"How do popular open-source GitHub projects implement retry logic with exponential backoff, and what does the official documentation recommend?"*
5. Confirm evidence appears tagged `[web]`, `[docs]`, and `[github]` with real, on-topic sources and working links
6. For isolated GitHub-only debugging in the future: `python scripts/debug_github_search.py "some question"` from `backend/`, venv active

## Known Issues / Follow-ups

- GitHub repo search only ever searches **repositories**, not code search or issues — a question genuinely requiring "what does issue #452 say" would not be answerable by this implementation. Acceptable for MVP scope.
- `README_FETCH_LIMIT = 3` means only the top 3 results per GitHub question get enriched content; results 4–5 fall back to bare descriptions. Not a bug, just a deliberate latency/thoroughness tradeoff.
- Source routing (`decide_sources`, Phase 3) is itself an LLM judgment call and won't always route a question to `github` even when GitHub evidence would help — this is expected variability in the routing step, not a Phase 5 defect.
- No caching across the many API calls per run (Tavily, docs search, GitHub search, README fetches) — acceptable at current scale, worth reconsidering if usage grows.

---

# Next Phase Preview — Phase 6: Evidence Evaluation & Sufficiency Loop

## Goal
Every phase so far has been "gather evidence and stop." Phase 6 adds actual judgment: after research runs, an LLM evaluates whether the gathered evidence is *sufficient* to answer the objective — and if not, the graph **loops back** to do another round of targeted research instead of just reporting whatever was found. This is the first genuinely cyclic part of the graph, and the first place a **bounded loop** (per the PRD's "research loops are always bounded" requirement) needs to be enforced in code, not just as a design intention.

## New graph flow
```
plan → decide_sources → research_web → research_docs → research_github → evaluate_sufficiency
                                                                              │
                                                        insufficient ────────┤
                                                        (loop back,          │
                                                         bounded)            │
                                                              sufficient ────┘
                                                                              ▼
                                                                             END
```
This introduces LangGraph's `add_conditional_edges` for the first time — up to now, every edge in the graph has been a fixed, unconditional `add_edge`.

## What `evaluate_sufficiency` does
Given the objective, research questions, and all gathered evidence, the LLM judges: does this evidence actually answer the objective, or are there clear gaps? Output is structured (sufficient: true/false, plus which specific questions/gaps remain if not).

## The bounded loop
A hard iteration cap (e.g. 2 extra rounds max) lives in `ResearchState` as a counter, incremented each time the loop fires. This is non-negotiable per the PRD — an "infinite refinement" failure mode is exactly what bounded loops exist to prevent. When the cap is hit, the graph proceeds to `END` regardless of sufficiency judgment, with whatever evidence exists at that point — not stuck retrying forever.

## What happens on a second round
Rather than re-running research on every original question, the second round should target specifically the gaps `evaluate_sufficiency` identified — otherwise the loop just repeats the same searches and gets the same results.

No new external dependencies expected — this phase is new orchestration logic (a new node, a new state field, a conditional edge) rather than new integrations.

Let me know when you're ready and I'll generate `phase6_setup.sh`.
