package summarize

// SermonSummary is the structured metadata output from the summarization pipeline.
type SermonSummary struct {
	SummaryShort     string           `json:"summary_short"`
	SummaryLong      string           `json:"summary_long"`
	MainTopics       []string         `json:"main_topics"`
	NotableThemes    []string         `json:"notable_themes"`
	BibleReferences  []BibleReference `json:"bible_references"`
	HistoricalRefs   []string         `json:"historical_references"`
	NotableQuotes    []string         `json:"notable_quotes"`
	Tags             []string         `json:"tags"`
	SuggestedTitle   string           `json:"suggested_title"`
	SuggestedSpeaker string           `json:"suggested_speaker"`
	EstimatedEra     string           `json:"estimated_era"`
}

// BibleReference holds a structured reference to a Bible passage.
type BibleReference struct {
	Book    string `json:"book"`
	Chapter int    `json:"chapter,omitempty"`
	Verse   int    `json:"verse,omitempty"`
	Text    string `json:"text"`
}

// ModelProfile defines the token budget for a specific model.
type ModelProfile struct {
	Name          string // Ollama model name
	ContextWindow int    // total tokens the model supports
	TokensPerWord float64 // rough estimate: English ≈ 1.3 tokens/word
}

// Known model profiles. Conservative estimates — leave room for the prompt
// template and response tokens.
var ModelProfiles = map[string]ModelProfile{
	"mistral":      {Name: "mistral", ContextWindow: 8192, TokensPerWord: 1.3},
	"llama3.1:8b":  {Name: "llama3.1:8b", ContextWindow: 8192, TokensPerWord: 1.3},
	"gemma2:9b":    {Name: "gemma2:9b", ContextWindow: 8192, TokensPerWord: 1.3},
	"phi3:mini":    {Name: "phi3:mini", ContextWindow: 4096, TokensPerWord: 1.3},
	"mistral-nemo": {Name: "mistral-nemo", ContextWindow: 128000, TokensPerWord: 1.3},
}

// DefaultProfile is used when the model isn't in the known profiles map.
// Assumes a conservative 4K context window.
var DefaultProfile = ModelProfile{
	ContextWindow: 4096,
	TokensPerWord: 1.3,
}

// ChunkBudget computes how many words of transcript fit in one chunk,
// given the model's context window.
//
// Budget split:
//   prompt template + instructions ≈ 500 tokens
//   response                       ≈ 1024 tokens
//   transcript chunk               = remainder
func (p ModelProfile) ChunkBudget() int {
	const promptOverhead = 500   // tokens for the prompt template
	const responseReserve = 1024 // tokens reserved for model output

	available := p.ContextWindow - promptOverhead - responseReserve
	if available < 500 {
		available = 500
	}
	return int(float64(available) / p.TokensPerWord)
}

// PipelineResult holds the full output of all three stages, for debugging.
type PipelineResult struct {
	ChunkSummaries []string      // Stage 1 output: one summary per chunk
	MergedSummary  string        // Stage 2 output: combined narrative summary
	Metadata       *SermonSummary // Stage 3 output: structured JSON
}
