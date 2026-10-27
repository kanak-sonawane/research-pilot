"use client";

export interface RunProgress {
  stage: string;
  stage_label: string;
  round: number;
  elapsed_seconds: number;
}

const STEPS = [
  { key: "planning", label: "Planning the research" },
  { key: "routing", label: "Choosing sources" },
  { key: "researching", label: "Searching sources" },
  { key: "evaluating", label: "Checking the evidence" },
  { key: "reporting", label: "Writing the report" },
];

function formatElapsed(totalSeconds: number): string {
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return minutes > 0 ? `${minutes}m ${seconds}s` : `${seconds}s`;
}

export default function ResearchProgress({ progress }: { progress: RunProgress }) {
  const currentIndex = STEPS.findIndex((s) => s.key === progress.stage);

  return (
    <div
      role="status"
      aria-live="polite"
      className="border rounded p-3 bg-white text-gray-900 text-sm flex flex-col gap-2"
    >
      <p className="font-medium">
        Research in progress
        <span className="text-gray-500 font-normal"> ({formatElapsed(progress.elapsed_seconds)} elapsed)</span>
      </p>

      <ol className="flex flex-col gap-1">
        {STEPS.map((step, i) => {
          const state = i < currentIndex ? "done" : i === currentIndex ? "active" : "pending";
          return (
            <li
              key={step.key}
              className={
                state === "active"
                  ? "font-semibold text-gray-900"
                  : state === "done"
                  ? "text-green-700"
                  : "text-gray-400"
              }
            >
              <span aria-hidden="true">{state === "done" ? "✓" : state === "active" ? "…" : "○"}</span>{" "}
              {step.label}
              {state === "active" && progress.round > 1 && (
                <span className="font-normal text-gray-500"> (round {progress.round}, follow-up questions)</span>
              )}
            </li>
          );
        })}
      </ol>

      <p className="text-gray-500 text-xs">
        Research on a local model can take a few minutes. Keep this page open.
      </p>
    </div>
  );
}
