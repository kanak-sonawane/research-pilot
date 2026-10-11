import ollama

from app.config import OLLAMA_MODEL


class LLMError(Exception):
    """Raised when the LLM call fails or returns something unusable."""


def call_llm(system_prompt: str, user_prompt: str) -> str:
    """
    Thin wrapper around ollama.chat.

    Kept intentionally dumb (no retries, no streaming) for Phase 2 —
    this is the single choke point every future LLM call routes through,
    so retry/timeout/logging behavior can be added here later without
    touching call sites.
    """
    try:
        response = ollama.chat(
            model=OLLAMA_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        )
        return response["message"]["content"]
    except Exception as e:
        raise LLMError(f"LLM call failed: {e}") from e
