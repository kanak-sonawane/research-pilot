"use client";

export interface ReportFinding {
  statement: string;
  evidence_ids: string[];
}
export interface FindingsSubsection {
  heading: string;
  findings: ReportFinding[];
}
export interface ArchitectureGroup {
  name: string;
  description: string;
  items: string[];
}
export interface ReportEvidence {
  id: string;
  claim: string;
  quote: string;
  question: string;
  source_id: string;
  source_type: string;
}
export interface ReportSource {
  id: string;
  title: string;
  url: string;
  source_types: string[];
}
export interface Methodology {
  objective: string;
  research_questions: string[];
  source_categories_searched: string[];
  source_categories_with_evidence: string[];
  tools_used: string[];
  search_strategy: string;
  source_selection_approach: string;
  research_rounds: number;
  limitations: string[];
}
export interface ValidationResult {
  passed: boolean;
  issues: string[];
  dropped_findings: number;
}
export interface Report {
  findings: FindingsSubsection[];
  information_architecture: ArchitectureGroup[];
  methodology: Methodology;
  sources: ReportSource[];
  evidence: ReportEvidence[];
  unanswered_questions: string[];
  validation: ValidationResult;
}

export default function ReportView({ report }: { report: Report }) {
  const evidenceById = new Map(report.evidence.map((e) => [e.id, e]));
  const sourceById = new Map(report.sources.map((s) => [s.id, s]));

  return (
    <article className="flex flex-col gap-6">
      {report.validation.passed ? (
        <p className="text-green-800 bg-green-50 border border-green-200 rounded p-2">
          Report validation passed: every finding cites stored evidence, and every citation maps to a source.
        </p>
      ) : (
        <div className="text-amber-800 bg-amber-50 border border-amber-200 rounded p-2">
          <strong>Report validation notes</strong>
          <ul className="list-disc list-inside mt-1">
            {report.validation.issues.map((issue, i) => (
              <li key={i}>{issue}</li>
            ))}
          </ul>
        </div>
      )}

      <section>
        <h2 className="text-lg font-semibold mb-2">1. Findings</h2>
        {report.findings.length === 0 ? (
          <p className="text-gray-600">No findings supported by evidence were produced.</p>
        ) : (
          report.findings.map((sub, i) => (
            <div key={i} className="mb-4">
              <h3 className="font-semibold mb-1">{sub.heading}</h3>
              <ul className="flex flex-col gap-2">
                {sub.findings.map((f, j) => {
                  const sourceIds = Array.from(
                    new Set(
                      f.evidence_ids
                        .map((id) => evidenceById.get(id)?.source_id)
                        .filter((x): x is string => Boolean(x))
                    )
                  );
                  return (
                    <li key={j} className="list-disc ml-5">
                      {f.statement}{" "}
                      {sourceIds.map((sid) => (
                        <a key={sid} href={`#source-${sid}`} className="text-blue-600 underline mr-1">
                          [{sid}]
                        </a>
                      ))}
                      <details className="text-gray-700">
                        <summary className="cursor-pointer text-xs">
                          Evidence ({f.evidence_ids.length})
                        </summary>
                        <ul className="mt-1 ml-4 list-disc">
                          {f.evidence_ids.map((id) => {
                            const ev = evidenceById.get(id);
                            if (!ev) return null;
                            const src = sourceById.get(ev.source_id);
                            return (
                              <li key={id} className="text-xs">
                                <strong>{id}</strong> ({ev.source_type}): {ev.claim}{" "}
                                {src && (
                                  <a
                                    href={src.url}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="text-blue-600 underline"
                                  >
                                    [{src.title}]
                                  </a>
                                )}
                                {ev.quote && <div className="italic text-gray-500">&ldquo;{ev.quote}&rdquo;</div>}
                              </li>
                            );
                          })}
                        </ul>
                      </details>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))
        )}
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-2">2. Information Architecture</h2>
        {report.information_architecture.length === 0 ? (
          <p className="text-gray-600">Not available.</p>
        ) : (
          <ul className="flex flex-col gap-3">
            {report.information_architecture.map((g, i) => (
              <li key={i}>
                <strong>{g.name}</strong>
                {g.description && <span>: {g.description}</span>}
                {g.items.length > 0 && (
                  <ul className="list-disc ml-6 mt-1">
                    {g.items.map((item, j) => (
                      <li key={j}>{item}</li>
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-2">3. Research Methodology / Approach</h2>
        <div className="flex flex-col gap-2">
          <p><strong>Objective:</strong> {report.methodology.objective}</p>
          <p><strong>Strategy:</strong> {report.methodology.search_strategy}</p>
          <p><strong>Source selection:</strong> {report.methodology.source_selection_approach}</p>
          <p>
            <strong>Source categories searched:</strong>{" "}
            {report.methodology.source_categories_searched.join(", ") || "none"}
            {" | "}
            <strong>with evidence:</strong>{" "}
            {report.methodology.source_categories_with_evidence.join(", ") || "none"}
          </p>
          <div>
            <strong>Tools used</strong>
            <ul className="list-disc ml-6">
              {report.methodology.tools_used.map((t, i) => (
                <li key={i}>{t}</li>
              ))}
            </ul>
          </div>
          <div>
            <strong>Limitations</strong>
            <ul className="list-disc ml-6">
              {report.methodology.limitations.map((l, i) => (
                <li key={i}>{l}</li>
              ))}
            </ul>
          </div>
          {report.unanswered_questions.length > 0 && (
            <div>
              <strong>Unanswered questions</strong>
              <ul className="list-disc ml-6">
                {report.unanswered_questions.map((q, i) => (
                  <li key={i}>{q}</li>
                ))}
              </ul>
            </div>
          )}
        </div>
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-2">4. Sources &amp; Citations</h2>
        {report.sources.length === 0 ? (
          <p className="text-gray-600">No sources.</p>
        ) : (
          <ol className="flex flex-col gap-1">
            {report.sources.map((s) => (
              <li key={s.id} id={`source-${s.id}`}>
                <strong>[{s.id}]</strong>{" "}
                <a href={s.url} target="_blank" rel="noopener noreferrer" className="text-blue-600 underline">
                  {s.title}
                </a>{" "}
                <span className="text-gray-500 text-xs uppercase">{s.source_types.join(", ")}</span>
              </li>
            ))}
          </ol>
        )}
      </section>
    </article>
  );
}
