#!/usr/bin/env bash
set -e

# Phase 7 JSON robustness fix.
# Run from the root of your research-pilot/ project, after phase7_setup.sh
# and phase7_speed_fix.sh.
#
# Problem: the model sometimes returns malformed JSON (for example an
# unescaped double quote inside a copied "quote" value). One bad reply
# discarded all evidence for that question, and a bad reply for the
# information architecture silently degraded that report section.
#
# Fix:
#   1. New call_llm_json(): calls the LLM and parses JSON; if the reply is
#      malformed it asks ONCE more, telling the model what went wrong.
#      (A retry costs time only when a reply was actually malformed.)
#   2. Evidence extraction, findings synthesis and information architecture
#      use it.
#   3. The evidence prompt now forbids double quotes inside text values.
#   4. When the information architecture fails, the report now says WHY.

echo "Applying Phase 7 JSON robustness fix..."

cat > backend/app/llm_json.py << 'EOF'
from app.json_utils import extract_json_object
from app.llm_service import call_llm

_RETRY_NOTE = (
    "\n\nIMPORTANT: your previous reply could not be parsed as JSON ({error}). "
    "Reply again with ONLY the JSON object. Do not put double-quote characters or "
    "backslashes inside text values; use single quotes instead."
)


def call_llm_json(system_prompt: str, user_prompt: str, retries: int = 1) -> dict:
    """
    Calls the LLM and parses a JSON object from its reply. If the reply is
    malformed, asks again (up to `retries` more times) with a note about
    the parse error.

    - An LLM outage (LLMError) is NOT retried here; it propagates.
    - Raises ValueError if every attempt returned unparseable JSON.
    """
    prompt = user_prompt
    last_error = "unknown error"

    for _ in range(retries + 1):
        raw = call_llm(system_prompt, prompt)
        try:
            return extract_json_object(raw)
        except ValueError as e:
            last_error = str(e)
            prompt = user_prompt + _RETRY_NOTE.format(error=last_error[:100])

    raise ValueError(last_error)
EOF

python3 - << 'PYEOF'
def patch(path, replacements):
    with open(path) as f:
        content = f.read()
    for old, new in replacements:
        if old not in content:
            raise SystemExit(f"PATCH FAILED in {path}: could not find:\n{old}")
        content = content.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(content)
    print(f"patched {path}")


patch("backend/app/web_research.py", [
    (
        "from app.json_utils import extract_json_object\n",
        "from app.json_utils import extract_json_object\nfrom app.llm_json import call_llm_json\n",
    ),
    (
        "- If none of the results are relevant, return an empty evidence list.",
        "- Never put double-quote characters or backslashes inside the claim or quote text; use single\n"
        "  quotes instead.\n"
        "- If none of the results are relevant, return an empty evidence list.",
    ),
    (
        "    try:\n"
        "        raw = call_llm(EVIDENCE_SYSTEM_PROMPT, user_prompt)\n"
        "    except LLMError as e:\n"
        "        raise ResearchError(f\"Evidence extraction LLM call failed: {e}\") from e\n"
        "\n"
        "    try:\n"
        "        parsed = extract_json_object(raw)\n"
        "    except ValueError as e:\n"
        "        raise ResearchError(f\"Could not parse evidence output: {e}\") from e\n",
        "    try:\n"
        "        parsed = call_llm_json(EVIDENCE_SYSTEM_PROMPT, user_prompt)\n"
        "    except LLMError as e:\n"
        "        raise ResearchError(f\"Evidence extraction LLM call failed: {e}\") from e\n"
        "    except ValueError as e:\n"
        "        raise ResearchError(f\"Could not parse evidence output after retry: {e}\") from e\n",
    ),
])

patch("backend/app/report.py", [
    (
        "from app.json_utils import extract_json_object\n",
        "from app.json_utils import extract_json_object\nfrom app.llm_json import call_llm_json\n",
    ),
    (
        "    raw = call_llm(FINDINGS_SYSTEM_PROMPT, f\"Objective: {objective}\\n\\nEvidence:\\n{evidence_block}\")\n"
        "    parsed = extract_json_object(raw)\n",
        "    parsed = call_llm_json(FINDINGS_SYSTEM_PROMPT, f\"Objective: {objective}\\n\\nEvidence:\\n{evidence_block}\")\n",
    ),
    (
        "    raw = call_llm(ARCHITECTURE_SYSTEM_PROMPT, f\"Objective: {objective}\\n\\nFindings:\\n{findings_block}\")\n"
        "    parsed = extract_json_object(raw)\n",
        "    parsed = call_llm_json(ARCHITECTURE_SYSTEM_PROMPT, f\"Objective: {objective}\\n\\nFindings:\\n{findings_block}\")\n",
    ),
    (
        "                \"Information architecture generation failed; groups shown are the findings headings.\"\n",
        "                f\"Information architecture generation failed ({str(e)[:120]}); groups shown are the findings headings.\"\n",
    ),
])
PYEOF

echo ""
echo "Done. Restart the backend (no new dependencies)."
echo "If a report still says 'Information architecture generation failed', the"
echo "validation note now includes the reason; paste it back."
