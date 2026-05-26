import Link from "next/link";
import { search, type SearchHit } from "@/lib/queries";
import { formatDuration } from "@/lib/format";

export const dynamic = "force-dynamic";

interface Props {
  searchParams: Promise<{ q?: string }>;
}

function escapeFTS(query: string): string {
  return query
    .split(/\s+/)
    .filter(Boolean)
    .map((t) => `"${t.replace(/"/g, '""')}"`)
    .join(" ");
}

function highlightMatches(text: string, query: string): string {
  if (!text) return "";
  const escaped = text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
  const terms = query.split(/\s+/).filter(Boolean);
  let result = escaped;
  for (const term of terms) {
    const re = new RegExp(
      `(${term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`,
      "gi"
    );
    result = result.replace(re, "<mark>$1</mark>");
  }
  return result;
}

const SOURCE_LABEL: Record<SearchHit["source"], string> = {
  transcript: "transcript",
  title: "title",
  speaker: "speaker",
  metadata: "summary",
};

export default async function SearchPage({ searchParams }: Props) {
  const { q } = await searchParams;
  const query = (q || "").trim();

  let hits: SearchHit[] = [];
  let error: string | null = null;

  if (query) {
    try {
      hits = search({
        ftsQuery: escapeFTS(query),
        likeQuery: `%${query.replace(/[%_]/g, (m) => `\\${m}`)}%`,
      });
    } catch (e) {
      error = e instanceof Error ? e.message : "search failed";
    }
  }

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      <h1 className="text-2xl font-bold">Search</h1>

      <form method="GET" className="flex gap-2">
        <input
          type="text"
          name="q"
          defaultValue={query}
          placeholder="Search across all transcripts…"
          autoFocus
          className="flex-1 px-3 py-2 rounded border border-neutral-300 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-sm"
        />
        <button
          type="submit"
          className="px-4 py-2 rounded bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 text-sm font-medium"
        >
          Search
        </button>
      </form>

      {query && (
        <div className="text-sm text-neutral-500">
          {error
            ? `Error: ${error}`
            : hits.length === 0
              ? `No matches for "${query}"`
              : `${hits.length} ${hits.length === 1 ? "match" : "matches"} for "${query}"`}
        </div>
      )}

      <div className="space-y-3">
        {hits.map((hit, i) => {
          // Transcript snippets come from FTS5 with <mark> tags already.
          // Other sources are raw text — escape and highlight here.
          const html =
            hit.source === "transcript"
              ? hit.snippet
              : highlightMatches(hit.snippet, query);

          return (
            <Link
              key={`${hit.recording_id}-${i}`}
              href={`/recordings/${hit.recording_id}`}
              className="block p-4 rounded border border-neutral-200 dark:border-neutral-800 hover:bg-neutral-50 dark:hover:bg-neutral-900 transition-colors"
            >
              <div className="flex items-baseline justify-between gap-4 mb-1">
                <h2 className="font-medium text-blue-600 dark:text-blue-400">
                  {hit.title || `Recording ${hit.recording_id}`}
                </h2>
                <div className="text-xs text-neutral-500 shrink-0 flex items-center gap-3">
                  <span className="px-1.5 py-0.5 rounded bg-neutral-100 dark:bg-neutral-800 text-neutral-600 dark:text-neutral-400">
                    {SOURCE_LABEL[hit.source]}
                  </span>
                  {hit.speaker && <span>{hit.speaker}</span>}
                  {hit.date && <span>{hit.date}</span>}
                  <span className="font-mono">
                    {formatDuration(hit.duration_ms)}
                  </span>
                </div>
              </div>
              <p
                className="text-sm text-neutral-700 dark:text-neutral-300 leading-relaxed [&>mark]:bg-yellow-200 [&>mark]:text-neutral-900 dark:[&>mark]:bg-yellow-700/50 dark:[&>mark]:text-neutral-100 [&>mark]:px-0.5 [&>mark]:rounded"
                dangerouslySetInnerHTML={{ __html: html }}
              />
            </Link>
          );
        })}
      </div>
    </div>
  );
}
