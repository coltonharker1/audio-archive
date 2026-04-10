package summarize

import (
	"fmt"
	"strings"
)

// ---- Stage 1: Chunk Summarization ----

const chunkPrompt = `You are analyzing a section of an audio recording transcript. The transcript was automatically generated from an audio recording and may contain errors, misspellings, or unclear passages.

This is section %d of %d from the full recording.

Summarize this section in 3-4 paragraphs. Your summary MUST preserve specific details from the original text, not generalize them.

REQUIRED — extract and preserve these specifics verbatim if present:
- Named people, speakers, or subjects (e.g. "Pastor Smith", "Uncle Bob", "the narrator")
- Named places (cities, countries, buildings, addresses)
- Named organizations, groups, or movements (e.g. "the Salvation Army", "Metropolitan Opera")
- Specific dates, times, numbers, or statistics
- Bible passages with book and chapter:verse if mentioned (e.g. "Revelation 13:4")
- Direct quotes or striking phrases
- Musical pieces or composers if mentioned
- Action items, requests, or callbacks (common in voicemails or meetings)

Do NOT replace specifics with general categories. If the recording says "Uncle Bob called from Denver asking about Thanksgiving," write that — do not write "a family member called about a holiday".

TRANSCRIPT SECTION:
%s

Write your summary as 3-4 paragraphs of plain text. Include every specific name, place, number, and reference that appears in this section.`

// ---- Stage 2: Summary Merge ----

const mergePrompt = `You are producing a unified summary of an audio recording. Below are summaries of consecutive sections of the recording, written in order.

Combine them into a single coherent 4-6 paragraph narrative summary. The summary MUST preserve every specific detail from the section summaries — do not generalize or drop specifics.

Preserve verbatim:
- ALL named people, places, and organizations
- ALL specific dates, times, numbers, and statistics
- ALL Bible references with chapter:verse (if any)
- ALL direct quotes in quotation marks
- Any mentions of historical events, current events, or cultural context
- Any action items, requests, or follow-ups

SECTION SUMMARIES:
%s

Write the combined summary as plain text, 4-6 paragraphs. If specific details appear in any section summary, they MUST appear in your combined summary. Do not reduce specifics to general categories.`

// ---- Stage 3: Classification + Structured Extraction ----

const extractPromptHeader = `You are analyzing an audio recording and producing structured metadata. The recording was transcribed from audio, so there may be speech-to-text errors in names and references.

You are given the following inputs:

=== FILE METADATA (use as a classification signal, especially when speech is sparse) ===
%s

=== AUDIO SIGNAL HINT (critical for classification) ===
%s

=== SOURCE A: Narrative Summary (use for topics, themes, long summary, title) ===
%s

=== SOURCE B: Detailed Section Summaries (use for entity extraction, quotes, references — it preserves details that SOURCE A may have compressed) ===
%s

`

const extractPromptSteps = `Follow these steps:

STEP 1: CLASSIFY the recording. Read all sources (file metadata, audio signal hint, narrative summary, section summaries) and decide which ONE of these types best fits:

%s

Set "recording_type" to your choice and "type_confidence" to "high", "medium", or "low".

CLASSIFICATION RULES:

RULE 1 — FILE METADATA IS A STRONG SIGNAL. If the file title or source filename clearly matches a recording type, that is a very strong signal — use it unless the transcript directly contradicts it:
  - title contains "voicemail" or "vm" → voicemail
  - title contains "phone call", "call with", "conversation with" → phone_call
  - title contains "interview", "Q&A" → interview
  - title contains "meeting", "standup", "1:1" → meeting
  - title contains "sermon", "service", "homily" → sermon
  - title contains "concert", "performance", "recital", "choir", "band", "song", "music" → musical_performance
  - title contains "diary", "journal", "entry" → audio_diary
  - title contains "lecture", "class" → lecture
  - title contains "podcast", "radio", "episode", "broadcast" → broadcast

RULE 2 — ONE-SIDED SPEECH IS A VOICEMAIL. If the transcript shows only one person talking with no back-and-forth conversation and no responses, and especially if the audio contains spoken timestamps like "three forty two p.m. Wednesday" (which voicemail systems announce before each message), this is a voicemail — possibly multiple voicemails concatenated.

RULE 3 — TWO-WAY CONVERSATION IS A PHONE CALL. Only classify as phone_call if the transcript shows back-and-forth exchange between two or more speakers with responses.

STEP 2: Extract UNIVERSAL fields that apply to any recording.

Before writing the JSON, do a PROPER NOUN SCAN: read SOURCE B line by line and make a mental list of every capitalized name you see. Each one belongs in people, places, or organizations. If the transcript mentions "Martin" or "Johnny" or "Uncle Bob" — those are people. If it mentions "Oklahoma" or "Tulsa" or "Main Street" or "the church on Elm" — those are places. Do not skip proper nouns just because they're mentioned briefly.

Then extract these fields:

- summary_short: 1 sentence describing what this recording is
- summary_long: 2-3 paragraphs covering the main content and flow
- suggested_title: a clear descriptive title. Do NOT include absolute dates (like "April 10" or "2024-03-15") unless those dates are literally stated in the transcript. If the transcript only mentions relative times like "Wednesday" or "last week", do not convert them to specific dates in the title.
- main_topics: 3-5 primary subjects discussed (noun phrases)
- themes: recurring concepts or motifs
- tags: 5-10 short lowercase keywords for search (single words or hyphenated)

- people: EVERY individual named in the transcript by a proper name, regardless of whether they speak. This includes:
  * People being addressed (e.g. if the caller says "All right, Martin, bye" — Martin goes here even though Martin doesn't speak)
  * People mentioned in passing (e.g. "Johnny came over" — Johnny goes here)
  * People the speaker refers to (e.g. "I talked to Sarah" — Sarah goes here)
  First names, last names, nicknames count. Generic references like "the doctor", "my mom", "the pastor" do NOT count — only proper names. If the transcript names ANY person, they MUST appear here. This field should rarely be empty.

- places: EVERY location mentioned. Cities, states, countries, streets, neighborhoods, buildings, landmarks, businesses by name. "Oklahoma", "Tulsa", "New Orleans Road" are all places. If the transcript names a location, it MUST appear here.

- organizations: EVERY named group, company, church, band, school, or institution. "the electric company" does NOT count (not a proper name); "Microsoft" or "First Baptist Church" does.

- dates_mentioned: Copy dates and time references EXACTLY as they appear in the transcript. If the transcript says "Wednesday", put "Wednesday". If it says "last summer", put "last summer". If it says "three forty two p.m. Wednesday", put "3:42 p.m. Wednesday". DO NOT invent absolute dates like "2026-04-10" from relative references — you cannot know what Wednesday is meant. Only include ISO dates if they are literally stated in the transcript.

- estimated_era: rough time period when this was recorded (e.g. "1960s"), or empty string. Only fill if there are strong contextual clues.

- estimated_date: ISO date if determinable from strong contextual clues, otherwise empty string. Do not guess.

- notable_quotes: 2-4 striking or memorable direct quotes from the transcript.

- mood: overall emotional tone (solemn, cheerful, urgent, intimate, conversational, frustrated, etc.)

- speakers: ONLY voices actually HEARD in the recording. For a voicemail, this is usually 1 speaker (the caller) even if multiple messages are concatenated. For a phone call, it's 2+. For a meeting, it's the attendees who speak. A person who is addressed or mentioned but never speaks does NOT belong here — they belong in the people array instead. If you can identify a speaker by name from context, use the name; otherwise use descriptions like "Caller", "Speaker 1".

- action_items: Tasks, requests, commitments, future plans, or callbacks mentioned anywhere in the transcript. Look for phrases like "I'll call you", "don't forget", "we need to", "remember to", "see you at", "going to the X on Y", "Thursday", "tomorrow". Voicemails and meetings typically have 2-5 action items. If the speaker mentions a future event, that's an action item. Only return an empty array if the recording genuinely has no future-oriented statements.

STEP 3: Based on the recording_type you chose in STEP 1, populate the "type_specific" object with fields relevant to that type.

CRITICAL RULE FOR type_specific STRUCTURE:
The type-specific fields must go DIRECTLY at the top level of type_specific. Do NOT nest them inside a sub-object named after the recording type.

CORRECT:
  "type_specific": {
    "bible_references": [...],
    "theological_themes": [...]
  }

INCORRECT (do NOT do this):
  "type_specific": {
    "sermon": {
      "bible_references": [...],
      "theological_themes": [...]
    }
  }

TYPE-SPECIFIC FIELDS BY RECORDING TYPE:

%s

If the recording type is "other", leave type_specific as an empty object {}.

EXTRACTION RULES:
- Scan SOURCE B carefully for specifics — it contains details that SOURCE A may have compressed.
- A typical recording has multiple people, places, and quotes. Do not emit empty arrays unless the recording genuinely has none.
- Use empty strings "" or empty arrays [] for fields you truly cannot determine. Do NOT write "Unknown" or "N/A".
- Correct obvious transcription errors in proper names (e.g. "revelations" → "Revelation", "Obama" → "Obama").
- Tags must be lowercase. Use hyphens for multi-word tags.

Respond with ONLY the JSON object. No markdown fences, no explanation, no preamble.`

// ---- Repair prompt ----

const repairPrompt = `The following text was supposed to be valid JSON but has errors. Fix it so it is valid JSON matching the structure described.

Expected top-level fields: recording_type, type_confidence, summary_short, summary_long, suggested_title, main_topics, themes, tags, people, places, organizations, dates_mentioned, estimated_era, estimated_date, notable_quotes, mood, speakers, action_items, type_specific.

Broken JSON:
%s

Respond with ONLY the corrected valid JSON object. No explanation, no markdown fences.`

// ---- Prompt builders ----

func fmtChunkPrompt(chunkNum, totalChunks int, text string) string {
	return fmt.Sprintf(chunkPrompt, chunkNum, totalChunks, text)
}

func fmtMergePrompt(sectionSummaries string) string {
	return fmt.Sprintf(mergePrompt, sectionSummaries)
}

// fmtExtractPrompt builds the extraction prompt with classification taxonomy
// and per-type field guidance baked in dynamically from typeSpecificFieldGuide.
// The density hint and file context are injected so the classifier has
// multiple signals beyond just the transcript content.
func fmtExtractPrompt(mergedSummary, chunkSummaries string, density SpeechDensity, fileContext string) string {
	densityHint := formatDensityHint(density)
	header := fmt.Sprintf(extractPromptHeader, fileContext, densityHint, mergedSummary, chunkSummaries)
	steps := fmt.Sprintf(extractPromptSteps,
		buildTypeTaxonomy(),
		buildTypeSpecificGuide())
	return header + steps
}

// formatDensityHint produces the audio signal hint paragraph for the prompt.
// If density is unknown (zero), returns a neutral placeholder.
func formatDensityHint(d SpeechDensity) string {
	if d.Description == "" {
		return "No audio-level speech density information is available."
	}
	return d.Description
}

func fmtRepairPrompt(brokenJSON string) string {
	return fmt.Sprintf(repairPrompt, brokenJSON)
}

// buildTypeTaxonomy formats the list of known recording types with
// short descriptions for the classification step of the prompt.
func buildTypeTaxonomy() string {
	descriptions := map[RecordingType]string{
		TypeSermon:             "religious teaching, preaching, or Bible exposition",
		TypeVoicemail:          "a recorded message left on a phone (one-sided, short)",
		TypePhoneCall:          "a recorded two-way phone or video call conversation",
		TypeInterview:          "Q&A format with a host asking questions and a guest answering",
		TypeMeeting:            "multi-person discussion, often with an agenda or decisions",
		TypeMusicalPerformance: "singing, instrumental music, choir, concert, or recital",
		TypeAudioDiary:         "personal first-person journal entry or reflection",
		TypeLecture:            "academic or educational talk to an audience",
		TypeBroadcast:          "radio show, podcast, news segment, or on-air program",
		TypeFieldRecording:     "ambient, environmental, or location-based audio with minimal speech",
		TypeOther:              "anything that doesn't fit the categories above",
	}

	var b strings.Builder
	for _, rt := range KnownRecordingTypes {
		fmt.Fprintf(&b, "  - %s — %s\n", rt, descriptions[rt])
	}
	return b.String()
}

// buildTypeSpecificGuide formats the type-specific field guide for inclusion
// in the extraction prompt, so the LLM knows what extra fields to populate
// for each recording type.
func buildTypeSpecificGuide() string {
	var b strings.Builder
	for _, rt := range KnownRecordingTypes {
		fields := typeSpecificFieldGuide[rt]
		if len(fields) == 0 {
			continue
		}
		fmt.Fprintf(&b, "\nIf recording_type is \"%s\":\n", rt)
		for _, f := range fields {
			fmt.Fprintf(&b, "  - %s: %s\n", f.Name, f.Desc)
		}
	}
	return b.String()
}
