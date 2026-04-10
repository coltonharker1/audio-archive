package summarize

import "fmt"

// ---- Stage 1: Chunk Summarization ----

const chunkPrompt = `You are analyzing a section of a sermon transcript. The transcript was automatically generated from an audio recording and may contain errors, misspellings, or unclear passages.

This is section %d of %d from the full sermon.

Summarize this section in 3-4 paragraphs. Your summary MUST preserve specific details from the original text, not generalize them.

REQUIRED — extract and preserve these specifics verbatim if present:
- Bible passages: always include book name AND chapter:verse when stated (e.g. "Revelation 13:4", "Matthew 4:5-11")
- Named organizations, groups, or movements (e.g. "the Church of Satan", "ecumenical movement")
- Specific people or leaders mentioned (e.g. "President Johnson", "de Gaulle", "Judas Iscariot")
- Specific numbers, statistics, or dates (e.g. "5,000 members", "42 months", "1960")
- Historical events or current events the preacher references
- Direct quotes or striking phrases (in quotation marks)

Do NOT replace specifics with general categories. If the preacher says "the Church of Satan has 5,000 members in California", write that — do not write "a satanic organization exists".

TRANSCRIPT SECTION:
%s

Write your summary as 3-4 paragraphs of plain text. Include every specific Bible reference, name, organization, and number that appears in this section.`

// ---- Stage 2: Summary Merge ----

const mergePrompt = `You are producing a unified summary of a sermon. Below are summaries of consecutive sections of the sermon, written in order.

Combine them into a single coherent 4-6 paragraph narrative summary. The summary MUST preserve every specific detail from the section summaries — do not generalize or drop specifics.

Preserve verbatim:
- ALL Bible references with chapter:verse (e.g. "Revelation 13:4", not just "Revelation")
- ALL named organizations (e.g. "Church of Satan")
- ALL named people (e.g. "President Johnson", "de Gaulle", "Judas")
- ALL numbers and statistics (e.g. "5,000 members", "42 months")
- ALL direct quotes shown in quotation marks
- Any mentions of specific historical events, current events, or cultural context

SECTION SUMMARIES:
%s

Write the combined summary as plain text, 4-6 paragraphs. If specific details appear in any section summary, they MUST appear in your combined summary. Do not reduce specifics to general categories.`

// ---- Stage 3: Structured Metadata Extraction ----

const extractPrompt = `You are extracting structured metadata from a sermon. The original was transcribed from audio and may contain speech-to-text errors in names and references.

You are given TWO sources:

=== SOURCE A: Narrative Summary (use for topics, themes, long summary, title) ===
%s

=== SOURCE B: Detailed Section Summaries (use this for Bible references, historical references, quotes — it contains more specifics) ===
%s

When extracting bible_references, historical_references, and notable_quotes, scan SOURCE B carefully — it preserves details that SOURCE A may have compressed away. When writing summary_short, summary_long, main_topics, and notable_themes, lean on SOURCE A.

Respond with a JSON object containing EVERY field listed below. Do not omit any field — use empty arrays or empty strings for fields you cannot fill.

EXTRACTION PROCESS:
Before writing JSON, scan the entire summary and count:
  - Every "Book Chapter:Verse" pattern (e.g. "Genesis 12:1", "Psalm 23:4", "John 3:16")
  - Every named person, organization, movement, or historical event
  - Every quoted statement (text in quotes)
You must include ALL of them in the JSON. A typical sermon mentions 5-15 Bible passages — if you emit only 1 or 2, you are missing most of them.

Below is an EXAMPLE from a DIFFERENT sermon (about Abraham's faith). Do NOT copy content from this example — use it only to understand the structure and density expected. Your output must describe the actual sermon summary provided above, not Abraham.

EXAMPLE (for structure reference only — do not copy the content):
{
  "summary_short": "A teaching on Abraham's journey of faith from Ur to Canaan and its lessons for believers today",
  "summary_long": "The preacher traces Abraham's call out of Ur of the Chaldees, his pilgrimage through Canaan, and the moments where his faith was tested. Key moments include leaving his homeland, his encounter with Melchizedek, and the covenant God made with him. The sermon draws parallels between Abraham's obedience and the Christian walk of faith today.",
  "main_topics": ["Abraham's Call", "Pilgrimage of Faith", "God's Covenant"],
  "notable_themes": ["obedience to God's call", "faith tested through trials", "divine covenant"],
  "bible_references": [
    {"book": "Genesis", "chapter": 12, "verse": 1, "text": "God calls Abraham to leave Ur"},
    {"book": "Genesis", "chapter": 14, "verse": 18, "text": "Abraham meets Melchizedek king of Salem"},
    {"book": "Genesis", "chapter": 15, "verse": 6, "text": "Abraham believed God and it was counted as righteousness"},
    {"book": "Hebrews", "chapter": 11, "verse": 8, "text": "Abraham obeyed and went out not knowing where he was going"},
    {"book": "Romans", "chapter": 4, "verse": 3, "text": "Paul cites Abraham as the example of justification by faith"}
  ],
  "historical_references": [
    "Ur of the Chaldees as an ancient Sumerian city",
    "The Hittite nation during Abraham's time"
  ],
  "notable_quotes": [
    "Abraham went out not knowing where he was going, but he knew who was leading him",
    "Faith does not require a map, only a compass that points to God"
  ],
  "tags": ["abraham", "faith", "genesis", "covenant", "pilgrimage", "obedience", "melchizedek"],
  "suggested_title": "Abraham: A Pilgrimage of Faith",
  "suggested_speaker": "",
  "estimated_era": ""
}

IMPORTANT:
- The example above is about Abraham. Your actual output must describe the sermon summary provided at the top of this prompt, which is about a different topic entirely.
- Match the DENSITY of the example: aim for 5+ bible_references, 2+ historical_references, 7+ tags when the summary supports it.
- Extract content from the ACTUAL SUMMARY, never from the example.

FIELD RULES:

summary_short: exactly 1 sentence.

main_topics: 3-5 entries, short noun phrases.

notable_themes: list theological concepts (e.g. "spiritual warfare", "eternal judgment", "salvation by faith"). If none clear, use empty array [].

bible_references: list EVERY Bible passage mentioned in the summary. For each one:
  - "book" must be the proper book name (fix obvious transcription errors: "revelations" → "Revelation")
  - "chapter" must be an integer — use 0 ONLY if no chapter is stated
  - "verse" must be an integer — use 0 ONLY if no verse is stated; for a range like "4-10" use the starting verse 4
  - "text" must briefly describe how the passage was used
  - Scan the summary carefully — if you see "Revelation 13:4" or "Matthew 4:5-11", you MUST include chapter and verse as integers

historical_references: list EVERY named entity mentioned in the summary that is not part of a Bible verse quote. This includes:
  - Biblical figures mentioned as examples (e.g. "Adam and Eve as examples of salvation by faith", "Judas Iscariot as possessed by Satan")
  - Theological or religious movements (e.g. "ecumenical movement", "first church of Satan")
  - Modern or historical people, places, organizations (e.g. "President Johnson", "World War II", "California")
  - Specific numbers or statistics tied to real-world context (e.g. "5,000 members", "144,000 Jewish evangelists")
  - Any group, tribe, or nation mentioned
If the summary names any entity that has a proper noun or specific identity, add it here. Do not leave this empty unless the summary truly mentions no named entities at all.

notable_quotes: 2-4 direct or near-direct quotes from the sermon. Empty array [] if none obvious.

tags: 5-10 entries, all lowercase, short single words or hyphenated phrases. No capitals. No spaces (use hyphens).

suggested_title: a clear descriptive title.

suggested_speaker: empty string "" unless the summary explicitly names the speaker.

estimated_era: empty string "" unless the summary contains specific time clues. If the summary mentions "President Johnson" or "de Gaulle", the era is "1960s". Do NOT write "Unknown" — use empty string "" instead.

Respond with ONLY the JSON object. No markdown fences, no preamble, no explanation.`

// ---- Repair prompt for malformed JSON ----

const repairPrompt = `The following text was supposed to be valid JSON but has errors. Fix it so it is valid JSON matching the structure described.

Expected structure: a JSON object with these string/array fields: summary_short, summary_long, main_topics, notable_themes, bible_references, historical_references, notable_quotes, tags, suggested_title, suggested_speaker, estimated_era.

Broken JSON:
%s

Respond with ONLY the corrected valid JSON object. No explanation, no markdown fences.`

func fmtChunkPrompt(chunkNum, totalChunks int, text string) string {
	return fmt.Sprintf(chunkPrompt, chunkNum, totalChunks, text)
}

func fmtMergePrompt(sectionSummaries string) string {
	return fmt.Sprintf(mergePrompt, sectionSummaries)
}

func fmtExtractPrompt(mergedSummary, chunkSummaries string) string {
	return fmt.Sprintf(extractPrompt, mergedSummary, chunkSummaries)
}

func fmtRepairPrompt(brokenJSON string) string {
	return fmt.Sprintf(repairPrompt, brokenJSON)
}
