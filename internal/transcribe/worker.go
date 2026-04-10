package transcribe

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
)

// Segment represents a timed transcript segment.
type Segment struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Text  string  `json:"text"`
}

// Result holds the complete transcription output from the Python worker.
type Result struct {
	Language            string    `json:"language"`
	LanguageProbability float64   `json:"language_probability"`
	Duration            float64   `json:"duration"`
	Segments            []Segment `json:"segments"`
	FullText            string    `json:"full_text"`
}

// Run invokes the Python transcription worker and returns the parsed result.
// pythonPath should point to the venv's python binary.
// workerPath should point to worker/transcribe.py.
func Run(ctx context.Context, pythonPath, workerPath, audioPath, modelSize string) (*Result, error) {
	cmd := exec.CommandContext(ctx, pythonPath, workerPath, audioPath, modelSize)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("transcription worker failed: %w\nstderr: %s", err, stderr.String())
	}

	var result Result
	if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
		return nil, fmt.Errorf("parsing transcript JSON: %w\nraw output: %s", err, stdout.String())
	}

	return &result, nil
}
