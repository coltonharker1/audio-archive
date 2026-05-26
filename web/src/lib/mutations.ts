import { getWriteDb } from "./db";

const RETRIES_BY_TYPE: Record<string, number> = {
  prep: 3,
  transcribe: 2,
  summarize: 2,
};

export type JobType = "prep" | "transcribe" | "summarize";

export function updateContext(recordingId: number, context: string): void {
  const db = getWriteDb();
  db.prepare(
    `UPDATE recordings
     SET context = NULLIF(?, ''),
         updated_at = datetime('now')
     WHERE id = ?`
  ).run(context, recordingId);
}

export function setApproval(recordingId: number, approved: boolean): void {
  const db = getWriteDb();
  if (approved) {
    db.prepare(
      `UPDATE recordings SET approved_at = datetime('now') WHERE id = ?`
    ).run(recordingId);
  } else {
    db.prepare(
      `UPDATE recordings SET approved_at = NULL WHERE id = ?`
    ).run(recordingId);
  }
}

export function enqueueJob(
  recordingId: number,
  type: JobType,
  model?: string
): number {
  const db = getWriteDb();
  const maxRetries = RETRIES_BY_TYPE[type] || 3;
  const result = db
    .prepare(
      `INSERT INTO jobs (recording_id, type, status, max_retries, model)
       VALUES (?, ?, 'pending', ?, NULLIF(?, ''))`
    )
    .run(recordingId, type, maxRetries, model || "");
  return result.lastInsertRowid as number;
}

export function enqueueStages(
  recordingId: number,
  stages: JobType[],
  model?: string
): number[] {
  return stages.map((s) =>
    enqueueJob(recordingId, s, s === "transcribe" ? model : undefined)
  );
}

export function updateTranscriptText(
  transcriptId: number,
  fullText: string,
  segments: { start: number; end: number; text: string }[] | null
): void {
  const db = getWriteDb();
  db.prepare(
    `UPDATE transcripts
     SET full_text = ?,
         segments = ?
     WHERE id = ?`
  ).run(
    fullText,
    segments ? JSON.stringify(segments) : null,
    transcriptId
  );
}
