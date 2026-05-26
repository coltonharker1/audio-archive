import { NextResponse } from "next/server";
import { updateTranscriptText } from "@/lib/mutations";

export const dynamic = "force-dynamic";

interface SegmentInput {
  start: number;
  end: number;
  text: string;
}

export async function PUT(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const transcriptId = parseInt(id, 10);
  if (isNaN(transcriptId)) {
    return NextResponse.json({ error: "Invalid ID" }, { status: 400 });
  }

  const body = (await request.json()) as {
    fullText?: string;
    segments?: SegmentInput[] | null;
  };

  if (typeof body.fullText !== "string") {
    return NextResponse.json(
      { error: "fullText required" },
      { status: 400 }
    );
  }

  const segments = Array.isArray(body.segments)
    ? body.segments.filter(
        (s): s is SegmentInput =>
          typeof s.start === "number" &&
          typeof s.end === "number" &&
          typeof s.text === "string"
      )
    : null;

  updateTranscriptText(transcriptId, body.fullText, segments);

  return NextResponse.json({ ok: true });
}
