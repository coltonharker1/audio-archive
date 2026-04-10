# audio-archive

A local pipeline for ingesting, prepping, transcribing, summarizing, and searching audio recordings — built for archiving digitized cassette and reel-to-reel tapes.

Everything runs locally. Go handles the pipeline, CLI, orchestration, and metadata. Python runs only the speech-to-text worker (`faster-whisper`). Summarization uses a local LLM via Ollama.

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
