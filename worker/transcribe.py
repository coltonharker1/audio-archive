#!/usr/bin/env python3
"""
Transcription worker for audio-archive.
Invoked by Go as a subprocess. Reads audio path from argv, writes JSON to stdout.
All logging goes to stderr so Go can cleanly parse stdout as JSON.
"""
import json
import sys
import time


def transcribe(audio_path, model_size="base"):
    start = time.time()

    # Import here so startup errors are caught cleanly
    from faster_whisper import WhisperModel

    print(f"Loading model: {model_size}", file=sys.stderr)
    model = WhisperModel(model_size, device="cpu", compute_type="int8")

    print(f"Transcribing: {audio_path}", file=sys.stderr)
    segments, info = model.transcribe(audio_path, beam_size=5)

    result = {
        "language": info.language,
        "language_probability": round(info.language_probability, 4),
        "duration": round(info.duration, 3),
        "segments": [],
        "full_text": "",
    }

    texts = []
    for seg in segments:
        text = seg.text.strip()
        result["segments"].append({
            "start": round(seg.start, 3),
            "end": round(seg.end, 3),
            "text": text,
        })
        texts.append(text)

    result["full_text"] = " ".join(texts)

    elapsed = time.time() - start
    print(f"Done in {elapsed:.1f}s — {len(result['segments'])} segments", file=sys.stderr)

    json.dump(result, sys.stdout, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: transcribe.py <audio_path> [model_size]", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    model_size = sys.argv[2] if len(sys.argv) > 2 else "base"
    transcribe(audio_path, model_size)
