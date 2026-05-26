import { NextResponse } from "next/server";
import { getRecording } from "@/lib/queries";
import { enqueueStages, type JobType } from "@/lib/mutations";
import { estimateSeconds, type Stage } from "@/lib/estimate";

export const dynamic = "force-dynamic";

const VALID_STAGES: JobType[] = ["prep", "transcribe", "summarize"];
const VALID_MODELS = ["base", "small", "medium", "large-v3"];

export async function POST(
  request: Request,
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

  const body = (await request.json()) as {
    stages: JobType[];
    model?: string;
  };

  if (!Array.isArray(body.stages) || body.stages.length === 0) {
    return NextResponse.json({ error: "stages required" }, { status: 400 });
  }
  for (const stage of body.stages) {
    if (!VALID_STAGES.includes(stage)) {
      return NextResponse.json(
        { error: `invalid stage: ${stage}` },
        { status: 400 }
      );
    }
  }
  if (body.model && !VALID_MODELS.includes(body.model)) {
    return NextResponse.json(
      { error: `invalid model: ${body.model}` },
      { status: 400 }
    );
  }

  const ids = enqueueStages(recordingId, body.stages, body.model);

  const totalEstimate = body.stages.reduce(
    (sum, s) =>
      sum + estimateSeconds(s as Stage, recording.duration_ms, body.model),
    0
  );

  return NextResponse.json({
    enqueued: ids,
    estimateSeconds: totalEstimate,
  });
}
