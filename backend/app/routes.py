import logging
import threading
import uuid

from fastapi import APIRouter, HTTPException

from app import run_store
from app.graph import research_graph
from app.schemas import Plan, ResearchRequest, ResearchRunResponse, RunAccepted, RunStatus

logger = logging.getLogger(__name__)
router = APIRouter()


def _build_result(run_id: str, query: str) -> ResearchRunResponse:
    """Runs the research graph and turns its final state into the result (same logic as before Phase 8)."""
    try:
        final_state = research_graph.invoke({
            "run_id": run_id,
            "query": query,
        })
    except Exception as e:  # the user always gets a readable result, never a silent failure
        logger.exception("Research run crashed")
        return ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=query,
            message=f"Research could not be completed because of an internal error ({type(e).__name__}). Please try again.",
        )

    if final_state.get("error"):
        return ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=query,
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

    fields = dict(
        run_id=run_id,
        status=status,
        query=query,
        message=message,
        plan=Plan(
            objective=final_state["objective"],
            research_questions=final_state["research_questions"],
        ),
        source_decisions=final_state.get("source_decisions"),
        evidence=evidence,
        warnings=final_state.get("research_warnings"),
        sufficient=final_state.get("sufficient"),
        research_rounds=final_state.get("research_iteration", 0) + 1,
    )
    try:
        return ResearchRunResponse(**fields, report=final_state.get("report"))
    except Exception:  # a malformed report must not throw away the evidence
        logger.exception("Report did not match the response schema; returning the result without it")
        return ResearchRunResponse(**fields, report=None)


def _execute_run(run_id: str, query: str) -> None:
    """Background thread: runs the research and always records a final result."""
    try:
        result = _build_result(run_id, query)
    except Exception:
        logger.exception("Could not assemble the research result")
        result = ResearchRunResponse(
            run_id=run_id,
            status="failed",
            query=query,
            message="Research finished, but the result could not be assembled because of an internal error. Please try again.",
        )
    run_store.finish_run(run_id, result.model_dump())


@router.post("/research", response_model=RunAccepted, status_code=202)
def start_research(payload: ResearchRequest):
    """Starts a research run in the background and returns immediately."""
    run_id = str(uuid.uuid4())
    if not run_store.create_run(run_id, payload.query):
        raise HTTPException(
            status_code=429,
            detail="Too many research runs are already in progress. Please wait for one to finish and try again.",
        )
    threading.Thread(
        target=_execute_run, args=(run_id, payload.query), daemon=True, name=f"run-{run_id[:8]}"
    ).start()
    return RunAccepted(run_id=run_id, status="running")


@router.get("/research/{run_id}", response_model=RunStatus)
def get_research_status(run_id: str):
    """Current stage of a run, plus the full result once it has finished."""
    run = run_store.get_run(run_id)
    if run is None:
        raise HTTPException(
            status_code=404,
            detail="Research run not found. The backend may have been restarted; please start the research again.",
        )
    return RunStatus(**run)
