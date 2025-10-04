"use client";
import { useState, useEffect } from "react";

type StartResp = { jobId: string };
type StatusResp = {
  state: "Queued" | "Running" | "Done" | "Error";
  result?: {
    summary: string;
    decisions: string[];
    actionItems: string[];
    risks: string[];
  };
  error?: string;
};

const API = process.env.NEXT_PUBLIC_API_BASE_URL ?? "http://localhost:5299";

export default function Page() {
  const [text, setText] = useState("");
  const [jobId, setJobId] = useState<string | null>(null);
  const [status, setStatus] = useState<StatusResp | null>(null);
  const [loading, setLoading] = useState(false);

  async function start() {
    setLoading(true);
    setStatus(null);
    setJobId(null);
    const resp = await fetch(`${API}/api/summary/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    const data: StartResp = await resp.json();
    setJobId(data.jobId);
    setLoading(false);
  }

  useEffect(() => {
    if (!jobId) return;
    const t = setInterval(async () => {
      const r = await fetch(`${API}/api/summary/status/${jobId}`);
      const s: StatusResp = await r.json();
      setStatus(s);
      if (s.state === "Done" || s.state === "Error") clearInterval(t);
    }, 1000);
    return () => clearInterval(t);
  }, [jobId]);

  return (
    <main className="mx-auto max-w-3xl p-6 space-y-6">
      <h1 className="text-2xl font-semibold">Streszczacz Notatek</h1>

      <div className="space-y-2">
        <label className="block text-sm font-medium">Wklej tekst</label>
        <textarea
          className="w-full min-h-[180px] rounded border border-neutral-300 p-3 focus:outline-none focus:ring-2 focus:ring-blue-500"
          value={text}
          onChange={e => setText(e.target.value)}
          placeholder="Wklej notatki lub transkrypt..."
        />
        <button
          onClick={start}
          disabled={loading || text.trim().length < 20}
          className="rounded bg-blue-600 px-4 py-2 text-white disabled:opacity-50"
        >
          {loading ? "Wysyłanie..." : "Streszcz"}
        </button>
      </div>

      {jobId && <p className="text-sm text-neutral-600">jobId: {jobId}</p>}

      {status && (
        <section className="rounded border border-neutral-200 p-4 space-y-3 bg-white">
          <div className="text-sm">
            Status: <span className="font-medium">{status.state}</span>
            {status.error && <span className="text-red-600"> — {status.error}</span>}
          </div>
          {status.result && (
            <>
              <div>
                <h2 className="font-semibold">Podsumowanie</h2>
                <p className="whitespace-pre-wrap">{status.result.summary}</p>
              </div>
              <div>
                <h2 className="font-semibold">Decyzje</h2>
                <ul className="list-disc pl-6">
                  {status.result.decisions.map((d, i) => <li key={i}>{d}</li>)}
                </ul>
              </div>
              <div>
                <h2 className="font-semibold">Action items</h2>
                <ul className="list-disc pl-6">
                  {status.result.actionItems.map((d, i) => <li key={i}>{d}</li>)}
                </ul>
              </div>
              <div>
                <h2 className="font-semibold">Ryzyka</h2>
                <ul className="list-disc pl-6">
                  {status.result.risks.map((d, i) => <li key={i}>{d}</li>)}
                </ul>
              </div>
            </>
          )}
        </section>
      )}
    </main>
  );
}
