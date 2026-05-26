"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";

interface Props {
  recordingId: number;
  initialApproved: boolean;
}

export function ApprovalToggle({ recordingId, initialApproved }: Props) {
  const [approved, setApproved] = useState(initialApproved);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const router = useRouter();

  async function toggle() {
    setError(null);
    const next = !approved;
    setApproved(next);
    try {
      const res = await fetch(`/api/recordings/${recordingId}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ approved: next }),
      });
      if (!res.ok) throw new Error(`save failed: ${res.status}`);
      startTransition(() => router.refresh());
    } catch (e) {
      setApproved(!next);
      setError(e instanceof Error ? e.message : "unknown");
    }
  }

  return (
    <button
      onClick={toggle}
      disabled={pending}
      className={
        approved
          ? "px-3 py-1.5 text-sm rounded bg-green-600 text-white hover:bg-green-700 disabled:opacity-40"
          : "px-3 py-1.5 text-sm rounded border border-neutral-300 dark:border-neutral-700 hover:bg-neutral-50 dark:hover:bg-neutral-900 disabled:opacity-40"
      }
      title={error || (approved ? "Click to unapprove" : "Mark approved for sync")}
    >
      {approved ? "✓ Approved for sync" : "Mark approved"}
    </button>
  );
}
