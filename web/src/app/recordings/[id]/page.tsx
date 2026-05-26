import Link from "next/link";
import { notFound } from "next/navigation";
import {
  getRecording,
  getTranscript,
  getSummary,
  getJobs,
  getGroupRecordings,
} from "@/lib/queries";
import { formatDuration } from "@/lib/format";
import type { RecordingSummaryMeta, Segment } from "@/lib/types";
import { ContextEditor } from "./components/ContextEditor";
import { ActionPanel } from "./components/ActionPanel";
import { ApprovalToggle } from "./components/ApprovalToggle";
import { RecordingPlayback } from "./components/RecordingPlayback";

export const dynamic = "force-dynamic";

function Tag({ label }: { label: string }) {
  return (
    <span className="inline-block px-2 py-0.5 rounded-full text-xs bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">
      {label}
    </span>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="space-y-2">
      <h2 className="text-sm font-semibold uppercase tracking-wider text-neutral-500">
        {title}
      </h2>
      {children}
    </section>
  );
}

function JobStatusDot({ status }: { status: string }) {
  const colors: Record<string, string> = {
    complete: "bg-green-500",
    running: "bg-yellow-500 animate-pulse",
    pending: "bg-neutral-300 dark:bg-neutral-600",
    failed: "bg-red-500",
  };
  return (
    <span
      className={`inline-block w-2 h-2 rounded-full ${colors[status] || colors.pending}`}
    />
  );
}

export default async function RecordingPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const recordingId = parseInt(id, 10);
  if (isNaN(recordingId)) notFound();

  const recording = getRecording(recordingId);
  if (!recording) notFound();

  const transcript = getTranscript(recordingId);
  const summary = getSummary(recordingId);
  const jobs = getJobs(recordingId);
  const groupMembers = recording.group_id
    ? getGroupRecordings(recording.group_id)
    : [];

  let meta: RecordingSummaryMeta | null = null;
  if (summary?.metadata) {
    try {
      meta = JSON.parse(summary.metadata);
    } catch {
      meta = null;
    }
  }

  let segments: Segment[] | null = null;
  if (transcript?.segments) {
    try {
      const parsed = JSON.parse(transcript.segments);
      if (Array.isArray(parsed)) segments = parsed;
    } catch {
      segments = null;
    }
  }

  return (
    <div className="max-w-4xl mx-auto space-y-8">
      <div>
        <Link
          href="/"
          className="text-sm text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
        >
          &larr; All recordings
        </Link>
      </div>

      <div className="space-y-2">
        <div className="flex items-start justify-between gap-4">
          <h1 className="text-2xl font-bold">
            {recording.title || recording.slug}
          </h1>
          <ApprovalToggle
            recordingId={recording.id}
            initialApproved={!!recording.approved_at}
          />
        </div>
        <div className="flex items-center gap-4 text-sm text-neutral-500">
          {recording.speaker && <span>{recording.speaker}</span>}
          <span>{formatDuration(recording.duration_ms)}</span>
          {recording.date && <span>{recording.date}</span>}
          {recording.synced_at && (
            <span className="text-green-600 dark:text-green-400">
              Synced {recording.remanence_catalog_number || ""}
            </span>
          )}
        </div>
      </div>

      <RecordingPlayback
        recordingId={recording.id}
        transcriptId={transcript?.id ?? null}
        audioSrc={
          recording.prep_path
            ? `/api/recordings/${recording.id}/audio`
            : null
        }
        initialFullText={transcript?.full_text || ""}
        initialSegments={segments}
      />

      <Section title="Actions">
        <ActionPanel recordingId={recording.id} />
      </Section>

      <Section title="Context">
        <ContextEditor
          recordingId={recording.id}
          initialContext={recording.context || ""}
        />
      </Section>

      {meta && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <Section title="Summary">
            <p className="text-sm leading-relaxed whitespace-pre-line">
              {meta.summary_long}
            </p>
          </Section>

          <div className="space-y-6">
            {meta.main_topics.length > 0 && (
              <Section title="Topics">
                <div className="flex flex-wrap gap-1.5">
                  {meta.main_topics.map((t) => (
                    <Tag key={t} label={t} />
                  ))}
                </div>
              </Section>
            )}

            {meta.tags.length > 0 && (
              <Section title="Tags">
                <div className="flex flex-wrap gap-1.5">
                  {meta.tags.map((t) => (
                    <Tag key={t} label={t} />
                  ))}
                </div>
              </Section>
            )}

            {meta.people.length > 0 && (
              <Section title="People">
                <ul className="text-sm space-y-0.5">
                  {meta.people.map((p) => (
                    <li key={p}>{p}</li>
                  ))}
                </ul>
              </Section>
            )}

            {meta.places.length > 0 && (
              <Section title="Places">
                <ul className="text-sm space-y-0.5">
                  {meta.places.map((p) => (
                    <li key={p}>{p}</li>
                  ))}
                </ul>
              </Section>
            )}

            {meta.organizations.length > 0 && (
              <Section title="Organizations">
                <ul className="text-sm space-y-0.5">
                  {meta.organizations.map((o) => (
                    <li key={o}>{o}</li>
                  ))}
                </ul>
              </Section>
            )}

            {meta.notable_quotes.length > 0 && (
              <Section title="Notable Quotes">
                <ul className="text-sm space-y-2">
                  {meta.notable_quotes.map((q, i) => (
                    <li key={i} className="italic border-l-2 border-neutral-300 pl-3">
                      &ldquo;{q}&rdquo;
                    </li>
                  ))}
                </ul>
              </Section>
            )}

            <Section title="Details">
              <dl className="text-sm grid grid-cols-2 gap-x-4 gap-y-1">
                <dt className="text-neutral-500">Type</dt>
                <dd>{meta.recording_type}</dd>
                <dt className="text-neutral-500">Confidence</dt>
                <dd>{meta.type_confidence}</dd>
                {meta.mood && (
                  <>
                    <dt className="text-neutral-500">Mood</dt>
                    <dd>{meta.mood}</dd>
                  </>
                )}
                {meta.estimated_era && (
                  <>
                    <dt className="text-neutral-500">Era</dt>
                    <dd>{meta.estimated_era}</dd>
                  </>
                )}
              </dl>
            </Section>
          </div>
        </div>
      )}

      {groupMembers.length > 1 && (
        <Section title={`Group: ${recording.group_title || "Untitled"}`}>
          <ul className="text-sm space-y-1">
            {groupMembers.map((m) => (
              <li key={m.id}>
                {m.id === recording.id ? (
                  <span className="font-medium">
                    {m.title || m.slug} (current)
                  </span>
                ) : (
                  <Link
                    href={`/recordings/${m.id}`}
                    className="text-blue-600 dark:text-blue-400 hover:underline"
                  >
                    {m.title || m.slug}
                  </Link>
                )}
              </li>
            ))}
          </ul>
        </Section>
      )}

      <Section title="Jobs">
        <div className="text-sm space-y-1">
          {jobs.map((job) => (
            <div key={job.id} className="flex items-center gap-3">
              <JobStatusDot status={job.status} />
              <span className="font-mono w-24">{job.type}</span>
              {job.model && (
                <span className="text-xs px-1.5 py-0.5 rounded bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">
                  {job.model}
                </span>
              )}
              <span className="text-neutral-500 text-xs">
                attempt {job.attempt}/{job.max_retries}
              </span>
              {job.error && (
                <span className="text-red-500 truncate max-w-md text-xs">
                  {job.error}
                </span>
              )}
            </div>
          ))}
        </div>
      </Section>
    </div>
  );
}
