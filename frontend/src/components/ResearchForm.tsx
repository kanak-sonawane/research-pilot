"use client";

import { useEffect, useState } from "react";
import ReportView, { type Report } from "@/components/ReportView";
import ResearchProgress, { type RunProgress } from "@/components/ResearchProgress";

type Phase = "idle" | "submitting" | "running" | "done" | "error";

interface Plan {
  objective: string;
  research_questions: string[];
}

interface EvidenceItem {
  question: string;
  source_type: string;
  source_title: string;
  source_url: string;
  claim: string;
  quote?: string;
}

interface ResearchRunResponse {
  run_id: string;
  status: string;
  query: string;
  message: string;
  plan: Plan | null;
  source_decisions: Record<string, string[]> | null;
  evidence: EvidenceItem[] | null;
  warnings: string[] | null;
  sufficient: boolean | null;
  research_rounds: number | null;
  report: Report | null;
}

interface RunStatusResponse {
  run_id: string;
  status: string;
  stage: string;
  stage_label: string;
  round: number;
  elapsed_seconds: number;
  result: ResearchRunResponse | null;
}

const API_BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:8000";

const POLL_INTERVAL_MS = 2000;
// Consecutive failed polls tolerated before giving up (a brief hiccup is retried).
const MAX_POLL_FAILURES = 5;

const STATUS_STYLES: Record<string, string> = {
  research_complete: "text-green-800 bg-green-50 border-green-200",
  research_incomplete: "text-amber-800 bg-amber-50 border-amber-200",
  failed: "text-red-800 bg-red-50 border-red-200",
};

const STATUS_LABELS: Record<string, string> = {
  research_complete: "Complete",
  research_incomplete: "Incomplete",
  failed: "Failed",
};

function extractDetail(body: unknown): string | null {
  const detail = (body as { detail?: unknown } | null)?.detail;
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail) && detail[0] && typeof detail[0].msg === "string") return detail[0].msg;
  return null;
}

export default function ResearchForm() {
  const [query, setQuery] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [runId, setRunId] = useState<string | null>(null);
  const [progress, setProgress] = useState<RunProgress | null>(null);
  const [connectionIssue, setConnectionIssue] = useState(false);
  const [result, setResult] = useState<ResearchRunResponse | null>(null);

  // Polls the backend for the current run until it finishes, fails, or the page is left.
  useEffect(() => {
    if (!runId) return;

    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let failures = 0;

    const fail = (message: string) => {
      setConnectionIssue(false);
      setErrorMessage(message);
      setPhase("error");
    };

    const poll = async () => {
      try {
        const res = await fetch(`${API_BASE_URL}/research/${runId}`);
        if (cancelled) return;

        if (res.status === 404) {
          fail(
            extractDetail(await res.json().catch(() => null)) ||
              "This research run was not found. The backend may have been restarted; please start it again."
          );
          return;
        }
        if (!res.ok) throw new Error(`HTTP ${res.status}`);

        const data: RunStatusResponse = await res.json();
        if (cancelled) return;

        failures = 0;
        setConnectionIssue(false);

        if (data.status === "running") {
          setProgress({
            stage: data.stage,
            stage_label: data.stage_label,
            round: data.round,
            elapsed_seconds: data.elapsed_seconds,
          });
          timer = setTimeout(poll, POLL_INTERVAL_MS);
          return;
        }

        if (data.result) {
          setResult(data.result);
          setPhase("done");
        } else {
          fail("The research finished without a result. Please try again.");
        }
      } catch {
        if (cancelled) return;
        failures += 1;
        if (failures >= MAX_POLL_FAILURES) {
          fail("Lost connection to the research server. Check that the backend is running, then start the research again.");
          return;
        }
        setConnectionIssue(true);
        timer = setTimeout(poll, POLL_INTERVAL_MS);
      }
    };

    poll();

    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [runId]);

  const busy = phase === "submitting" || phase === "running";

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;

    if (!query.trim()) {
      setPhase("error");
      setErrorMessage("Please enter a research topic before submitting.");
      return;
    }

    setPhase("submitting");
    setErrorMessage("");
    setResult(null);
    setProgress(null);
    setConnectionIssue(false);
    setRunId(null);

    try {
      const res = await fetch(`${API_BASE_URL}/research`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query }),
      });

      if (!res.ok) {
        const errBody = await res.json().catch(() => null);
        throw new Error(extractDetail(errBody) || "The research request could not be submitted.");
      }

      const data: { run_id: string } = await res.json();
      setProgress({ stage: "queued", stage_label: "Starting", round: 1, elapsed_seconds: 0 });
      setPhase("running");
      setRunId(data.run_id);
    } catch (err) {
      setPhase("error");
      setErrorMessage(
        err instanceof TypeError
          ? "Could not reach the research server. Make sure the backend is running."
          : err instanceof Error
          ? err.message
          : "Something went wrong. Please try again."
      );
    }
  };

  const evidenceForQuestion = (question: string) =>
    result?.evidence?.filter((e) => e.question === question) ?? [];

  return (
    <div className="w-full max-w-3xl flex flex-col gap-4">
      <form onSubmit={handleSubmit} className="flex flex-col gap-3">
        <label htmlFor="research-query" className="font-medium text-gray-900">
          Technical research topic
        </label>
        <input
          id="research-query"
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="e.g. How does LangGraph handle cyclic workflows?"
          className="border rounded px-3 py-2 text-gray-900 placeholder:text-gray-400 bg-white"
          // Keeps the native input on light styling regardless of OS dark mode.
          style={{ colorScheme: "light" }}
          disabled={busy}
        />
        <button
          type="submit"
          disabled={busy}
          className="rounded bg-black px-4 py-2 text-white disabled:opacity-50"
        >
          {phase === "submitting" ? "Starting..." : phase === "running" ? "Researching..." : "Start Research"}
        </button>
      </form>

      {phase === "error" && (
        <p className="text-red-600 text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      {phase === "running" && progress && (
        <div className="flex flex-col gap-2">
          <ResearchProgress progress={progress} />
          {connectionIssue && (
            <p className="text-amber-700 text-sm" role="status">
              The connection to the backend was interrupted. Retrying...
            </p>
          )}
        </div>
      )}

      {phase === "done" && result && (
        <div className="text-sm border rounded p-4 bg-gray-50 text-gray-900 flex flex-col gap-4">
          <p
            className={`border rounded p-2 ${STATUS_STYLES[result.status] ?? "border-gray-200"}`}
            role={result.status === "failed" ? "alert" : "status"}
          >
            <strong>{STATUS_LABELS[result.status] ?? result.status}:</strong> {result.message}
          </p>
          <p className="text-gray-500 text-xs">
            Run ID: {result.run_id}
            {result.research_rounds !== null && <> | Research rounds: {result.research_rounds}</>}
          </p>

          {result.warnings && result.warnings.length > 0 && (
            <details className="text-amber-700 bg-amber-50 border border-amber-200 rounded p-2">
              <summary className="cursor-pointer font-semibold">Warnings ({result.warnings.length})</summary>
              <ul className="list-disc list-inside mt-1">
                {result.warnings.map((w, i) => <li key={i}>{w}</li>)}
              </ul>
            </details>
          )}

          {result.report && <ReportView report={result.report} />}

          {result.plan && (
            <details>
              <summary className="cursor-pointer font-semibold">
                Raw evidence by research question
              </summary>
              <div className="flex flex-col gap-3 mt-2">
                <p><strong>Objective:</strong> {result.plan.objective}</p>
                {result.plan.research_questions.map((q, i) => (
                  <div key={i} className="border-l-2 border-gray-300 pl-3">
                    <p className="font-medium">
                      {q}
                      {result.source_decisions?.[q] && (
                        <span className="text-gray-500 font-normal">
                          {" "}[{result.source_decisions[q].join(", ")}]
                        </span>
                      )}
                    </p>
                    {evidenceForQuestion(q).length > 0 ? (
                      <ul className="list-disc list-inside mt-1 flex flex-col gap-1">
                        {evidenceForQuestion(q).map((ev, j) => (
                          <li key={j}>
                            <span className="text-gray-400 uppercase text-xs mr-1">
                              {ev.source_type}
                            </span>
                            {ev.claim}{" "}
                            <a
                              href={ev.source_url}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="text-blue-600 underline"
                            >
                              [{ev.source_title || "source"}]
                            </a>
                          </li>
                        ))}
                      </ul>
                    ) : (
                      <p className="text-gray-500 mt-1">No evidence gathered.</p>
                    )}
                  </div>
                ))}
              </div>
            </details>
          )}
        </div>
      )}
    </div>
  );
}
