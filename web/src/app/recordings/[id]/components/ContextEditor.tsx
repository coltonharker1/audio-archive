"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";

interface Props {
  recordingId: number;
  initialContext: string;
}

export function ContextEditor({ recordingId, initialContext }: Props) {
  const [context, setContext] = useState(initialContext);
  const [savedContext, setSavedContext] = useState(initialContext);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const router = useRouter();

  const dirty = context !== savedContext;

  async function save(alsoSummarize: boolean) {
    setError(null);
    try {
      const patchRes = await fetch(`/api/recordings/${recordingId}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ context }),
      });
      if (!patchRes.ok) throw new Error(`save failed: ${patchRes.status}`);

      if (alsoSummarize) {
        const jobRes = await fetch(`/api/recordings/${recordingId}/jobs`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ stages: ["summarize"] }),
        });
        if (!jobRes.ok) throw new Error(`enqueue failed: ${jobRes.status}`);
      }

      setSavedContext(context);
      startTransition(() => router.refresh());
    } catch (e) {
      setError(e instanceof Error ? e.message : "unknown error");
    }
  }

  return (
    <div className="space-y-2">
      <textarea
        value={context}
        onChange={(e) => setContext(e.target.value)}
        rows={6}
        placeholder="Add background context for the LLM (e.g. who the speaker is, where this was recorded, what tape collection it's from). Saved context is prepended to the summarization prompt."
        className="w-full rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 px-3 py-2 text-sm font-mono"
      />
      <div className="flex items-center gap-2">
        <button
          onClick={() => save(false)}
          disabled={!dirty || pending}
          className="px-3 py-1.5 text-sm rounded bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 disabled:opacity-40 disabled:cursor-not-allowed"
        >
          Save
        </button>
        <button
          onClick={() => save(true)}
          disabled={pending}
          className="px-3 py-1.5 text-sm rounded border border-neutral-300 dark:border-neutral-700 hover:bg-neutral-50 dark:hover:bg-neutral-900 disabled:opacity-40"
        >
          Save & re-summarize
        </button>
        {dirty && (
          <span className="text-xs text-yellow-600 dark:text-yellow-400">
            unsaved changes
          </span>
        )}
        {error && (
          <span className="text-xs text-red-600 dark:text-red-400">{error}</span>
        )}
      </div>
    </div>
  );
}
