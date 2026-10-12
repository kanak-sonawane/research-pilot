"use client";

import { useState } from "react";
import ReportView, { type Report } from "@/components/ReportView";

type RunStatus = "idle" | "loading" | "success" | "error";

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

const API_BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL || "http://localhost:8000";

export default function ResearchForm() {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<RunStatus>("idle");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [result, setResult] = useState<ResearchRunResponse | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

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
          disabled={status === "loading"}
        />
        <button
          type="submit"
          disabled={status === "loading"}
          className="rounded bg-black px-4 py-2 text-white disabled:opacity-50"
        >
          {status === "loading" ? "Researching..." : "Start Research"}
        </button>
      </form>

      {status === "error" && (
        <p className="text-red-600 text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      {status === "success" && result && (
        <div className="text-sm border rounded p-4 bg-gray-50 text-gray-900 flex flex-col gap-4">
          <p><strong>Status:</strong> {result.status}</p>
          <p><strong>Run ID:</strong> {result.run_id}</p>
          {result.research_rounds !== null && (
            <p>
              <strong>Research rounds:</strong> {result.research_rounds}
              {result.sufficient !== null && (
                <span className="text-gray-500">
                  {" "}({result.sufficient ? "evidence judged sufficient" : "some questions unanswered or round limit reached"})
                </span>
              )}
            </p>
          )}

          {result.warnings && result.warnings.length > 0 && (
            <div className="text-amber-700 bg-amber-50 border border-amber-200 rounded p-2">
              <strong>Warnings:</strong>
              <ul className="list-disc list-inside mt-1">
                {result.warnings.map((w, i) => <li key={i}>{w}</li>)}
              </ul>
            </div>
          )}

          {result.status === "failed" && (
            <p className="text-red-600">{result.message}</p>
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
