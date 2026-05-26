"use client";

import { useEffect, useState } from "react";

interface JobCounts {
  pending: number;
  running: number;
  complete: number;
  failed: number;
}

const POLL_INTERVAL_MS = 3000;

export function StatusBar() {
  const [counts, setCounts] = useState<JobCounts | null>(null);

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;

    async function tick() {
      try {
        const res = await fetch("/api/status", { cache: "no-store" });
        if (!cancelled && res.ok) {
          setCounts(await res.json());
        }
      } catch {
        // Network errors are expected when the dev server reloads — ignore.
      }
      if (!cancelled) timer = setTimeout(tick, POLL_INTERVAL_MS);
    }

    tick();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, []);

  if (!counts) {
    return <span className="text-xs text-neutral-400">…</span>;
  }

  const active = counts.pending + counts.running;

  return (
    <div className="flex items-center gap-3 text-xs">
      {active > 0 ? (
        <span className="flex items-center gap-1.5 text-yellow-600 dark:text-yellow-400">
          <span className="inline-block w-2 h-2 rounded-full bg-yellow-500 animate-pulse" />
          {counts.running} running, {counts.pending} pending
        </span>
      ) : (
        <span className="flex items-center gap-1.5 text-green-600 dark:text-green-400">
          <span className="inline-block w-2 h-2 rounded-full bg-green-500" />
          idle
        </span>
      )}
      <span className="text-neutral-500">{counts.complete} done</span>
      {counts.failed > 0 && (
        <span className="text-red-600 dark:text-red-400">
          {counts.failed} failed
        </span>
      )}
    </div>
  );
}
