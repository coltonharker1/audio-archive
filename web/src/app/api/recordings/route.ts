import { NextResponse } from "next/server";
import { getRecordings } from "@/lib/queries";

export const dynamic = "force-dynamic";

export function GET() {
  const recordings = getRecordings();
  return NextResponse.json(recordings);
}
