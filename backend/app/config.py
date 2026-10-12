import os

from dotenv import load_dotenv

load_dotenv()


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen3:8b")
TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")

# Qwen3 "reasons" before answering by default. Those hidden tokens are slow to
# generate and our tasks (extraction, routing, short JSON) don't need them.
# Set OLLAMA_THINK=true in .env to turn reasoning back on.
OLLAMA_THINK = _env_bool("OLLAMA_THINK", False)

# Safety cap on tokens generated per LLM call (stops runaway generations).
OLLAMA_MAX_TOKENS = int(os.getenv("OLLAMA_MAX_TOKENS", "2048"))

# How many LLM calls may be in flight at once. A single local GPU doesn't
# speed up with parallel requests, so the default is 1.
OLLAMA_CONCURRENCY = max(1, int(os.getenv("OLLAMA_CONCURRENCY", "1")))

# Extra research rounds allowed after the first.
MAX_RESEARCH_ROUNDS = int(os.getenv("MAX_RESEARCH_ROUNDS", "1"))
