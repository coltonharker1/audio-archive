import { NextResponse } from "next/server";
import { getRecording } from "@/lib/queries";
import { estimateSeconds, formatEstimate, type Stage } from "@/lib/estimate";

export const dynamic = "force-dynamic";

const VALID_STAGES: Stage[] = ["prep", "transcribe", "summarize"];

export async function GET(
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

  const url = new URL(request.url);
  const stagesParam = url.searchParams.get("stages") || "prep,transcribe,summarize";
  const model = url.searchParams.get("model") || "base";

  const stages = stagesParam.split(",").filter((s): s is Stage =>
    VALID_STAGES.includes(s as Stage)
  );

  const breakdown = stages.map((stage) => {
    const seconds = estimateSeconds(stage, recording.duration_ms, model);
    return { stage, seconds, formatted: formatEstimate(seconds) };
  });

  const totalSeconds = breakdown.reduce((sum, b) => sum + b.seconds, 0);

  return NextResponse.json({
    breakdown,
    totalSeconds,
    totalFormatted: formatEstimate(totalSeconds),
  });
}
