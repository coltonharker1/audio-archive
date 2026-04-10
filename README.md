# audio-archive

A local pipeline for ingesting, prepping, transcribing, summarizing, and searching audio recordings — built for archiving digitized cassette and reel-to-reel tapes, generalized to handle any audio content (sermons, voicemails, audio diaries, musical performances, interviews, etc.).

Everything runs locally. Go handles the pipeline, CLI, orchestration, and metadata. Python runs only the speech-to-text worker (`faster-whisper`). Summarization uses a local LLM via Ollama.

> For design rationale, known issues, and how the pipeline thinks about hard problems, see [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- Go 1.22+
- FFmpeg and FFprobe (`brew install ffmpeg`)
- Python 3 (for the transcription worker)
- [Ollama](https://ollama.com) (for summarization)

## Setup

```bash
# Build the CLI
go build -o archive ./cmd/archive/

# Set up the Python transcription worker
python3 -m venv .venv
.venv/bin/pip install -r worker/requirements.txt

# Pull an Ollama model for summarization
ollama pull mistral
```

## Commands

```bash
# Ingest a recording into the archive
./archive ingest sermon.wav --speaker "Pastor Name" --date 2024-01-07 --title "Morning Service"

# Batch ingest a whole directory of files
./archive ingest-dir ~/Tapes/1968/ --recursive --speaker "Pastor Name"

# Prepare audio (normalize, filter, downconvert to 16kHz mono)
./archive prep <id>

# Transcribe with faster-whisper
./archive transcribe <id> --model base

# Summarize with local LLM
./archive summarize <id>

# Full pipeline in one shot
./archive run sermon.wav --speaker "Pastor Name" --date 2024-01-07 --title "Morning Service"

# Browse and search
./archive list
./archive show <id>
./archive search "some phrase"
```

## Background job queue

The pipeline stages can also run asynchronously via a background worker,
with automatic retries and crash recovery.

```bash
# Enqueue jobs for a recording (prep, transcribe, summarize, or all)
./archive enqueue <id> all

# Batch ingest + enqueue full pipeline for every file
./archive ingest-dir ~/Tapes/1968/ --run

# Start the worker (blocks until Ctrl+C)
./archive worker

# Inspect queue state
./archive status
```

## Inbox auto-processing (recommended workflow)

Drop audio files in `~/audio-inbox/` and have them automatically ingested,
prepped, transcribed, and summarized in the background — no manual commands.

```bash
# One-time setup: build, install launchd agents, start the daemons
make install-daemons
```

This installs two macOS launchd agents that start at login and restart if
they crash:

- **`watch` daemon** — monitors `~/audio-inbox/` for new files (via fsnotify)
  and waits for each file's size to stabilize before ingesting. Files already
  being copied are not processed mid-write.
- **`worker` daemon** — processes the job queue (prep → transcribe → summarize)
  with retries and crash recovery.

After that, drop any audio file (wav, mp3, m4a, flac, aiff, aac, ogg, opus)
into the inbox and it will be automatically processed.

```bash
# See whether the daemons are running
make daemons-status

# Tail the logs
make logs

# Rebuild after code changes and restart the daemons
make reinstall-daemons

# Remove the daemons
make uninstall-daemons
```

You can also run the watcher manually (without launchd) for testing:

```bash
./archive watch ~/audio-inbox --stable-delay 3s
```

## Data Layout

Archive data lives in `~/.audio-archive/`:

```
~/.audio-archive/
├── archive.db                 # SQLite database (records, transcripts, summaries, FTS5 index)
├── masters/YYYY/              # Original untouched recordings
├── processed/YYYY/            # FFmpeg-prepped audio (16kHz mono WAV)
├── transcripts/YYYY/          # Plain text + timestamped JSON
└── metadata/YYYY/             # Structured summaries + debug files
```

Original master files are never modified. All processing produces separate files.

## Architecture

- **Go** — CLI, pipeline orchestration, database, FFmpeg calls, Ollama HTTP client, job management
- **Python** — transcription worker only (`worker/transcribe.py` using `faster-whisper`)
- **SQLite** — single-file database with FTS5 for full-text search
- **FFmpeg** — audio preparation pipeline (high-pass filter, loudness normalization, silence trimming, downsampling)
- **Ollama** — local LLM for summarization (default: `mistral`)

### Summarization pipeline

Three stages, all in Go:

1. **Chunk summarization** — splits transcript to fit the model's context window, summarizes each chunk
2. **Summary merge** — combines chunk summaries into a coherent narrative
3. **Structured metadata extraction** — extracts JSON metadata (topics, Bible references, tags, quotes) from both the merged summary and the chunk summaries

Intermediate outputs are saved to `~/.audio-archive/metadata/YYYY/<name>_debug/` for inspection.

## Future work

- **Remanence Archive integration** — push processed recordings (audio + transcript + structured summary) upstream into [remanence-archive](https://github.com/coltonharker1/remanence-archive) as browsable catalog records. Design sketched in [docs/remanence-integration.md](docs/remanence-integration.md).
