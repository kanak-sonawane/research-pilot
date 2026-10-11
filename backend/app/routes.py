import uuid

from fastapi import APIRouter

from app.schemas import ResearchRequest, ResearchRunResponse, Plan
from app.graph import research_graph

router = APIRouter()


@router.post("/research", response_model=ResearchRunResponse)
def start_research(payload: ResearchRequest):
    run_id = str(uuid.uuid4())

    final_state = research_graph.invoke({
        "run_id": run_id,
        "query": payload.query,
    })

    if final_state.get("error"):
        return ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=payload.query,
            message=final_state["error"],
        )

    return ResearchRunResponse(
        run_id=run_id,
        status="research_complete",
        query=payload.query,
        message="Research plan, source routing, and evidence gathered.",
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
        evidence=final_state.get("evidence", []),
        warnings=final_state.get("research_warnings"),
        sufficient=final_state.get("sufficient"),
        research_rounds=final_state.get("research_iteration", 0) + 1,
    )
