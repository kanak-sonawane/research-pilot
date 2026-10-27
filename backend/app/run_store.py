"""
In-memory run tracking (Phase 8). Stateless MVP: nothing is saved to disk, and a backend
restart forgets every run (the UI reports that clearly).
"""
import threading
import time
from typing import Dict, Optional

# Graph node name -> the stage shown to the user.
NODE_STAGES = {
    "plan": "planning",
    "decide_sources": "routing",
    "research_web": "researching",
    "research_docs": "researching",
    "research_github": "researching",
    "evaluate_sufficiency": "evaluating",
    "generate_report": "reporting",
}

STAGE_LABELS = {
    "queued": "Starting",
    "planning": "Planning the research",
    "routing": "Choosing sources",
    "researching": "Searching sources",
    "evaluating": "Checking the evidence",
    "reporting": "Writing the report",
    "done": "Finished",
}

# Runs allowed at the same time. LLM calls are serialized by llm_service, so more runs would
# just queue behind each other on a local model.
MAX_ACTIVE_RUNS = 2
# Finished runs are forgotten after this long, and at most this many runs are kept.
RUN_TTL_SECONDS = 3600
MAX_STORED_RUNS = 50

_lock = threading.Lock()
_runs: Dict[str, dict] = {}


def _prune(now: float) -> None:
    """Called with the lock held."""
    for run_id in [r for r, run in _runs.items() if run["status"] != "running" and now - run["updated_at"] > RUN_TTL_SECONDS]:
        del _runs[run_id]
    overflow = len(_runs) - MAX_STORED_RUNS
    if overflow > 0:
        finished = sorted((run["updated_at"], r) for r, run in _runs.items() if run["status"] != "running")
        for _, run_id in finished[:overflow]:
            del _runs[run_id]


def create_run(run_id: str, query: str) -> bool:
    """Registers a new running run. Returns False if too many runs are already in progress."""
    now = time.time()
    with _lock:
        _prune(now)
        if sum(1 for run in _runs.values() if run["status"] == "running") >= MAX_ACTIVE_RUNS:
            return False
        _runs[run_id] = {
            "run_id": run_id,
            "query": query,
            "status": "running",
            "stage": "queued",
            "stage_label": STAGE_LABELS["queued"],
            "round": 1,
            "result": None,
            "started_at": now,
            "updated_at": now,
            "finished_at": None,
        }
        return True


def set_stage(run_id: Optional[str], node_name: str, round_number: int = 1) -> None:
    """Called by the graph when a node starts. Ignored for unknown runs/nodes."""
    stage = NODE_STAGES.get(node_name)
    if not run_id or not stage:
        return
    with _lock:
        run = _runs.get(run_id)
        if run is None or run["status"] != "running":
            return
        run["stage"] = stage
        run["stage_label"] = STAGE_LABELS[stage]
        run["round"] = round_number
        run["updated_at"] = time.time()


def finish_run(run_id: str, result: dict) -> None:
    """Stores the final result; the run's status becomes the result's status."""
    now = time.time()
    with _lock:
        run = _runs.get(run_id)
        if run is None:
            return
        run["status"] = result.get("status", "failed")
        run["stage"] = "done"
        run["stage_label"] = STAGE_LABELS["done"]
        run["result"] = result
        run["updated_at"] = now
        run["finished_at"] = now


def get_run(run_id: str) -> Optional[dict]:
    """A snapshot of the run (with elapsed_seconds), or None if unknown."""
    with _lock:
        run = _runs.get(run_id)
        if run is None:
            return None
        snapshot = dict(run)
    end = snapshot["finished_at"] or time.time()
    snapshot["elapsed_seconds"] = int(end - snapshot["started_at"])
    return snapshot
