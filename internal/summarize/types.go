package summarize

// RecordingType classifies what kind of audio recording this is.
// The extraction pipeline asks the LLM to pick one of these.
type RecordingType string

const (
	TypeSermon             RecordingType = "sermon"
	TypeVoicemail          RecordingType = "voicemail"
	TypePhoneCall          RecordingType = "phone_call"
	TypeInterview          RecordingType = "interview"
	TypeMeeting            RecordingType = "meeting"
	TypeMusicalPerformance RecordingType = "musical_performance"
	TypeAudioDiary         RecordingType = "audio_diary"
	TypeLecture            RecordingType = "lecture"
	TypeBroadcast          RecordingType = "broadcast"
	TypeFieldRecording     RecordingType = "field_recording"
	TypeOther              RecordingType = "other"
)

// KnownRecordingTypes lists every type the pipeline can classify into.
// Used in the extraction prompt so the LLM knows what's valid.
var KnownRecordingTypes = []RecordingType{
	TypeSermon,
	TypeVoicemail,
	TypePhoneCall,
	TypeInterview,
	TypeMeeting,
	TypeMusicalPerformance,
	TypeAudioDiary,
	TypeLecture,
	TypeBroadcast,
	TypeFieldRecording,
	TypeOther,
}

// RecordingSummary is the universal structured metadata extracted from
// any audio recording. It has a common core of fields that apply across
// all recording types, plus a TypeSpecific map for fields unique to
// the classified type (e.g. bible_references for sermons, caller_identity
// for voicemails, pieces for musical performances).
type RecordingSummary struct {
	// ---- Classification ----

	// RecordingType is what kind of recording this is, as classified by the LLM.
	RecordingType RecordingType `json:"recording_type"`

	// TypeConfidence is the LLM's confidence in its classification: high/medium/low.
	TypeConfidence string `json:"type_confidence"`

	// ---- Universal narrative fields ----

	SummaryShort   string `json:"summary_short"`   // 1-2 sentences
	SummaryLong    string `json:"summary_long"`    // 2-3 paragraphs
	SuggestedTitle string `json:"suggested_title"` // descriptive title

	// ---- Universal topical fields ----

	// MainTopics are the 3-5 primary subjects discussed.
	MainTopics []string `json:"main_topics"`

	// Themes are recurring concepts, motifs, or ideas (more abstract than topics).
	Themes []string `json:"themes"`

	// Tags are short lowercase keywords for search/filtering (5-10 entries).
	Tags []string `json:"tags"`

	// ---- Universal entity extraction ----

	// People are individuals named in the recording (speakers, subjects, mentioned).
	People []string `json:"people"`

	// Places are locations mentioned (cities, countries, landmarks, addresses).
	Places []string `json:"places"`

	// Organizations are named groups (companies, churches, schools, bands).
	Organizations []string `json:"organizations"`

	// DatesMentioned are any dates or time periods referenced in the recording.
	DatesMentioned []string `json:"dates_mentioned"`

	// ---- Temporal context (when was this recorded) ----

	// EstimatedEra is a broad time period like "1960s" or "early 2000s".
	EstimatedEra string `json:"estimated_era"`

	// EstimatedDate is an ISO date string if determinable, otherwise empty.
	EstimatedDate string `json:"estimated_date"`

	// ---- Moments and tone ----

	// NotableQuotes are 2-4 striking or memorable statements.
	NotableQuotes []string `json:"notable_quotes"`

	// Mood is the overall emotional tone: solemn/cheerful/urgent/intimate/etc.
	Mood string `json:"mood"`

	// ---- Participants ----

	// Speakers are the identified voices in the recording.
	Speakers []string `json:"speakers"`

	// ---- Practical info ----

	// ActionItems are tasks, requests, or follow-ups mentioned (common in
	// voicemails, meetings, phone calls).
	ActionItems []string `json:"action_items"`

	// ---- Type-specific extensions ----

	// TypeSpecific holds fields unique to the classified RecordingType.
	// Its shape varies by type. See typeSpecificFieldGuide for each type's
	// expected fields.
	TypeSpecific map[string]any `json:"type_specific"`
}

// typeSpecificFieldGuide describes the type-specific fields we want the LLM
// to populate for each recording type. It's used to build the extraction
// prompt, and as documentation for downstream consumers.
var typeSpecificFieldGuide = map[RecordingType][]typeSpecificField{
	TypeSermon: {
		{Name: "bible_references", Desc: "array of {book, chapter, verse, text} — every scripture passage mentioned"},
		{Name: "theological_themes", Desc: "array of strings — e.g. 'salvation', 'eschatology', 'grace'"},
		{Name: "scripture_focus", Desc: "primary passage the sermon is built around, e.g. 'Revelation 13'"},
		{Name: "preaching_style", Desc: "expository, topical, narrative, evangelistic, etc."},
	},
	TypeVoicemail: {
		{Name: "caller_identity", Desc: "name or description of who left the message"},
		{Name: "recipient", Desc: "who the message was for"},
		{Name: "callback_requested", Desc: "true/false — did they ask for a call back"},
		{Name: "urgency", Desc: "low, medium, or high"},
		{Name: "callback_number", Desc: "phone number to call back if given"},
	},
	TypePhoneCall: {
		{Name: "participants", Desc: "array of people on the call"},
		{Name: "call_purpose", Desc: "short description of what the call was about"},
	},
	TypeInterview: {
		{Name: "interviewer", Desc: "name of the host/interviewer"},
		{Name: "interviewee", Desc: "name of the subject being interviewed"},
		{Name: "questions_asked", Desc: "array of notable questions raised"},
	},
	TypeMeeting: {
		{Name: "attendees", Desc: "array of people present"},
		{Name: "agenda_items", Desc: "array of topics discussed"},
		{Name: "decisions", Desc: "array of decisions made"},
	},
	TypeMusicalPerformance: {
		{Name: "pieces", Desc: "array of {title, composer, duration_sec} for each piece performed"},
		{Name: "ensemble_type", Desc: "solo, duet, choir, band, orchestra, etc."},
		{Name: "soloists", Desc: "array of featured soloists"},
		{Name: "musical_style", Desc: "classical, jazz, folk, hymn, gospel, etc."},
		{Name: "estimated_key", Desc: "e.g. 'D major', 'E minor' if determinable"},
	},
	TypeAudioDiary: {
		{Name: "reflections", Desc: "array of personal reflections or observations"},
		{Name: "emotional_events", Desc: "array of significant emotional moments"},
		{Name: "referenced_memories", Desc: "array of past events the speaker recalls"},
	},
	TypeLecture: {
		{Name: "subject_area", Desc: "academic field or domain"},
		{Name: "key_concepts", Desc: "array of main concepts explained"},
		{Name: "cited_works", Desc: "array of books, papers, or sources cited"},
	},
	TypeBroadcast: {
		{Name: "show_name", Desc: "name of the show or program"},
		{Name: "host", Desc: "name of the host"},
		{Name: "guests", Desc: "array of guests"},
		{Name: "segments", Desc: "array of segments or topics covered"},
	},
	TypeFieldRecording: {
		{Name: "location", Desc: "where the recording was made"},
		{Name: "environment", Desc: "indoor/outdoor, urban/rural, etc."},
		{Name: "notable_sounds", Desc: "array of identifiable sounds (birds, traffic, etc.)"},
	},
	TypeOther: {
		// No fields — universal ones are enough
	},
}

type typeSpecificField struct {
	Name string
	Desc string
}

// ---- Model profiles ----

// ModelProfile defines the token budget for a specific Ollama model.
type ModelProfile struct {
	Name          string  // Ollama model name
	ContextWindow int     // total tokens the model supports
	TokensPerWord float64 // rough estimate: English ≈ 1.3 tokens/word
}

// ModelProfiles are conservative context-window estimates for supported models.
var ModelProfiles = map[string]ModelProfile{
	"mistral":      {Name: "mistral", ContextWindow: 8192, TokensPerWord: 1.3},
	"llama3.1:8b":  {Name: "llama3.1:8b", ContextWindow: 8192, TokensPerWord: 1.3},
	"gemma2:9b":    {Name: "gemma2:9b", ContextWindow: 8192, TokensPerWord: 1.3},
	"phi3:mini":    {Name: "phi3:mini", ContextWindow: 4096, TokensPerWord: 1.3},
	"mistral-nemo": {Name: "mistral-nemo", ContextWindow: 128000, TokensPerWord: 1.3},
}

// DefaultProfile is used when the model isn't in ModelProfiles.
var DefaultProfile = ModelProfile{
	ContextWindow: 4096,
	TokensPerWord: 1.3,
}

// ChunkBudget computes how many words fit in a single chunk, leaving room
// for the prompt template and the response.
func (p ModelProfile) ChunkBudget() int {
	const promptOverhead = 500
	const responseReserve = 1024

	available := p.ContextWindow - promptOverhead - responseReserve
	if available < 500 {
		available = 500
	}
	return int(float64(available) / p.TokensPerWord)
}

// PipelineResult holds the full output of all three stages, for debugging.
type PipelineResult struct {
	ChunkSummaries []string          // Stage 1: one summary per chunk
	MergedSummary  string            // Stage 2: combined narrative
	Metadata       *RecordingSummary // Stage 3: structured classification + extraction
}
