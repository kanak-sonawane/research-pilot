import logging
import uuid

from fastapi import APIRouter

from app.schemas import ResearchRequest, ResearchRunResponse, Plan
from app.graph import research_graph

router = APIRouter()


@router.post("/research", response_model=ResearchRunResponse)
def start_research(payload: ResearchRequest):
    run_id = str(uuid.uuid4())

    try:
        final_state = research_graph.invoke({
            "run_id": run_id,
            "query": payload.query,
        })
    except Exception as e:  # the client always gets a readable response, never a bare 500
        logging.getLogger(__name__).exception("Research run crashed")
        return ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=payload.query,
            message=f"Research could not be completed because of an internal error ({type(e).__name__}). Please try again.",
        )

    if final_state.get("error"):
        return ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=payload.query,
            message=final_state["error"],
        )

    evidence = final_state.get("evidence", [])
    unanswered = (final_state.get("report") or {}).get("unanswered_questions", [])
    if not evidence:
        status = "failed"
        message = (
            "Research could not gather any usable evidence. Check the warnings "
            "(for example a missing or invalid API key) and try again."
        )
    elif unanswered:
        status = "research_incomplete"
        message = f"Research finished with gaps: {len(unanswered)} question(s) could not be answered."
    else:
        status = "research_complete"
        message = "Research complete. Report generated from the gathered evidence."

    return ResearchRunResponse(
        run_id=run_id,
        status=status,
        query=payload.query,
        message=message,
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
        evidence=final_state.get("evidence", []),
        warnings=final_state.get("research_warnings"),
        sufficient=final_state.get("sufficient"),
        research_rounds=final_state.get("research_iteration", 0) + 1,
        report=final_state.get("report"),
    )
