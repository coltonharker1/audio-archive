package summarize

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
)

const (
	// Overlap between chunks to preserve context at boundaries.
	overlapWords = 200
	// Maximum attempts to get valid JSON from the extraction stage.
	maxJSONRetries = 3
)

// Engine runs the three-stage summarization pipeline.
type Engine struct {
	client  *OllamaClient
	profile ModelProfile
}

// NewEngine creates a summarization engine for the given Ollama model.
func NewEngine(model string) *Engine {
	profile, ok := ModelProfiles[model]
	if !ok {
		profile = DefaultProfile
		profile.Name = model
		slog.Warn("unknown model, using conservative 4K context estimate",
			"model", model, "chunk_budget_words", profile.ChunkBudget())
	}

	return &Engine{
		client:  NewOllamaClient(model),
		profile: profile,
	}
}

// Summarize runs the full pipeline and returns the structured result.
// debugDir, if non-empty, receives intermediate files for inspection.
func (e *Engine) Summarize(ctx context.Context, transcript string, debugDir string) (*PipelineResult, error) {
	wordCount := len(strings.Fields(transcript))
	chunkBudget := e.profile.ChunkBudget()

	slog.Info("summarization starting",
		"words", wordCount,
		"model", e.profile.Name,
		"context_window", e.profile.ContextWindow,
		"chunk_budget_words", chunkBudget,
	)

	result := &PipelineResult{}

	// ---- Stage 1: Chunk Summarization ----
	chunks := chunkTranscript(transcript, chunkBudget, overlapWords)
	slog.Info("stage 1: chunk summarization", "chunks", len(chunks))

	for i, chunk := range chunks {
		slog.Info("summarizing chunk", "chunk", i+1, "of", len(chunks),
			"words", len(strings.Fields(chunk)))

		prompt := fmtChunkPrompt(i+1, len(chunks), chunk)
		summary, err := e.client.Generate(ctx, prompt, GenerateOpts{
			Temperature: 0.3,
			MaxTokens:   1024,
		})
		if err != nil {
			return nil, fmt.Errorf("stage 1 chunk %d/%d: %w", i+1, len(chunks), err)
		}

		result.ChunkSummaries = append(result.ChunkSummaries, summary)
	}

	// Save intermediate chunk summaries
	if debugDir != "" {
		writeDebugFile(debugDir, "stage1_chunks.txt", formatChunksDebug(result.ChunkSummaries))
	}

	// ---- Stage 2: Summary Merge ----
	slog.Info("stage 2: merging chunk summaries")

	numbered := make([]string, len(result.ChunkSummaries))
	for i, s := range result.ChunkSummaries {
		numbered[i] = fmt.Sprintf("=== Section %d of %d ===\n%s", i+1, len(result.ChunkSummaries), s)
	}
	mergeInput := strings.Join(numbered, "\n\n")

	merged, err := e.client.Generate(ctx, fmtMergePrompt(mergeInput), GenerateOpts{
		Temperature: 0.3,
		MaxTokens:   2048,
	})
	if err != nil {
		return nil, fmt.Errorf("stage 2 merge: %w", err)
	}
	result.MergedSummary = merged

	if debugDir != "" {
		writeDebugFile(debugDir, "stage2_merged.txt", merged)
	}

	// ---- Stage 3: Structured Metadata Extraction ----
	// Pass both the merged narrative (for topics/themes/flow) and the chunk
	// summaries (for exhaustive reference extraction). The merge stage tends
	// to compress multiple references into fewer mentions; chunks preserve
	// the full density.
	slog.Info("stage 3: extracting structured metadata")

	chunkBlob := strings.Join(numbered, "\n\n")
	metadata, err := e.extractWithRetry(ctx, merged, chunkBlob, debugDir)
	if err != nil {
		return nil, fmt.Errorf("stage 3 extraction: %w", err)
	}
	result.Metadata = metadata

	if debugDir != "" {
		metaJSON, _ := json.MarshalIndent(metadata, "", "  ")
		writeDebugFile(debugDir, "stage3_metadata.json", string(metaJSON))
	}

	slog.Info("summarization complete",
		"topics", len(metadata.MainTopics),
		"bible_refs", len(metadata.BibleReferences),
		"tags", len(metadata.Tags),
	)

	return result, nil
}

// extractWithRetry attempts structured JSON extraction with retries.
// On failure, it tries: (1) re-extraction, (2) JSON repair prompt, (3) give up.
func (e *Engine) extractWithRetry(ctx context.Context, mergedSummary, chunkSummaries string, debugDir string) (*SermonSummary, error) {
	var lastRaw string
	var lastErr error

	for attempt := 1; attempt <= maxJSONRetries; attempt++ {
		var raw string
		var err error

		if attempt <= 2 {
			// Attempts 1-2: ask the model to extract structured data.
			// Temperature 0.2 — low enough for consistent JSON, high enough
			// that the model isn't overly conservative about what to extract.
			raw, err = e.client.Generate(ctx, fmtExtractPrompt(mergedSummary, chunkSummaries), GenerateOpts{
				Temperature: 0.2,
				MaxTokens:   4096,
				JSONSchema:  jsonSchema,
			})
		} else {
			// Attempt 3: ask the model to repair the broken JSON from last attempt
			slog.Warn("attempting JSON repair", "attempt", attempt)
			raw, err = e.client.Generate(ctx, fmtRepairPrompt(lastRaw), GenerateOpts{
				Temperature: 0.0,
				MaxTokens:   4096,
				JSONSchema:  jsonSchema,
			})
		}

		if err != nil {
			lastErr = err
			slog.Warn("extraction call failed", "attempt", attempt, "error", err)
			continue
		}

		lastRaw = raw

		// Save raw response for debugging
		if debugDir != "" {
			writeDebugFile(debugDir, fmt.Sprintf("stage3_raw_attempt%d.txt", attempt), raw)
		}

		summary, parseErr := parseSummaryJSON(raw)
		if parseErr == nil {
			if attempt > 1 {
				slog.Info("extraction succeeded on retry", "attempt", attempt)
			}
			return summary, nil
		}

		lastErr = parseErr
		slog.Warn("JSON parse failed", "attempt", attempt, "error", parseErr)
	}

	return nil, fmt.Errorf("failed after %d attempts: %w", maxJSONRetries, lastErr)
}

// jsonSchema is passed to Ollama's format parameter to constrain output.
// Every field is marked required so the model cannot omit fields — it must
// emit empty arrays or empty strings for unknowns instead.
var jsonSchema = json.RawMessage(`{
	"type": "object",
	"properties": {
		"summary_short": {"type": "string"},
		"summary_long": {"type": "string"},
		"main_topics": {"type": "array", "items": {"type": "string"}},
		"notable_themes": {"type": "array", "items": {"type": "string"}},
		"bible_references": {"type": "array", "items": {
			"type": "object",
			"properties": {
				"book": {"type": "string"},
				"chapter": {"type": "integer"},
				"verse": {"type": "integer"},
				"text": {"type": "string"}
			},
			"required": ["book", "chapter", "verse", "text"]
		}},
		"historical_references": {"type": "array", "items": {"type": "string"}},
		"notable_quotes": {"type": "array", "items": {"type": "string"}},
		"tags": {"type": "array", "items": {"type": "string"}},
		"suggested_title": {"type": "string"},
		"suggested_speaker": {"type": "string"},
		"estimated_era": {"type": "string"}
	},
	"required": [
		"summary_short", "summary_long", "main_topics", "notable_themes",
		"bible_references", "historical_references", "notable_quotes",
		"tags", "suggested_title", "suggested_speaker", "estimated_era"
	]
}`)

// chunkTranscript splits text into word-based chunks sized to fit the model's
// context window, with overlap to preserve context at boundaries.
func chunkTranscript(text string, budgetWords, overlapWords int) []string {
	words := strings.Fields(text)
	if len(words) <= budgetWords {
		return []string{text}
	}

	var chunks []string
	start := 0
	stride := budgetWords - overlapWords
	if stride < 100 {
		stride = 100
	}

	for start < len(words) {
		end := start + budgetWords
		if end > len(words) {
			end = len(words)
		}
		chunks = append(chunks, strings.Join(words[start:end], " "))
		start += stride
	}

	return chunks
}

// parseSummaryJSON attempts to parse the LLM's response as SermonSummary JSON.
// It normalizes nil slices to empty slices so downstream JSON output never
// emits `null` for list fields.
func parseSummaryJSON(raw string) (*SermonSummary, error) {
	var summary SermonSummary

	// Try direct parse
	if err := json.Unmarshal([]byte(raw), &summary); err == nil {
		normalizeSummary(&summary)
		return &summary, nil
	}

	// Strip markdown fences and find the JSON object
	cleaned := strings.TrimSpace(raw)
	if idx := strings.Index(cleaned, "{"); idx >= 0 {
		cleaned = cleaned[idx:]
	}
	if idx := strings.LastIndex(cleaned, "}"); idx >= 0 {
		cleaned = cleaned[:idx+1]
	}

	if err := json.Unmarshal([]byte(cleaned), &summary); err != nil {
		preview := raw
		if len(preview) > 300 {
			preview = preview[:300] + "..."
		}
		return nil, fmt.Errorf("invalid JSON: %w\nraw: %s", err, preview)
	}

	normalizeSummary(&summary)
	return &summary, nil
}

// normalizeSummary ensures slice fields are never nil (nil marshals as null;
// empty slice marshals as []) and cleans up common model quirks.
func normalizeSummary(s *SermonSummary) {
	if s.MainTopics == nil {
		s.MainTopics = []string{}
	}
	if s.NotableThemes == nil {
		s.NotableThemes = []string{}
	}
	if s.BibleReferences == nil {
		s.BibleReferences = []BibleReference{}
	}
	if s.HistoricalRefs == nil {
		s.HistoricalRefs = []string{}
	}
	if s.NotableQuotes == nil {
		s.NotableQuotes = []string{}
	}
	if s.Tags == nil {
		s.Tags = []string{}
	}
	// Strip common placeholder values the model uses when it should be empty
	if strings.EqualFold(s.EstimatedEra, "unknown") || strings.EqualFold(s.EstimatedEra, "n/a") {
		s.EstimatedEra = ""
	}
	if strings.EqualFold(s.SuggestedSpeaker, "unknown") || strings.EqualFold(s.SuggestedSpeaker, "n/a") {
		s.SuggestedSpeaker = ""
	}
	// Lowercase tags and strip spaces (replace with hyphens)
	for i, t := range s.Tags {
		t = strings.TrimSpace(strings.ToLower(t))
		t = strings.ReplaceAll(t, " ", "-")
		s.Tags[i] = t
	}
}

// ---- Debug file helpers ----

func writeDebugFile(dir, name, content string) {
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		slog.Warn("failed to write debug file", "path", path, "error", err)
	}
}

func formatChunksDebug(summaries []string) string {
	var b strings.Builder
	for i, s := range summaries {
		fmt.Fprintf(&b, "========== CHUNK %d ==========\n%s\n\n", i+1, s)
	}
	return b.String()
}
