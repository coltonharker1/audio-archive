"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { Segment } from "@/lib/types";

interface Props {
  recordingId: number;
  transcriptId: number | null;
  audioSrc: string | null;
  initialFullText: string;
  initialSegments: Segment[] | null;
}

export function RecordingPlayback({
  recordingId: _recordingId,
  transcriptId,
  audioSrc,
  initialFullText,
  initialSegments,
}: Props) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const [activeIdx, setActiveIdx] = useState<number | null>(null);
  const [editing, setEditing] = useState(false);
  const [draftText, setDraftText] = useState(initialFullText);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const router = useRouter();

  const segments = initialSegments;

  useEffect(() => {
    if (!audioRef.current || !segments?.length) return;
    const audio = audioRef.current;

    function update() {
      if (!segments) return;
      const t = audio.currentTime;
      let idx: number | null = null;
      for (let i = 0; i < segments.length; i++) {
        if (t >= segments[i].start && t < segments[i].end) {
          idx = i;
          break;
        }
      }
      setActiveIdx(idx);
    }

    audio.addEventListener("timeupdate", update);
    return () => audio.removeEventListener("timeupdate", update);
  }, [segments]);

  useEffect(() => {
    if (activeIdx === null || !containerRef.current) return;
    const el = containerRef.current.querySelector(
      `[data-seg="${activeIdx}"]`
    ) as HTMLElement | null;
    if (el) {
      el.scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  }, [activeIdx]);

  function seekTo(seconds: number) {
    if (!audioRef.current) return;
    audioRef.current.currentTime = seconds;
    audioRef.current.play().catch(() => {});
  }

  async function saveEdit() {
    if (!transcriptId) return;
    setError(null);
    try {
      const res = await fetch(`/api/transcripts/${transcriptId}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          fullText: draftText,
          // Editing the full text invalidates segment timestamps unless the
          // user only fixed typos. We preserve existing segments — the user
          // will need to re-transcribe to regenerate them with new timing.
          segments: segments,
        }),
      });
      if (!res.ok) throw new Error(`save failed: ${res.status}`);
      setEditing(false);
      startTransition(() => router.refresh());
    } catch (e) {
      setError(e instanceof Error ? e.message : "unknown");
    }
  }

  function cancelEdit() {
    setDraftText(initialFullText);
    setEditing(false);
    setError(null);
  }

  return (
    <div className="space-y-4">
      {audioSrc && (
        <audio
          ref={audioRef}
          controls
          preload="metadata"
          className="w-full"
          src={audioSrc}
        />
      )}

      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-neutral-500">
          Transcript
        </h2>
        <div className="flex items-center gap-2">
          {editing ? (
            <>
              {error && (
                <span className="text-xs text-red-600 dark:text-red-400">
                  {error}
                </span>
              )}
              <button
                onClick={cancelEdit}
                disabled={pending}
                className="px-2 py-1 text-xs rounded border border-neutral-300 dark:border-neutral-700 hover:bg-neutral-50 dark:hover:bg-neutral-900"
              >
                Cancel
              </button>
              <button
                onClick={saveEdit}
                disabled={pending || draftText === initialFullText}
                className="px-2 py-1 text-xs rounded bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 disabled:opacity-40"
              >
                Save
              </button>
            </>
          ) : (
            transcriptId && (
              <button
                onClick={() => {
                  setDraftText(initialFullText);
                  setEditing(true);
                }}
                className="px-2 py-1 text-xs rounded border border-neutral-300 dark:border-neutral-700 hover:bg-neutral-50 dark:hover:bg-neutral-900"
              >
                Edit
              </button>
            )
          )}
        </div>
      </div>

      {editing ? (
        <textarea
          value={draftText}
          onChange={(e) => setDraftText(e.target.value)}
          rows={20}
          className="w-full rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 p-3 text-sm font-mono leading-relaxed"
        />
      ) : segments && segments.length > 0 ? (
        <div
          ref={containerRef}
          className="text-sm leading-relaxed bg-neutral-50 dark:bg-neutral-900 rounded-lg p-4 max-h-96 overflow-y-auto"
        >
          {segments.map((seg, i) => (
            <span
              key={i}
              data-seg={i}
              onClick={() => seekTo(seg.start)}
              className={
                "cursor-pointer rounded px-0.5 transition-colors " +
                (activeIdx === i
                  ? "bg-yellow-200 dark:bg-yellow-700/40 text-neutral-900 dark:text-neutral-100"
                  : "hover:bg-neutral-200 dark:hover:bg-neutral-800")
              }
              title={`${formatTime(seg.start)} → ${formatTime(seg.end)} — click to seek`}
            >
              {seg.text}
              {" "}
            </span>
          ))}
        </div>
      ) : (
        <div className="text-sm leading-relaxed bg-neutral-50 dark:bg-neutral-900 rounded-lg p-4 max-h-96 overflow-y-auto whitespace-pre-wrap">
          {initialFullText}
        </div>
      )}

      {!editing && segments && segments.length > 0 && (
        <p className="text-xs text-neutral-500">
          Click any line to jump there. Active line highlights as audio plays.
        </p>
      )}
    </div>
  );
}

function formatTime(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}
