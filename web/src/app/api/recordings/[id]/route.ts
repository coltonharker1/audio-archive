import { NextResponse } from "next/server";
import { getRecording, getTranscript, getSummary, getJobs } from "@/lib/queries";
import { updateContext, setApproval } from "@/lib/mutations";

export const dynamic = "force-dynamic";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const recordingId = parseInt(id, 10);
  if (isNaN(recordingId)) {
    return NextResponse.json({ error: "Invalid ID" }, { status: 400 });
  }

  const recording = getRecording(recordingId);
  if (!recording) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  const transcript = getTranscript(recordingId);
  const summary = getSummary(recordingId);
  const jobs = getJobs(recordingId);

  let summaryMeta = null;
  if (summary?.metadata) {
    try {
      summaryMeta = JSON.parse(summary.metadata);
    } catch {
      summaryMeta = null;
    }
  }

  let segments = null;
  if (transcript?.segments) {
    try {
      segments = JSON.parse(transcript.segments);
    } catch {
      segments = null;
    }
  }

  return NextResponse.json({
    recording,
    transcript: transcript
      ? { ...transcript, segments }
      : null,
    summary: summary
      ? { ...summary, metadata: summaryMeta }
      : null,
    jobs,
  });
}

export async function PATCH(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const recordingId = parseInt(id, 10);
  if (isNaN(recordingId)) {
    return NextResponse.json({ error: "Invalid ID" }, { status: 400 });
  }
  if (!getRecording(recordingId)) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  const body = (await request.json()) as {
    context?: string;
    approved?: boolean;
  };

  if (typeof body.context === "string") {
    updateContext(recordingId, body.context);
  }
  if (typeof body.approved === "boolean") {
    setApproval(recordingId, body.approved);
  }

  return NextResponse.json({ ok: true });
}
