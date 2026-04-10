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

You are given TWO sources:

=== SOURCE A: Narrative Summary (use for topics, themes, long summary, title) ===
%s

=== SOURCE B: Detailed Section Summaries (use for entity extraction, quotes, references — it preserves details that SOURCE A may have compressed) ===
%s

`

const extractPromptSteps = `Follow these steps:

STEP 1: CLASSIFY the recording. Read both sources carefully and decide which ONE of these types best fits:

%s

Set "recording_type" to your choice and "type_confidence" to "high", "medium", or "low".

STEP 2: Extract UNIVERSAL fields that apply to any recording:

- summary_short: 1 sentence describing what this recording is
- summary_long: 2-3 paragraphs covering the main content and flow
- suggested_title: a clear descriptive title
- main_topics: 3-5 primary subjects discussed (noun phrases)
- themes: recurring concepts or motifs
- tags: 5-10 short lowercase keywords for search (single words or hyphenated)
- people: every individual named in the recording
- places: every location mentioned
- organizations: every group, company, church, band, or institution named
- dates_mentioned: specific dates, years, or time periods referenced
- estimated_era: rough time period when this was recorded (e.g. "1960s"), or empty string
- estimated_date: ISO date if determinable, otherwise empty string
- notable_quotes: 2-4 striking or memorable statements
- mood: overall emotional tone (solemn, cheerful, urgent, intimate, conversational, etc.)
- speakers: identifiable voices in the recording
- action_items: tasks, requests, or callbacks mentioned (empty array if none)

STEP 3: Based on the recording_type you chose in STEP 1, populate the "type_specific" object with fields relevant to that type.

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
func fmtExtractPrompt(mergedSummary, chunkSummaries string) string {
	header := fmt.Sprintf(extractPromptHeader, mergedSummary, chunkSummaries)
	steps := fmt.Sprintf(extractPromptSteps,
		buildTypeTaxonomy(),
		buildTypeSpecificGuide())
	return header + steps
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
