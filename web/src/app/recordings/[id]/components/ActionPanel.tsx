"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";

interface Props {
  recordingId: number;
}

const MODELS = ["base", "small", "medium", "large-v3"] as const;
type Model = (typeof MODELS)[number];

type Stage = "prep" | "transcribe" | "summarize";

export function ActionPanel({ recordingId }: Props) {
  const [model, setModel] = useState<Model>("base");
  const [estimate, setEstimate] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const [busy, setBusy] = useState<Stage | "all" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const router = useRouter();

  useEffect(() => {
    let cancelled = false;
    setEstimate(null);
    fetch(
      `/api/recordings/${recordingId}/estimate?stages=transcribe&model=${model}`
    )
      .then((r) => r.json())
      .then((data) => {
        if (!cancelled && data.totalFormatted) {
          setEstimate(data.totalFormatted);
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [recordingId, model]);

  async function enqueue(stages: Stage[], label: Stage | "all") {
    setError(null);
    setBusy(label);
    try {
      const res = await fetch(`/api/recordings/${recordingId}/jobs`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          stages,
          model: stages.includes("transcribe") ? model : undefined,
        }),
      });
      if (!res.ok) throw new Error(`enqueue failed: ${res.status}`);
      startTransition(() => router.refresh());
    } catch (e) {
      setError(e instanceof Error ? e.message : "unknown");
    } finally {
      setBusy(null);
    }
  }

  const disabled = busy !== null || pending;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <button
          onClick={() => enqueue(["prep"], "prep")}
          disabled={disabled}
          className="px-3 py-1.5 text-sm rounded border border-neutral-300 dark:border-neutral-700 hover:bg-neutral-50 dark:hover:bg-neutral-900 disabled:opacity-40"
        >
          {busy === "prep" ? "Enqueuing…" : "Re-prep"}
        </button>
        <button
          onClick={() => enqueue(["transcribe"], "transcribe")}
          disabled={disabled}
          className="px-3 py-1.5 text-sm rounded border border-neutral-300 dark:border-neutral-700 hover:bg-neutral-50 dark:hover:bg-neutral-900 disabled:opacity-40"
        >
          {busy === "transcribe" ? "Enqueuing…" : "Re-transcribe"}
        </button>
        <select
          value={model}
          onChange={(e) => setModel(e.target.value as Model)}
          disabled={disabled}
          className="px-2 py-1.5 text-sm rounded border border-neutral-300 dark:border-neutral-700 bg-white dark:bg-neutral-900"
        >
          {MODELS.map((m) => (
            <option key={m} value={m}>
              {m}
            </option>
          ))}
        </select>
        <span className="text-xs text-neutral-500">
          {estimate ? `~${estimate}` : "…"}
        </span>
        <button
          onClick={() => enqueue(["summarize"], "summarize")}
          disabled={disabled}
          className="px-3 py-1.5 text-sm rounded border border-neutral-300 dark:border-neutral-700 hover:bg-neutral-50 dark:hover:bg-neutral-900 disabled:opacity-40"
        >
          {busy === "summarize" ? "Enqueuing…" : "Re-summarize"}
        </button>
        <button
          onClick={() => enqueue(["prep", "transcribe", "summarize"], "all")}
          disabled={disabled}
          className="ml-auto px-3 py-1.5 text-sm rounded bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 disabled:opacity-40"
        >
          {busy === "all" ? "Enqueuing…" : "Re-process all"}
        </button>
      </div>
      {error && (
        <div className="text-xs text-red-600 dark:text-red-400">{error}</div>
      )}
    </div>
  );
}
