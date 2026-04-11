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
	"syscall"
)

// RunWhisperCpp invokes the whisper.cpp CLI (whisper-cli) and returns a
// parsed Result compatible with the Python worker's output, so downstream
// pipeline code doesn't care which backend produced the transcript.
//
// This is the scaffolding for the whisper.cpp migration planned in
// docs/DESIGN.md. The pipeline does not yet call this function — it's
// parked here with tests against a fake binary so a future session can
// benchmark against real whisper.cpp on one sermon recording, confirm
// VAD parity on the accordion canary, and then flip the pipeline in
// internal/pipeline/transcribe.go to call this instead of Run.
//
// Expected whisper.cpp invocation:
//
//	whisper-cli --model <gguf> --file <wav> --output-json \
//	            --no-prints --language auto --vad
//
// whisper.cpp writes a JSON file next to the audio file by default (same
// name, .json extension). We pass --output-file <base> to pin the location,
// then read and parse it. This matches the contract of the existing Run
// function so TranscribeRecording needs only a one-line swap to switch.
//
// binPath should point to the whisper-cli binary (e.g.
// /opt/homebrew/bin/whisper-cli). modelPath should point to a GGML model
// file (e.g. ~/.audio-archive/models/ggml-base.en.bin).
func RunWhisperCpp(ctx context.Context, binPath, modelPath, audioPath string) (*Result, error) {
	if binPath == "" {
		return nil, errors.New("whisper.cpp binary path is empty")
	}
	if _, err := os.Stat(binPath); err != nil {
		return nil, fmt.Errorf("whisper.cpp binary not found at %s: %w", binPath, err)
	}
	if _, err := os.Stat(modelPath); err != nil {
		return nil, fmt.Errorf("whisper.cpp model not found at %s: %w", modelPath, err)
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
		"--no-prints", // reduce stderr noise
		"--language", "auto",
		"--vad", // voice activity detection — canary parity check with faster-whisper
	}

	cmd := exec.CommandContext(ctx, binPath, args...)
	applySubprocessSafety(cmd)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	// We don't use stdout — whisper-cli writes its result to the json file.
	// Discard stdout to prevent pipe buffering issues on chatty builds.
	cmd.Stdout = os.Stderr // fold stdout into stderr for the Go parent

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

// applySubprocessSafety applies the same process-group + WaitDelay
// protections we added to the Python worker path, so this wrapper cannot
// hang indefinitely on a subprocess that leaks file descriptors.
func applySubprocessSafety(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
			return err
		}
		return os.ErrProcessDone
	}
	cmd.WaitDelay = waitDelay
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
