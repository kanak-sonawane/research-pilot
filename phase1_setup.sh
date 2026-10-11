#!/usr/bin/env bash
set -e

# Phase 1 — Research Request UI & Backend Entry Point
# Run this from the root of your research-pilot/ project.

echo "Setting up Phase 1 files..."

# ---------------------------------------------------------------------------
# Backend: request schema + /research endpoint
# ---------------------------------------------------------------------------

mkdir -p backend/app
touch backend/app/__init__.py

cat > backend/app/schemas.py << 'EOF'
from pydantic import BaseModel, field_validator


class ResearchRequest(BaseModel):
    """
    Incoming payload for POST /research.
    Kept minimal on purpose — Phase 1 only validates and normalizes
    the request. Planning/LLM handling starts in Phase 2.
    """
    query: str

    @field_validator("query")
    @classmethod
    def query_must_not_be_blank(cls, v: str) -> str:
        normalized = v.strip()
        if not normalized:
            raise ValueError("Research query cannot be empty.")
        return normalized


class ResearchRunResponse(BaseModel):
    """
    Placeholder response contract for Phase 1.
    Real research orchestration (LangGraph) replaces the placeholder
    fields in Phase 3+, but the response shape is meant to stay stable
    so the frontend doesn't need to change later.
    """
    run_id: str
    status: str
    query: str
    message: str
EOF

cat > backend/app/routes.py << 'EOF'
import uuid

from fastapi import APIRouter, HTTPException
from pydantic import ValidationError

from app.schemas import ResearchRequest, ResearchRunResponse

router = APIRouter()


@router.post("/research", response_model=ResearchRunResponse)
def start_research(payload: ResearchRequest):
    """
    Phase 1 entry point. Accepts and validates a research request and
    returns a placeholder run response so the frontend/backend contract
    is established before real orchestration (LangGraph) exists.
    """
    run_id = str(uuid.uuid4())

    return ResearchRunResponse(
        run_id=run_id,
        status="received",
        query=payload.query,
        message="Request received. Research orchestration is not implemented yet (Phase 1 placeholder).",
    )
EOF

# Wire the router into main.py if it isn't already wired in.
if ! grep -q "include_router" backend/main.py; then
  python3 - << 'PYEOF'
import re

with open("backend/main.py", "r") as f:
    content = f.read()

if "from app.routes import router" not in content:
    content = content.replace(
        "from fastapi.middleware.cors import CORSMiddleware",
        "from fastapi.middleware.cors import CORSMiddleware\nfrom app.routes import router",
    )

if "app.include_router(router)" not in content:
    # Insert after the CORS middleware block
    content += "\napp.include_router(router)\n"

with open("backend/main.py", "w") as f:
    f.write(content)
PYEOF
  echo "Wired router into backend/main.py"
else
  echo "backend/main.py already has include_router — skipping auto-wire, check it manually."
fi

# ---------------------------------------------------------------------------
# Frontend: research input UI wired to the backend
# ---------------------------------------------------------------------------

mkdir -p frontend/src/components

cat > frontend/src/components/ResearchForm.tsx << 'EOF'
"use client";

import { useState } from "react";

type RunStatus = "idle" | "loading" | "success" | "error";

interface ResearchRunResponse {
  run_id: string;
  status: string;
  query: string;
  message: string;
}

const API_BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:8000";

export default function ResearchForm() {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<RunStatus>("idle");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [result, setResult] = useState<ResearchRunResponse | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    // Client-side guard. The backend re-validates independently —
    // this is just to avoid a pointless round trip for empty input.
    if (!query.trim()) {
      setStatus("error");
      setErrorMessage("Please enter a research topic before submitting.");
      return;
    }

    setStatus("loading");
    setErrorMessage("");
    setResult(null);

    try {
      const res = await fetch(`${API_BASE_URL}/research`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query }),
      });

      if (!res.ok) {
        const errBody = await res.json().catch(() => null);
        throw new Error(
          errBody?.detail?.[0]?.msg || "The research request could not be submitted."
        );
      }

      const data: ResearchRunResponse = await res.json();
      setResult(data);
      setStatus("success");
    } catch (err) {
      setStatus("error");
      setErrorMessage(
        err instanceof Error ? err.message : "Something went wrong. Please try again."
      );
    }
  };

  return (
    <div className="w-full max-w-xl flex flex-col gap-4">
      <form onSubmit={handleSubmit} className="flex flex-col gap-3">
        <label htmlFor="research-query" className="font-medium">
          Technical research topic
        </label>
        <input
          id="research-query"
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="e.g. How does LangGraph handle cyclic workflows?"
          className="border rounded px-3 py-2"
          disabled={status === "loading"}
        />
        <button
          type="submit"
          disabled={status === "loading"}
          className="rounded bg-black px-4 py-2 text-white disabled:opacity-50"
        >
          {status === "loading" ? "Submitting..." : "Start Research"}
        </button>
      </form>

      {status === "error" && (
        <p className="text-red-600 text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      {status === "success" && result && (
        <div className="text-sm border rounded p-3 bg-gray-50">
          <p><strong>Run ID:</strong> {result.run_id}</p>
          <p><strong>Status:</strong> {result.status}</p>
          <p><strong>Message:</strong> {result.message}</p>
        </div>
      )}
    </div>
  );
}
EOF

cat > frontend/src/app/page.tsx << 'EOF'
import ResearchForm from "@/components/ResearchForm";

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-6 p-6">
      <h1 className="text-2xl font-semibold">Research Pilot</h1>
      <ResearchForm />
    </main>
  );
}
EOF

echo ""
echo "Phase 1 files created/updated:"
echo "  backend/app/schemas.py"
echo "  backend/app/routes.py"
echo "  backend/main.py (router wired in)"
echo "  frontend/src/components/ResearchForm.tsx"
echo "  frontend/src/app/page.tsx (replaced with the Phase 1 form)"
echo ""
echo "Next: restart both servers and test the flow manually (see docs/phase-1 verification steps)."
