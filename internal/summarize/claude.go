package summarize

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ClaudeEngine runs summarization via the Claude Code CLI (`claude -p`).
//
// Unlike the Ollama engine's 3-stage chunk/merge/extract pipeline (required
// by Mistral's 8K context window), this engine does everything in a single
// prompt — Claude's 200K+ context easily handles any transcript. The prompt
// asks for classification, narrative summary, and structured entity
// extraction all at once, producing a RecordingSummary-shaped JSON.
//
// The CLI is invoked as a subprocess using the same applySubprocessSafety
// pattern as the whisper.cpp wrapper: process group isolation, group-wide
// SIGKILL on cancel, and WaitDelay to prevent pipe-hang deadlocks.
//
// Cost: covered by the user's Claude Max subscription (no API credits).
// Tradeoff: requires internet; falls back to Ollama when offline.
type ClaudeEngine struct {
	binPath string // path to the claude CLI binary
}

// NewClaudeEngine creates a Claude-based summarization engine.
// binPath should point to the claude CLI (e.g. the result of `which claude`).
func NewClaudeEngine(binPath string) *ClaudeEngine {
	return &ClaudeEngine{binPath: binPath}
}

// claudeWaitDelay is the maximum time to wait for pipe I/O after the claude
// process exits. Same rationale as the transcribe wrapper's waitDelay.
var claudeWaitDelay = 30 * time.Second

// Summarize runs a single-prompt summarization via Claude CLI and returns
// the structured result. It retries once on non-zero exit.
func (e *ClaudeEngine) Summarize(ctx context.Context, input SummarizeInput) (*PipelineResult, error) {
	transcript := input.Transcript
	wordCount := len(strings.Fields(transcript))
	density := computeSpeechDensity(wordCount, input.DurationMs)

	slog.Info("summarization starting",
		"engine", "claude",
		"words", wordCount,
		"duration_ms", input.DurationMs,
		"wpm", fmt.Sprintf("%.1f", density.WordsPerMinute),
		"density", density.Classification,
	)

	prompt := buildClaudePrompt(input, density)

	var result *PipelineResult
	var lastErr error

	for attempt := 1; attempt <= 2; attempt++ {
		raw, err := e.runCLI(ctx, prompt)
		if err != nil {
			lastErr = err
			slog.Warn("claude CLI attempt failed",
				"attempt", attempt,
				"error", err)
			continue
		}

		summary, err := parseClaudeResponse(raw)
		if err != nil {
			lastErr = fmt.Errorf("parsing claude response: %w\nraw: %s", err, truncate(raw, 500))
			slog.Warn("claude response parse failed",
				"attempt", attempt,
				"error", err)
			continue
		}

		// Normalize the summary the same way the Ollama engine does.
		normalizeSummary(summary)

		result = &PipelineResult{
			ChunkSummaries: []string{summary.SummaryLong},
			MergedSummary:  summary.SummaryLong,
			Metadata:       summary,
		}
		break
	}

	if result == nil {
		return nil, fmt.Errorf("claude summarization failed after 2 attempts: %w", lastErr)
	}

	// Write debug files if requested.
	if input.DebugDir != "" {
		writeDebugFile(input.DebugDir, "claude_prompt.txt", prompt)
		metaJSON, _ := json.MarshalIndent(result.Metadata, "", "  ")
		writeDebugFile(input.DebugDir, "stage3_metadata.json", string(metaJSON))
	}

	slog.Info("summarization complete",
		"engine", "claude",
		"type", result.Metadata.RecordingType,
		"topics", len(result.Metadata.MainTopics),
		"people", len(result.Metadata.People),
		"tags", len(result.Metadata.Tags),
	)

	return result, nil
}

// runCLI invokes `claude -p <prompt> --output-format json` and returns the
// result text from the JSON envelope.
func (e *ClaudeEngine) runCLI(ctx context.Context, prompt string) (string, error) {
	cmd := exec.CommandContext(ctx, e.binPath, "-p", prompt, "--output-format", "json")
	applyClaudeSubprocessSafety(cmd)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("claude CLI failed: %w\nstderr: %s", err, truncate(stderr.String(), 500))
	}

	// Parse the CLI's JSON envelope to extract the actual response text.
	var envelope struct {
		Result  string `json:"result"`
		IsError bool   `json:"is_error"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &envelope); err != nil {
		return "", fmt.Errorf("parsing claude CLI envelope: %w\nraw: %s", err, truncate(stdout.String(), 500))
	}
	if envelope.IsError {
		return "", fmt.Errorf("claude CLI reported error: %s", truncate(envelope.Result, 500))
	}

	return envelope.Result, nil
}

// applyClaudeSubprocessSafety mirrors the transcribe wrapper's safety
// pattern. See internal/transcribe/subprocess.go for the full rationale.
func applyClaudeSubprocessSafety(cmd *exec.Cmd) {
	attr := syscallSysProcAttr()
	cmd.SysProcAttr = &attr
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		if err := killProcessGroup(cmd.Process.Pid); err != nil {
			return err
		}
		return os.ErrProcessDone
	}
	cmd.WaitDelay = claudeWaitDelay
}

// parseClaudeResponse extracts a RecordingSummary from Claude's text
// response. The prompt asks for a JSON object; Claude sometimes wraps it
// in markdown fences which we strip.
func parseClaudeResponse(raw string) (*RecordingSummary, error) {
	text := strings.TrimSpace(raw)

	// Strip markdown code fences if present.
	if strings.HasPrefix(text, "```") {
		// Remove opening fence line
		if idx := strings.Index(text, "\n"); idx >= 0 {
			text = text[idx+1:]
		}
		// Remove closing fence
		if idx := strings.LastIndex(text, "```"); idx >= 0 {
			text = text[:idx]
		}
		text = strings.TrimSpace(text)
	}

	var summary RecordingSummary
	if err := json.Unmarshal([]byte(text), &summary); err != nil {
		return nil, fmt.Errorf("JSON unmarshal: %w", err)
	}

	return &summary, nil
}

// buildClaudePrompt constructs the single-shot prompt for Claude.
// Unlike the Ollama engine's 3-stage approach, this puts everything in
// one prompt because Claude's context window can handle it.
func buildClaudePrompt(input SummarizeInput, density SpeechDensity) string {
	fileContext := buildFileContextHint(input.Title, input.SourceName)
	typeTaxonomy := buildTypeTaxonomy()
	typeGuide := buildTypeSpecificGuide()

	// For type-specific field descriptions, include the full detail
	// (not just field names) since we have the context budget for it.
	var typeFieldDetail strings.Builder
	for _, rt := range KnownRecordingTypes {
		fields := typeSpecificFieldGuide[rt]
		if len(fields) == 0 {
			continue
		}
		fmt.Fprintf(&typeFieldDetail, "\n  %s:\n", rt)
		for _, f := range fields {
			fmt.Fprintf(&typeFieldDetail, "    - %s: %s\n", f.Name, f.Desc)
		}
	}

	var b strings.Builder
	b.WriteString("You are an audio recording archivist. Analyze the transcript below and produce a single JSON object with structured metadata.\n\n")

	b.WriteString("## Audio Signal\n")
	fmt.Fprintf(&b, "- Source file: %s\n", fileContext)
	fmt.Fprintf(&b, "- Duration: %.1f minutes\n", float64(input.DurationMs)/60000.0)
	if density.Description != "" {
		fmt.Fprintf(&b, "- Speech density: %s\n", density.Description)
	}

	b.WriteString("\n## Recording Type Taxonomy\n")
	b.WriteString("Classify into exactly one of:\n")
	b.WriteString(typeTaxonomy)

	b.WriteString("\n## Output JSON Schema\n")
	b.WriteString("Return a single JSON object (no markdown fences, no commentary) with these fields:\n\n")
	b.WriteString(`{
  "recording_type": "one of the types above",
  "type_confidence": "high/medium/low",
  "summary_short": "1-2 sentence summary",
  "summary_long": "2-4 paragraph detailed summary preserving key facts, names, dates, quotes",
  "suggested_title": "descriptive title — do NOT invent dates not stated in the transcript",
  "main_topics": ["3-5 primary subjects"],
  "themes": ["recurring concepts or motifs"],
  "tags": ["5-10 lowercase keywords for search"],
  "people": ["every person named or addressed — speakers AND mentioned individuals"],
  "places": ["locations mentioned"],
  "organizations": ["named groups, churches, companies"],
  "dates_mentioned": ["dates or time periods referenced IN the content, NOT the processing date"],
  "estimated_era": "broad time period like '1960s' or 'late 1990s' if determinable",
  "estimated_date": "ISO date if determinable from content, otherwise empty string",
  "notable_quotes": ["2-4 striking verbatim statements"],
  "mood": "overall emotional tone",
  "speakers": ["identified voices"],
  "action_items": ["tasks or follow-ups mentioned, if any"],
  "type_specific": { ... fields specific to the classified type ... }
}
`)

	b.WriteString("\n## Type-Specific Fields\n")
	b.WriteString("Populate `type_specific` based on the classified type:\n")
	b.WriteString(typeGuide)
	b.WriteString("\nFull field descriptions:\n")
	b.WriteString(typeFieldDetail.String())

	b.WriteString("\n## Critical Instructions\n")
	b.WriteString("- Return ONLY the JSON object. No markdown fences, no explanation, no commentary.\n")
	b.WriteString("- For `people`: include the speaker/preacher's name if stated. Do NOT use 'Speaker' as a placeholder.\n")
	b.WriteString("- For `dates_mentioned`: extract dates from the CONTENT, not from file metadata. If the speaker says 'last Tuesday' without context, omit it.\n")
	b.WriteString("- For `suggested_title`: never invent dates or date ranges not explicitly stated in the transcript.\n")
	b.WriteString("- For sermons: scan the full transcript for every Bible reference (Book Chapter:Verse pattern) and include ALL of them in type_specific.bible_references.\n")
	b.WriteString("- Empty arrays [] are better than arrays with placeholder values like ['Unknown'] or ['N/A'].\n")
	b.WriteString("- Empty strings \"\" are better than placeholder values like 'Unknown' or 'Not specified'.\n")

	b.WriteString("\n## Transcript\n\n")
	b.WriteString(input.Transcript)

	return b.String()
}

// truncate shortens s to max characters, appending "..." if truncated.
func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
