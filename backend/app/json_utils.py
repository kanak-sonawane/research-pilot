import json
import re


def extract_json_object(raw_text: str) -> dict:
    """
    Shared defensive JSON extraction, used by every module that asks the
    LLM for structured output (planning, source_decision, web_research).

    Strips ```json fences, then uses json.JSONDecoder().raw_decode() to
    parse just the first complete JSON object starting from the first
    `{`. This is deliberately NOT a regex match to the last `}` in the
    text — a greedy regex grabs any trailing commentary or extra braces
    the model adds after the real JSON, which causes json.loads to fail
    with "Extra data" even though the actual JSON was well-formed.
    raw_decode() stops as soon as one valid JSON value is parsed and
    ignores everything after it.
    """
    text = raw_text.strip()
    text = re.sub(r"^```(?:json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()

    start = text.find("{")
    if start == -1:
        raise ValueError(f"No JSON object found in model output: {raw_text!r}")

    decoder = json.JSONDecoder()
    try:
        obj, _ = decoder.raw_decode(text, start)
    except json.JSONDecodeError as e:
        raise ValueError(f"Could not parse JSON object: {e}") from e

    return obj