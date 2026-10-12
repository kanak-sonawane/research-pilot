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
