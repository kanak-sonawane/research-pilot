from app.web_research import get_client, extract_evidence, ResearchError

# Dynamic discovery, per the PRD, means we don't hardcode a list of docs
# sites per library. Instead we scope a normal web search toward
# documentation specifically by appending this qualifier to the query,
# and let the search engine's own ranking surface the actual official
# docs page for whatever library/tool the question is about.
DOCS_QUERY_SUFFIX = " official documentation"


def search_docs(query: str, max_results: int = 5) -> list[dict]:
    try:
        client = get_client()
        response = client.search(query=query + DOCS_QUERY_SUFFIX, max_results=max_results)
        return response.get("results", [])
    except ResearchError:
        raise
    except Exception as e:
        raise ResearchError(f"Docs search failed for '{query}': {e}") from e


def research_question_docs(question: str) -> list[dict]:
    results = search_docs(question)
    return extract_evidence(question, results, source_type="docs")
