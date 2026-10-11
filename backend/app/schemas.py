from typing import Dict, List, Optional

from pydantic import BaseModel, field_validator


class ResearchRequest(BaseModel):
    query: str

    @field_validator("query")
    @classmethod
    def query_must_not_be_blank(cls, v: str) -> str:
        normalized = v.strip()
        if not normalized:
            raise ValueError("Research query cannot be empty.")
        return normalized


class Plan(BaseModel):
    objective: str
    # Full history across all rounds — see ResearchState.research_questions.
    research_questions: List[str]


class EvidenceItem(BaseModel):
    question: str
    source_type: str
    source_title: str
    source_url: str
    claim: str


class ResearchRunResponse(BaseModel):
    run_id: str
    status: str
    query: str
    message: str
    plan: Optional[Plan] = None
    source_decisions: Optional[Dict[str, List[str]]] = None
    evidence: Optional[List[EvidenceItem]] = None
    warnings: Optional[List[str]] = None
    # New in Phase 6:
    sufficient: Optional[bool] = None
    # How many research rounds actually ran (1 = no looping occurred,
    # 2+ = the sufficiency loop fired at least once).
    research_rounds: Optional[int] = None
