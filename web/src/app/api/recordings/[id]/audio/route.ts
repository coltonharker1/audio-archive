import { NextResponse } from "next/server";
import { getRecording } from "@/lib/queries";
import { ARCHIVE_ROOT } from "@/lib/db";
import path from "path";
import fs from "fs";

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
  if (!recording?.prep_path) {
    return NextResponse.json({ error: "No audio available" }, { status: 404 });
  }

  const audioPath = path.join(ARCHIVE_ROOT, recording.prep_path);
  if (!audioPath.startsWith(ARCHIVE_ROOT) || !fs.existsSync(audioPath)) {
    return NextResponse.json({ error: "File not found" }, { status: 404 });
  }

  const stat = fs.statSync(audioPath);
  const stream = fs.createReadStream(audioPath);

  return new Response(stream as unknown as ReadableStream, {
    headers: {
      "Content-Type": "audio/wav",
      "Content-Length": stat.size.toString(),
      "Accept-Ranges": "bytes",
    },
  });
}
