import re
import threading
import time

import ollama

from app.config import (
    OLLAMA_CONCURRENCY,
    OLLAMA_MAX_TOKENS,
    OLLAMA_MODEL,
    OLLAMA_THINK,
)


class LLMError(Exception):
    """Raised when the LLM call fails or returns something unusable."""


# Limits simultaneous calls into Ollama. Extra threads wait here instead of
# piling onto the server (which can allocate extra memory per parallel slot).
_slots = threading.Semaphore(OLLAMA_CONCURRENCY)

_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL)
_THINK_UNCLOSED = re.compile(r"<think>.*", re.DOTALL)


def _get(obj, name, default=None):
    """Reads a field from an ollama response whether it behaves like a dict or an object."""
    try:
        value = obj[name]
    except Exception:
        value = getattr(obj, name, default)
    return default if value is None else value


def _chat(messages):
    options = {"num_predict": OLLAMA_MAX_TOKENS}

    if OLLAMA_THINK:
        return ollama.chat(model=OLLAMA_MODEL, messages=messages, options=options)

    try:
        return ollama.chat(model=OLLAMA_MODEL, messages=messages, options=options, think=False)
    except (TypeError, ollama.ResponseError):
        # Older client/server without the `think` option: use Qwen3's
        # soft switch in the prompt instead.
        fallback = [dict(m) for m in messages]
        fallback[-1]["content"] = fallback[-1]["content"] + " /no_think"
        return ollama.chat(model=OLLAMA_MODEL, messages=fallback, options=options)


def call_llm(system_prompt: str, user_prompt: str) -> str:
    """
    Single choke point for every Ollama call.

    Prints one timing line per call, for example:
      [llm] 'You are a research evidence extraction assistant.': 41.2s run, 0.0s queued, in=1510 out=402 tok (9.8 tok/s)
    'out' is the number of tokens the model generated; if it is far larger
    than the visible answer, the model is spending time on hidden reasoning.
    """
    first_line = system_prompt.strip().splitlines()[0] if system_prompt.strip() else "llm"
    label = first_line[:60]

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]

    waiting_since = time.perf_counter()
    with _slots:
        started = time.perf_counter()
        try:
            response = _chat(messages)
        except Exception as e:
            raise LLMError(f"LLM call failed: {e}") from e
        finished = time.perf_counter()

    message = _get(response, "message")
    content = _get(message, "content", "") or ""
    content = _THINK_BLOCK.sub("", content)
    content = _THINK_UNCLOSED.sub("", content).strip()

    run_seconds = finished - started
    out_tokens = _get(response, "eval_count", 0)
    in_tokens = _get(response, "prompt_eval_count", 0)
    rate = (out_tokens / run_seconds) if run_seconds > 0 and out_tokens else 0.0
    truncated = " TRUNCATED(hit token cap)" if _get(response, "done_reason", "") == "length" else ""
    print(
        f"[llm] {label!r}: {run_seconds:.1f}s run, {started - waiting_since:.1f}s queued, "
        f"in={in_tokens} out={out_tokens} tok ({rate:.1f} tok/s){truncated}",
        flush=True,
    )

    return content
