import { getDb } from "./db";
import type {
  Recording,
  Job,
  Transcript,
  Summary,
  JobCounts,
} from "./types";

export function getRecordings(): Recording[] {
  const db = getDb();
  return db
    .prepare("SELECT * FROM recordings ORDER BY id DESC")
    .all() as Recording[];
}

export function getRecording(id: number): Recording | undefined {
  const db = getDb();
  return db
    .prepare("SELECT * FROM recordings WHERE id = ?")
    .get(id) as Recording | undefined;
}

export function getTranscript(recordingId: number): Transcript | undefined {
  const db = getDb();
  return db
    .prepare(
      "SELECT * FROM transcripts WHERE recording_id = ? ORDER BY id DESC LIMIT 1"
    )
    .get(recordingId) as Transcript | undefined;
}

export function getSummary(recordingId: number): Summary | undefined {
  const db = getDb();
  return db
    .prepare(
      "SELECT * FROM summaries WHERE recording_id = ? ORDER BY id DESC LIMIT 1"
    )
    .get(recordingId) as Summary | undefined;
}

export function getJobs(recordingId: number): Job[] {
  const db = getDb();
  return db
    .prepare(
      "SELECT * FROM jobs WHERE recording_id = ? ORDER BY id DESC"
    )
    .all(recordingId) as Job[];
}

export function getJobCounts(): JobCounts {
  const db = getDb();
  const rows = db
    .prepare(
      "SELECT status, COUNT(*) as count FROM jobs GROUP BY status"
    )
    .all() as { status: string; count: number }[];

  const counts: JobCounts = { pending: 0, running: 0, complete: 0, failed: 0 };
  for (const row of rows) {
    if (row.status in counts) {
      counts[row.status as keyof JobCounts] = row.count;
    }
  }
  return counts;
}

export function getGroupRecordings(groupId: string): Recording[] {
  const db = getDb();
  return db
    .prepare("SELECT * FROM recordings WHERE group_id = ? ORDER BY id")
    .all(groupId) as Recording[];
}

export interface SearchHit {
  recording_id: number;
  snippet: string;
  source: "transcript" | "title" | "speaker" | "metadata";
  title: string | null;
  speaker: string | null;
  date: string | null;
  duration_ms: number | null;
}

interface SearchOptions {
  ftsQuery: string;
  likeQuery: string;
}

export function search({ ftsQuery, likeQuery }: SearchOptions): SearchHit[] {
  const db = getDb();
  const seen = new Map<number, SearchHit>();

  const transcriptHits = db
    .prepare(
      `SELECT t.recording_id,
              snippet(transcripts_fts, 0, '<mark>', '</mark>', '…', 24) AS snippet,
              r.title, r.speaker, r.date, r.duration_ms
       FROM transcripts_fts
       JOIN transcripts t ON t.id = transcripts_fts.rowid
       JOIN recordings r ON r.id = t.recording_id
       WHERE transcripts_fts MATCH ?
       ORDER BY rank
       LIMIT 50`
    )
    .all(ftsQuery) as Omit<SearchHit, "source">[];

  for (const hit of transcriptHits) {
    if (!seen.has(hit.recording_id)) {
      seen.set(hit.recording_id, { ...hit, source: "transcript" });
    }
  }

  const metadataHits = db
    .prepare(
      `SELECT r.id AS recording_id, r.title, r.speaker, r.date, r.duration_ms,
              CASE
                WHEN r.title LIKE ? THEN 'title'
                WHEN r.speaker LIKE ? THEN 'speaker'
                ELSE 'metadata'
              END AS source,
              CASE
                WHEN r.title LIKE ? THEN r.title
                WHEN r.speaker LIKE ? THEN r.speaker
                ELSE COALESCE(s.summary_short, '')
              END AS snippet
       FROM recordings r
       LEFT JOIN summaries s ON s.recording_id = r.id
       WHERE r.title LIKE ?
          OR r.speaker LIKE ?
          OR s.metadata LIKE ?
          OR s.summary_short LIKE ?
       LIMIT 50`
    )
    .all(
      likeQuery, likeQuery, likeQuery, likeQuery,
      likeQuery, likeQuery, likeQuery, likeQuery
    ) as SearchHit[];

  for (const hit of metadataHits) {
    const existing = seen.get(hit.recording_id);
    if (existing) {
      // already have a transcript hit; keep that one but optionally upgrade snippet
      continue;
    }
    seen.set(hit.recording_id, hit);
  }

  return Array.from(seen.values());
}
