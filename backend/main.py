from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import router
import ollama

app = FastAPI(title="Research Agent API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/health/llm")
def health_llm():
    try:
        response = ollama.chat(
            model="qwen3:8b",
            messages=[{"role": "user", "content": "Reply with just: pong"}],
        )
        return {"status": "ok", "model": "qwen3:8b", "reply": response["message"]["content"]}
    except Exception as e:
        return {"status": "error", "detail": str(e)}
app.include_router(router)
