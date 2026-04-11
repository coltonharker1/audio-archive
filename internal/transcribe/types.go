package transcribe

// Segment represents a timed transcript segment. Times are in seconds.
type Segment struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Text  string  `json:"text"`
}

// Result is the backend-agnostic transcription output. Both the whisper.cpp
// path (RunWhisperCpp) and any future alternate backends produce the same
// shape so TranscribeRecording doesn't care which engine ran.
type Result struct {
	Language            string    `json:"language"`
	LanguageProbability float64   `json:"language_probability"`
	Duration            float64   `json:"duration"`
	Segments            []Segment `json:"segments"`
	FullText            string    `json:"full_text"`
}
