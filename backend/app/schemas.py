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
    research_questions: List[str]


class EvidenceItem(BaseModel):
    question: str
    source_type: str
    source_title: str
    source_url: str
    claim: str
    quote: str = ""


# ---- Report (Phase 7) ----------------------------------------------------

class ReportFinding(BaseModel):
    statement: str
    evidence_ids: List[str]


class FindingsSubsection(BaseModel):
    heading: str
    findings: List[ReportFinding]


class ArchitectureGroup(BaseModel):
    name: str
    description: str = ""
    items: List[str] = []


class ReportEvidence(BaseModel):
    id: str
    claim: str
    quote: str = ""
    question: str
    source_id: str
    source_type: str


class ReportSource(BaseModel):
    id: str
    title: str
    url: str
    source_types: List[str]


class Methodology(BaseModel):
    objective: str
    research_questions: List[str]
    source_categories_searched: List[str]
    source_categories_with_evidence: List[str]
    tools_used: List[str]
    search_strategy: str
    source_selection_approach: str
    research_rounds: int
    limitations: List[str]


class ValidationResult(BaseModel):
    passed: bool
    issues: List[str]
    dropped_findings: int


class Report(BaseModel):
    findings: List[FindingsSubsection]
    information_architecture: List[ArchitectureGroup]
    methodology: Methodology
    sources: List[ReportSource]
    evidence: List[ReportEvidence]
    unanswered_questions: List[str]
    validation: ValidationResult


class ResearchRunResponse(BaseModel):
    run_id: str
    status: str
    query: str
    message: str
    plan: Optional[Plan] = None
    source_decisions: Optional[Dict[str, List[str]]] = None
    evidence: Optional[List[EvidenceItem]] = None
    warnings: Optional[List[str]] = None
    sufficient: Optional[bool] = None
    research_rounds: Optional[int] = None
    report: Optional[Report] = None


# ---- Run tracking (Phase 8) -------------------------------------------------------------

class RunAccepted(BaseModel):
    run_id: str
    status: str  # always "running"


class RunStatus(BaseModel):
    run_id: str
    # "running" while in progress, then the result's status:
    # "research_complete" | "research_incomplete" | "failed"
    status: str
    stage: str
    stage_label: str
    round: int
    elapsed_seconds: int
    result: Optional[ResearchRunResponse] = None
