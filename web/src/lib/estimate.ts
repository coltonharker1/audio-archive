import { getDb } from "./db";

const FALLBACK_REALTIME = {
  base: 30,
  small: 20,
  medium: 14,
  "large-v3": 4,
} as const;

const PREP_REALTIME = 40;
const SUMMARIZE_SECONDS = 60;

export type Stage = "prep" | "transcribe" | "summarize";

export function estimateSeconds(
  stage: Stage,
  durationMs: number | null,
  model = "base"
): number {
  const audioSeconds = (durationMs || 0) / 1000;

  if (stage === "prep") return Math.max(5, audioSeconds / PREP_REALTIME);
  if (stage === "summarize") return SUMMARIZE_SECONDS;

  const factor = realtimeFromHistory(model) || fallback(model);
  return Math.max(10, audioSeconds / factor);
}

function fallback(model: string): number {
  return (
    FALLBACK_REALTIME[model as keyof typeof FALLBACK_REALTIME] ||
    FALLBACK_REALTIME.base
  );
}

function realtimeFromHistory(model: string): number | null {
  const db = getDb();
  const row = db
    .prepare(
      `SELECT
         SUM(r.duration_ms) AS audio_ms,
         SUM((julianday(j.finished_at) - julianday(j.started_at)) * 86400000) AS run_ms
       FROM jobs j
       JOIN recordings r ON r.id = j.recording_id
       WHERE j.type = 'transcribe'
         AND j.status = 'complete'
         AND j.started_at IS NOT NULL
         AND j.finished_at IS NOT NULL
         AND COALESCE(j.model, '') = ?
       ORDER BY j.id DESC
       LIMIT 20`
    )
    .get(model === "base" ? "" : model) as {
    audio_ms: number | null;
    run_ms: number | null;
  };

  if (!row?.audio_ms || !row?.run_ms || row.run_ms <= 0) return null;
  return row.audio_ms / row.run_ms;
}

export function formatEstimate(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const min = Math.floor(seconds / 60);
  const sec = Math.round(seconds % 60);
  if (sec === 0) return `${min}m`;
  return `${min}m ${sec}s`;
}
