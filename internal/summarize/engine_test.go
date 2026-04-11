package summarize

import (
	"strings"
	"testing"
)

// ---- chunkTranscript ----

func TestChunkTranscript_ShortTextReturnsSingleChunk(t *testing.T) {
	text := "this is a short piece of text with fewer words than the budget"
	chunks := chunkTranscript(text, 1000, 100)

	if len(chunks) != 1 {
		t.Errorf("got %d chunks, want 1", len(chunks))
	}
	if chunks[0] != text {
		t.Errorf("chunk content changed unexpectedly")
	}
}

func TestChunkTranscript_SplitsLongText(t *testing.T) {
	// Build 5000 distinct words
	words := make([]string, 5000)
	for i := range words {
		words[i] = "word"
	}
	text := strings.Join(words, " ")

	chunks := chunkTranscript(text, 2000, 200)

	if len(chunks) < 2 {
		t.Errorf("expected multiple chunks for 5000 words with budget 2000, got %d", len(chunks))
	}

	// Every chunk should have no more words than the budget
	for i, chunk := range chunks {
		w := len(strings.Fields(chunk))
		if w > 2000 {
			t.Errorf("chunk %d has %d words, budget was 2000", i, w)
		}
	}
}

func TestChunkTranscript_OverlapIsRespected(t *testing.T) {
	// 1000 unique numbered words so we can detect overlap
	words := make([]string, 1000)
	for i := range words {
		words[i] = "w" + string(rune('0'+i%10)) + string(rune('0'+(i/10)%10))
	}
	text := strings.Join(words, " ")

	chunks := chunkTranscript(text, 400, 50)

	if len(chunks) < 2 {
		t.Fatalf("expected multiple chunks, got %d", len(chunks))
	}

	// The last N words of chunk[0] should appear at the start of chunk[1]
	// (where N is the overlap). Check that chunk[1] starts within the first
	// 400 words of chunk[0] worth of content.
	first := strings.Fields(chunks[0])
	second := strings.Fields(chunks[1])

	// Find chunk[1][0] in chunk[0]
	var overlapIdx int = -1
	for i, w := range first {
		if w == second[0] {
			overlapIdx = i
			break
		}
	}
	if overlapIdx == -1 {
		t.Error("chunk[1] does not begin within chunk[0] — no overlap detected")
	}
}

// ---- parseSummaryJSON ----

func TestParseSummaryJSON_ValidJSON(t *testing.T) {
	raw := `{
		"recording_type": "sermon",
		"type_confidence": "high",
		"summary_short": "A sermon",
		"summary_long": "Detailed.",
		"suggested_title": "Test",
		"main_topics": ["one", "two"],
		"themes": ["grace"],
		"tags": ["sermon", "test"],
		"people": ["Pastor Smith"],
		"places": [],
		"organizations": [],
		"dates_mentioned": [],
		"estimated_era": "",
		"estimated_date": "",
		"notable_quotes": [],
		"mood": "solemn",
		"speakers": [],
		"action_items": [],
		"type_specific": {"bible_references": []}
	}`

	summary, err := parseSummaryJSON(raw)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if summary.RecordingType != TypeSermon {
		t.Errorf("type = %q, want sermon", summary.RecordingType)
	}
	if summary.SummaryShort != "A sermon" {
		t.Errorf("summary_short = %q", summary.SummaryShort)
	}
	if len(summary.MainTopics) != 2 {
		t.Errorf("main_topics len = %d, want 2", len(summary.MainTopics))
	}
}

func TestParseSummaryJSON_StripsMarkdownFences(t *testing.T) {
	raw := "```json\n" + `{
		"recording_type": "other",
		"summary_short": "Test",
		"summary_long": "Test",
		"main_topics": [],
		"tags": []
	}` + "\n```"

	summary, err := parseSummaryJSON(raw)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if summary.SummaryShort != "Test" {
		t.Errorf("summary_short = %q", summary.SummaryShort)
	}
}

func TestParseSummaryJSON_InvalidJSON(t *testing.T) {
	_, err := parseSummaryJSON("not json at all")
	if err == nil {
		t.Error("expected error on invalid JSON")
	}
}

// ---- normalizeSummary ----

func TestNormalizeSummary_NilSlicesBecomeEmpty(t *testing.T) {
	s := &RecordingSummary{
		SummaryShort: "test",
	}
	normalizeSummary(s)

	// Every slice field should be non-nil after normalization
	if s.MainTopics == nil {
		t.Error("MainTopics should be empty slice, not nil")
	}
	if s.Tags == nil {
		t.Error("Tags should be empty slice, not nil")
	}
	if s.People == nil {
		t.Error("People should be empty slice, not nil")
	}
	if s.Places == nil {
		t.Error("Places should be empty slice, not nil")
	}
	if s.Organizations == nil {
		t.Error("Organizations should be empty slice, not nil")
	}
	if s.DatesMentioned == nil {
		t.Error("DatesMentioned should be empty slice, not nil")
	}
	if s.NotableQuotes == nil {
		t.Error("NotableQuotes should be empty slice, not nil")
	}
	if s.Speakers == nil {
		t.Error("Speakers should be empty slice, not nil")
	}
	if s.ActionItems == nil {
		t.Error("ActionItems should be empty slice, not nil")
	}
	if s.Themes == nil {
		t.Error("Themes should be empty slice, not nil")
	}
	if s.TypeSpecific == nil {
		t.Error("TypeSpecific should be empty map, not nil")
	}
}

func TestNormalizeSummary_PlaceholderValuesCleared(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantEmpty bool
	}{
		{"Unknown", "Unknown", true},
		{"unknown lowercase", "unknown", true},
		{"N/A", "N/A", true},
		{"none", "none", true},
		{"null", "null", true},
		{"  Unknown  ", "  Unknown  ", true},
		{"real value", "1960s", false},
		{"empty", "", true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := &RecordingSummary{EstimatedEra: tc.input}
			normalizeSummary(s)

			got := s.EstimatedEra == ""
			if got != tc.wantEmpty {
				t.Errorf("EstimatedEra=%q → isEmpty=%v, want %v", tc.input, got, tc.wantEmpty)
			}
		})
	}
}

func TestNormalizeSummary_TagsLowercasedAndHyphenated(t *testing.T) {
	s := &RecordingSummary{
		Tags: []string{"End Times", "REVELATION", "spiritual warfare", "  tag  "},
	}
	normalizeSummary(s)

	want := []string{"end-times", "revelation", "spiritual-warfare", "tag"}
	if len(s.Tags) != len(want) {
		t.Fatalf("len(Tags) = %d, want %d", len(s.Tags), len(want))
	}
	for i, got := range s.Tags {
		if got != want[i] {
			t.Errorf("tags[%d] = %q, want %q", i, got, want[i])
		}
	}
}

func TestNormalizeSummary_EmptyTypeDefaultsToOther(t *testing.T) {
	s := &RecordingSummary{}
	normalizeSummary(s)
	if s.RecordingType != TypeOther {
		t.Errorf("empty RecordingType should default to %q, got %q", TypeOther, s.RecordingType)
	}
}

// ---- ModelProfile.ChunkBudget ----

func TestChunkBudget_MistralDefault(t *testing.T) {
	p := ModelProfiles["mistral"]
	budget := p.ChunkBudget()

	// mistral has 8192 context, 500 prompt overhead, 1024 response reserve
	// → 6668 tokens for transcript → ~5129 words at 1.3 tokens/word
	if budget < 5000 || budget > 5300 {
		t.Errorf("mistral chunk budget = %d, want ~5129", budget)
	}
}

func TestChunkBudget_SmallModelClamped(t *testing.T) {
	// A hypothetical tiny model with a 1024 context window
	p := ModelProfile{ContextWindow: 1024, TokensPerWord: 1.3}
	budget := p.ChunkBudget()

	// Available = 1024 - 500 - 1024 = -500, but minimum is 500 tokens
	// → 500/1.3 ≈ 384 words
	if budget < 100 || budget > 500 {
		t.Errorf("tiny model budget = %d, want ~384", budget)
	}
}

func TestChunkBudget_LargeContextModel(t *testing.T) {
	p := ModelProfiles["mistral-nemo"]
	budget := p.ChunkBudget()

	// 128000 - 500 - 1024 = 126476 tokens → ~97289 words
	if budget < 90000 {
		t.Errorf("mistral-nemo budget = %d, expected much larger", budget)
	}
}

// ---- flattenTypeSpecific ----

func TestFlattenTypeSpecific_NestedUnderTypeKey(t *testing.T) {
	s := &RecordingSummary{
		RecordingType: TypeSermon,
		TypeSpecific: map[string]any{
			"sermon": map[string]any{
				"bible_references":   []any{"Rev 13:4"},
				"scripture_focus":    "Revelation 13",
				"theological_themes": []any{"eschatology"},
			},
		},
	}

	flattenTypeSpecific(s)

	if _, stillNested := s.TypeSpecific["sermon"]; stillNested {
		t.Error("sermon key should have been flattened")
	}
	if _, ok := s.TypeSpecific["scripture_focus"]; !ok {
		t.Error("scripture_focus should be at top level after flatten")
	}
	if _, ok := s.TypeSpecific["bible_references"]; !ok {
		t.Error("bible_references should be at top level after flatten")
	}
}

func TestFlattenTypeSpecific_NotNested(t *testing.T) {
	s := &RecordingSummary{
		RecordingType: TypeSermon,
		TypeSpecific: map[string]any{
			"scripture_focus": "Revelation 13",
		},
	}

	flattenTypeSpecific(s)

	if got := s.TypeSpecific["scripture_focus"]; got != "Revelation 13" {
		t.Errorf("unexpected change: %v", got)
	}
}

func TestFlattenTypeSpecific_DifferentKeyNotFlattened(t *testing.T) {
	// If type_specific has a sub-object whose key doesn't match the recording
	// type, leave it alone — it's probably a legitimate nested field.
	s := &RecordingSummary{
		RecordingType: TypeSermon,
		TypeSpecific: map[string]any{
			"unrelated_key": map[string]any{"foo": "bar"},
		},
	}

	flattenTypeSpecific(s)

	nested, ok := s.TypeSpecific["unrelated_key"].(map[string]any)
	if !ok {
		t.Fatal("unrelated nested key was incorrectly flattened")
	}
	if nested["foo"] != "bar" {
		t.Error("nested value corrupted")
	}
}

// ---- cleanTypeSpecific ----

func TestCleanTypeSpecific_RemovesPlaceholders(t *testing.T) {
	m := map[string]any{
		"location":    "Unknown",
		"environment": "indoor",
		"style":       "N/A",
		"notes":       "",
	}
	cleanTypeSpecific(m)

	if _, ok := m["location"]; ok {
		t.Error("'Unknown' location should be removed")
	}
	if m["environment"] != "indoor" {
		t.Error("real value should be preserved")
	}
	if _, ok := m["style"]; ok {
		t.Error("'N/A' should be removed")
	}
	if _, ok := m["notes"]; ok {
		t.Error("empty string should be removed")
	}
}

func TestCleanTypeSpecific_CleansNestedMaps(t *testing.T) {
	m := map[string]any{
		"details": map[string]any{
			"venue":  "Unknown",
			"crowd":  "large",
			"notes":  "n/a",
		},
		"name": "valid",
	}
	cleanTypeSpecific(m)

	details, ok := m["details"].(map[string]any)
	if !ok {
		t.Fatal("details should still be a map")
	}
	if _, exists := details["venue"]; exists {
		t.Error("nested 'Unknown' should be removed")
	}
	if details["crowd"] != "large" {
		t.Error("real nested value should be preserved")
	}
}

func TestCleanTypeSpecific_RemovesEmptyArrayItems(t *testing.T) {
	m := map[string]any{
		"pieces": []any{"Ave Maria", "Unknown", "N/A", "Clair de Lune"},
	}
	cleanTypeSpecific(m)

	pieces, ok := m["pieces"].([]any)
	if !ok {
		t.Fatal("pieces should still be an array")
	}
	if len(pieces) != 2 {
		t.Errorf("expected 2 items after cleaning, got %d: %v", len(pieces), pieces)
	}
}

// ---- computeSpeechDensity ----

func TestComputeSpeechDensity_NormalSpeech(t *testing.T) {
	// 10 minutes with 1500 words = 150 wpm
	d := computeSpeechDensity(1500, 10*60*1000)
	if d.Classification != "normal" {
		t.Errorf("1500/10min = %s, want normal", d.Classification)
	}
	if d.WordsPerMinute < 149 || d.WordsPerMinute > 151 {
		t.Errorf("wpm = %f, want ~150", d.WordsPerMinute)
	}
}

func TestComputeSpeechDensity_Minimal(t *testing.T) {
	// 35 minutes with ~450 words (the accordion case)
	// But actually without VAD hallucinations, it'd be closer to 0
	d := computeSpeechDensity(50, 35*60*1000)
	if d.Classification != "minimal" {
		t.Errorf("50/35min = %s, want minimal", d.Classification)
	}
}

func TestComputeSpeechDensity_Sparse(t *testing.T) {
	// 10 min with 200 words = 20 wpm
	d := computeSpeechDensity(200, 10*60*1000)
	if d.Classification != "sparse" {
		t.Errorf("200/10min = %s, want sparse", d.Classification)
	}
}

func TestComputeSpeechDensity_Slow(t *testing.T) {
	// 10 min with 600 words = 60 wpm
	d := computeSpeechDensity(600, 10*60*1000)
	if d.Classification != "slow" {
		t.Errorf("600/10min = %s, want slow", d.Classification)
	}
}

func TestComputeSpeechDensity_ZeroDuration(t *testing.T) {
	d := computeSpeechDensity(100, 0)
	if d.Description != "" {
		t.Error("zero duration should yield empty density")
	}
}

// ---- Prompt size regression guard ----

// TestExtractPromptSize prevents the stage 3 extraction prompt from
// bloating back to the point where it overflows Mistral's 8K context
// window. A long history of iterative prompt additions caused a real
// bug where summaries took 10+ minutes instead of 30 seconds because
// the prompt + content exceeded the window and Ollama fell into
// sliding-window mode.
//
// The TEMPLATE (instructions, taxonomy, type guide) should stay under
// ~2500 words. The actual content (merged summary, chunk summaries)
// is variable per recording and we accept those costs — but the
// fixed-cost template must stay small.
func TestExtractPromptSize(t *testing.T) {
	density := SpeechDensity{
		WordsPerMinute: 100,
		Classification: "normal",
		Description:    "~100 words per minute — normal speech density.",
	}

	// Pass empty strings for the variable-size content; we only want
	// to measure the template + taxonomy + type guide.
	prompt := fmtExtractPrompt("", "", density, "No file metadata available.")
	words := len(strings.Fields(prompt))

	// Budget: 2500 words is ~3300 tokens, well under 8K.
	const maxTemplateWords = 2500
	if words > maxTemplateWords {
		t.Errorf("extract prompt template is %d words, budget is %d.\n"+
			"Prompt bloat caused a production bug; keep it tight.\n"+
			"Current prompt:\n%s",
			words, maxTemplateWords, prompt)
	}

	// Also make sure it's not accidentally empty or missing critical pieces
	if !strings.Contains(prompt, "recording_type") {
		t.Error("prompt missing recording_type reference")
	}
	if !strings.Contains(prompt, "people") || !strings.Contains(prompt, "places") {
		t.Error("prompt missing universal entity fields")
	}
	if !strings.Contains(prompt, string(TypeSermon)) {
		t.Error("prompt missing type taxonomy")
	}

	t.Logf("extract prompt template size: %d words", words)
}

// ---- Known types completeness ----

func TestKnownRecordingTypesCoversConstants(t *testing.T) {
	// Every declared RecordingType constant should appear in KnownRecordingTypes.
	// If we add a new type and forget to add it to the list, this test fails.
	declared := []RecordingType{
		TypeSermon, TypeVoicemail, TypePhoneCall, TypeInterview, TypeMeeting,
		TypeMusicalPerformance, TypeAudioDiary, TypeLecture, TypeBroadcast,
		TypeFieldRecording, TypeOther,
	}

	seen := make(map[RecordingType]bool)
	for _, rt := range KnownRecordingTypes {
		seen[rt] = true
	}

	for _, rt := range declared {
		if !seen[rt] {
			t.Errorf("RecordingType %q is declared but missing from KnownRecordingTypes", rt)
		}
	}
}
