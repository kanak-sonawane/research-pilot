"use client";
import { useState } from "react";

export default function Home() {
  const [status, setStatus] = useState<string>("idle");

  const checkBackend = async () => {
    setStatus("loading");
    try {
      const res = await fetch("http://localhost:8000/health");
      const data = await res.json();
      setStatus(`backend says: ${data.status}`);
    } catch (err) {
      setStatus("backend unreachable");
    }
  };

  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-4">
      <h1 className="text-2xl font-semibold">Research Agent — Phase 0 Test</h1>
      <button
        onClick={checkBackend}
        className="rounded bg-black px-4 py-2 text-white"
      >
        Check backend connection
      </button>
      <p>{status}</p>
    </main>
  );
}