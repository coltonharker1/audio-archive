# Remanence Archive Integration — Design Note

> Status: **Future work / north star.** Nothing here is built yet. This document
> captures the design so it's not lost while audio-archive itself is being
> solidified.

## Goal

Let audio-archive push processed recordings (prepared audio + transcript +
structured summary) upstream into [remanence-archive](https://github.com/coltonharker1/remanence-archive),
a Next.js web catalog for digitized analog recordings, so finished work in the
local pipeline becomes browsable on the public site with one command.

The pieces we have on the audio-archive side (prepared audio, transcript,
structured summary metadata) map almost cleanly to the shape of a remanence
`sound` record. There are two real gaps: a transcript/metadata storage gap
on the remanence schema, and an auth gap (remanence uses email-based NextAuth
which doesn't fit a CLI).

## Remanence Archive (as of April 2026)

Reference snapshot of the upstream system so future work here doesn't have
to re-discover it.

**Stack:** Next.js 16 App Router, PostgreSQL via Neon + Drizzle, Cloudflare R2
for audio/image storage, NextAuth v5 (email + Resend), Tailwind v4, React 19.

**Core entity — `sounds` table:**

| Column | Notes |
|---|---|
| `id` | serial PK |
| `catalogNumber` | unique, e.g. `RA-042` (auto-generated via `/api/sounds/next-number`) |
| `title` | string |
| `description` | freeform text |
| `medium` | enum: reel-to-reel variants, cassette, vinyl, 8-track, minidisc, DAT, etc. |
| `whereFound`, `dateFound`, `estimatedRecordingDate` | provenance |
| `tracks` | **JSONB array** — `{ title, audioUrl, downloadUrl, audioFilename, downloadFilename, duration, description }` |
| `images` | **JSONB array** — `{ url, filename, caption }` |
| `imageUrl`, `imageFilename` | thumbnail |
| `totalDuration` | computed from tracks |
| `published` | bool — controls public catalog visibility |
| `createdAt`, `updatedAt` | timestamps |

**Existing API routes (all require admin auth):**

- `GET /api/sounds` — list, including unpublished
- `POST /api/sounds` — create
- `PATCH /api/sounds/[id]` — update metadata/tracks/images
- `DELETE /api/sounds/[id]` — delete sound and R2 files
- `POST /api/upload` — presigned R2 URL for direct browser upload
- `GET /api/sounds/next-number` — next catalog number

**Audio storage:** Cloudflare R2, keyed `audio/{catalogNumber}/...` and
`image/{catalogNumber}/...`. App manages both streaming URLs and original-
quality download URLs.

**What remanence does NOT currently have:**

- No transcript storage
- No structured summary metadata (topics, tags, bible references, etc.)
- No service-account / API-key auth
- No "sync from another system" endpoint

## Field mapping

| audio-archive                            | → | remanence `sounds`                      |
|------------------------------------------|---|------------------------------------------|
| `master_path` (original WAV)             | → | `tracks[].downloadUrl`                   |
| `prep_path` (16kHz mono WAV)             | → | `tracks[].audioUrl` (streaming)          |
| `title`                                  | → | `title`                                  |
| `speaker` + `date`                       | → | part of `description` or metadata        |
| `date`                                   | → | `estimatedRecordingDate`                 |
| `duration_ms`                            | → | `tracks[].duration`, `totalDuration`     |
| summary `summary_long`                   | → | `description` (sound-level)              |
| summary `summary_short`                  | → | top of `description` or metadata field    |
| summary `main_topics`                    | → | **no home yet** — needs JSONB metadata   |
| summary `tags`                           | → | **no home yet**                          |
| summary `bible_references`               | → | **no home yet**                          |
| summary `notable_quotes`                 | → | **no home yet**                          |
| transcript `full_text`                   | → | **no home yet**                          |
| transcript `segments` (timestamped)      | → | **no home yet**                          |

## Two integration paths

### Path A — Minimal (no remanence schema changes)

Flatten everything into `description`. Lose the structured data but ship
something quickly.

```json
POST /api/sounds
{
  "title": "Morning Service",
  "description": "<summary_long>\n\nTopics: ...\n\nKey passages: ...",
  "medium": "reel-to-reel",
  "estimatedRecordingDate": "1968-04-07",
  "tracks": [
    {
      "title": "Morning Service",
      "audioUrl": "<R2 URL for .prep.wav>",
      "downloadUrl": "<R2 URL for master WAV>",
      "duration": 4165,
      "description": "<summary_short>"
    }
  ]
}
```

### Path B — Full fidelity (recommended long-term)

Add a `metadata` JSONB column to `sounds`. Non-breaking since JSONB is
additive and existing code ignores unknown fields.

```sql
-- Migration in remanence
ALTER TABLE sounds ADD COLUMN metadata JSONB DEFAULT '{}';
```

The `metadata` column stores the full structured output from audio-archive:

```json
{
  "source": "audio-archive",
  "audio_archive_id": 4,
  "summary_short": "...",
  "summary_long": "...",
  "main_topics": [...],
  "notable_themes": [...],
  "bible_references": [{"book": "Revelation", "chapter": 13, "verse": 4, "text": "..."}],
  "historical_references": [...],
  "notable_quotes": [...],
  "tags": [...],
  "suggested_title": "...",
  "transcript_excerpt": "...",
  "transcript_url": "<R2 URL for full .txt>"
}
```

Later, remanence's catalog UI can grow features that consume this:
tag filtering, topic search, bible-reference cross-indexing, etc.

## Auth: the real blocker

Remanence uses email magic-link auth. A CLI can't sit through an email
verification loop. Two reasonable paths:

**Option 1 — dedicated sync endpoint with API key**

Add a single `POST /api/sync` endpoint in remanence that:
- Accepts `Authorization: Bearer <SYNC_API_KEY>` header
- Reads the key from a new `SYNC_API_KEY` env var
- Is the *only* endpoint accessible via API key (limits blast radius)
- Calls the same underlying handlers as `/api/sounds` POST

audio-archive stores its key in a config file or env var.

**Option 2 — local-only bypass**

If remanence is running on `localhost` on the same Mac as audio-archive,
bypass auth for loopback requests. Simple but fragile (someone SSHes
in and suddenly has admin access).

Option 1 is cleaner and scales if remanence ever moves off localhost.

## Suggested sync flow

```
audio-archive                      remanence-archive
─────────────                      ─────────────────
archive sync <recording-id>
  │
  ├──▶ GET /api/sync/next-catalog-number
  │    (returns "RA-042")
  │
  ├──▶ POST /api/sync/upload       (presigned R2 URL for master WAV)
  │    PUT to R2 with original file
  │
  ├──▶ POST /api/sync/upload       (presigned R2 URL for prep WAV)
  │    PUT to R2 with prepared file
  │
  └──▶ POST /api/sync              (create sound record)
       {
         catalogNumber: "RA-042",
         title, description, medium,
         estimatedRecordingDate,
         tracks: [...],
         metadata: { ... },
         published: false         // draft by default, admin reviews
       }
```

Drafts-by-default is important: the summary and transcript quality
aren't perfect, so the admin should review + publish manually rather
than having junk appear on the public catalog.

## New audio-archive CLI command

```bash
# Sync one recording
archive sync 42

# Sync and mark published (skip review)
archive sync 42 --publish

# Sync all recordings that have a completed summarize job but haven't been synced yet
archive sync --pending

# Dry-run — show what would be posted without actually doing it
archive sync 42 --dry-run
```

Adds a `synced_at` and `remanence_catalog_number` column to the
recordings table in audio-archive so we can track what's already been
pushed and avoid duplicates.

## Prerequisites before building

Roughly in order:

1. **Summarization quality is good enough to publish.** Right now runs
   are variable — Bible reference extraction fluctuates 1-5 refs per
   run on the same input. Need deterministic extraction or human review
   gate before pushing upstream.

2. **Audio-archive handles real tape recordings robustly.** The pipeline
   is tested end-to-end but not at scale on actual 30-60 minute sermons
   from a directory of ~100 files. Batch ingest + worker needs proving
   on real volume.

3. **Remanence gets a `metadata` JSONB column.** Small migration, non-
   breaking.

4. **Remanence gets `/api/sync` with API-key auth.** One new file, one
   new env var. Scoped narrowly.

5. **audio-archive gets `archive sync` command.** Talks to remanence
   over HTTP, uploads to R2 via presigned URL, POSTs the record.

6. **audio-archive tracks sync state.** `synced_at` and
   `remanence_catalog_number` columns, so `archive sync --pending`
   works.

## Open questions to resolve later

- **Medium detection.** audio-archive doesn't currently know whether a
  file came from reel-to-reel vs cassette. We'd need either a CLI flag
  (`archive ingest --medium reel-to-reel`) or metadata in the source
  directory structure, or just default to something and let the admin
  fix it in remanence.

- **Images/thumbnails.** remanence has `imageUrl` and `images` arrays.
  audio-archive has nothing like this. Skip for sync v1, or add
  optional `--image` flag to `archive sync`.

- **`whereFound`, `dateFound`, `estimatedRecordingDate`.** These
  provenance fields don't map cleanly. `estimatedRecordingDate` can
  come from the `date` field in audio-archive. The other two are
  tape-specific and would need new fields or manual entry.

- **Transcript hosting.** For Path B, where does the full transcript
  live? Options: (a) upload `.txt` to R2 alongside audio, include URL
  in metadata; (b) embed in `metadata.transcript_full` directly (JSONB
  can handle it, but bloats the row); (c) keep transcripts only in
  audio-archive's SQLite and let remanence link back somehow (requires
  audio-archive to be reachable, which breaks the "remanence is the
  public view" model).

  Probably (a) — upload transcript `.txt` to R2, store URL in metadata.

- **Re-sync semantics.** If audio-archive re-transcribes or re-
  summarizes a recording, should `archive sync 42` update the
  existing remanence record or create a new one? Probably update, via
  PATCH, keyed by `metadata.audio_archive_id`.
