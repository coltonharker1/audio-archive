package transcribe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// RunWhisperCpp invokes the whisper.cpp CLI (whisper-cli) and returns a
// parsed Result. Any downstream pipeline code only cares about the Result
// shape, not which engine produced it.
//
// Benchmark evidence from the 2026-04-11 cutover: on an Apple Silicon Mac
// with Metal, whisper.cpp processed a ~69 minute sermon (r005) in 1m41s
// vs faster-whisper's 56m21s on the same file — a ~33× speedup with word
// counts within 0.2% of the Python path (11578 vs 11596). VAD parity on
// the accordion canary: whisper.cpp emits 1 segment "(upbeat music)",
// faster-whisper emits 0 words. Both stay well under the 20-word
// non-speech threshold in the summarizer, so classification outcomes are
// identical.
//
// binPath should point to the whisper-cli binary (e.g.
// /opt/homebrew/bin/whisper-cli). modelPath should point to a GGML speech
// model file (e.g. ~/.audio-archive/models/ggml-base.en.bin). vadModelPath
// should point to a Silero VAD model file; if empty, VAD is disabled
// (NOT recommended — Whisper will hallucinate repeated phrases on non-
// speech audio).
func RunWhisperCpp(ctx context.Context, binPath, modelPath, vadModelPath, audioPath string) (*Result, error) {
	if binPath == "" {
		return nil, errors.New("whisper.cpp binary path is empty")
	}
	if _, err := os.Stat(binPath); err != nil {
		return nil, fmt.Errorf("whisper.cpp binary not found at %s: %w", binPath, err)
	}
	if _, err := os.Stat(modelPath); err != nil {
		return nil, fmt.Errorf("whisper.cpp speech model not found at %s: %w", modelPath, err)
	}
	if vadModelPath != "" {
		if _, err := os.Stat(vadModelPath); err != nil {
			return nil, fmt.Errorf("whisper.cpp VAD model not found at %s: %w", vadModelPath, err)
		}
	}
	if _, err := os.Stat(audioPath); err != nil {
		return nil, fmt.Errorf("audio file not found at %s: %w", audioPath, err)
	}

	// whisper-cli writes its JSON output next to the input by default. Pin
	// it to a temp file we own so multiple concurrent transcribes can't
	// collide on the same path.
	tmpDir, err := os.MkdirTemp("", "whispercpp-*")
	if err != nil {
		return nil, fmt.Errorf("creating temp dir for whisper.cpp output: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	outBase := filepath.Join(tmpDir, "out") // whisper-cli appends .json

	args := []string{
		"--model", modelPath,
		"--file", audioPath,
		"--output-json",
		"--output-file", outBase,
		"--no-prints",    // reduce stderr noise
		"--language", "en", // base.en is English-only; "auto" on an .en model is a no-op
	}
	// VAD requires both --vad and --vad-model or whisper.cpp aborts
	// (ggml_abort). Only enable when the caller provided a VAD model path.
	if vadModelPath != "" {
		args = append(args, "--vad", "--vad-model", vadModelPath)
	}

	cmd := exec.CommandContext(ctx, binPath, args...)
	applySubprocessSafety(cmd)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	// We don't use stdout — whisper-cli writes its result to the json file.
	// Fold any stray stdout into the parent's stderr so we see it in the
	// daemon log if something goes wrong, but don't block on pipe I/O.
	cmd.Stdout = os.Stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("whisper.cpp failed: %w\nstderr: %s", err, stderr.String())
	}

	// Parse the JSON output file.
	jsonPath := outBase + ".json"
	raw, err := os.ReadFile(jsonPath)
	if err != nil {
		return nil, fmt.Errorf("reading whisper.cpp output JSON (%s): %w\nstderr: %s", jsonPath, err, stderr.String())
	}

	return parseWhisperCppJSON(raw)
}

// whisperCppJSON matches the shape that `whisper-cli --output-json` writes.
// See
// https://github.com/ggerganov/whisper.cpp/blob/master/examples/cli/cli.cpp
// for the canonical writer. Fields we don't use are intentionally omitted.
type whisperCppJSON struct {
	Result struct {
		Language string `json:"language"`
	} `json:"result"`
	Transcription []struct {
		Offsets struct {
			From int64 `json:"from"` // ms
			To   int64 `json:"to"`   // ms
		} `json:"offsets"`
		Text string `json:"text"`
	} `json:"transcription"`
}

// parseWhisperCppJSON converts the whisper.cpp JSON output into the
// internal Result shape shared with the Python worker path.
//
// Isolated so it can be unit-tested against real or canned whisper.cpp
// output without needing the binary installed.
func parseWhisperCppJSON(raw []byte) (*Result, error) {
	var w whisperCppJSON
	if err := json.Unmarshal(raw, &w); err != nil {
		return nil, fmt.Errorf("parsing whisper.cpp JSON: %w", err)
	}

	result := &Result{
		Language: w.Result.Language,
		Segments: make([]Segment, 0, len(w.Transcription)),
	}

	var texts []string
	var lastEndMs int64
	for _, t := range w.Transcription {
		text := strings.TrimSpace(t.Text)
		if text == "" {
			continue
		}
		result.Segments = append(result.Segments, Segment{
			Start: float64(t.Offsets.From) / 1000.0,
			End:   float64(t.Offsets.To) / 1000.0,
			Text:  text,
		})
		texts = append(texts, text)
		if t.Offsets.To > lastEndMs {
			lastEndMs = t.Offsets.To
		}
	}

	result.FullText = strings.Join(texts, " ")
	result.Duration = float64(lastEndMs) / 1000.0
	// whisper.cpp doesn't return a language probability; leave zero.
	return result, nil
}
