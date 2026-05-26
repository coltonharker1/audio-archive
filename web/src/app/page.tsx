import Link from "next/link";
import { getRecordings } from "@/lib/queries";
import { formatDuration } from "@/lib/format";

export const dynamic = "force-dynamic";

function StatusBadge({
  synced,
  approved,
}: {
  synced: boolean;
  approved: boolean;
}) {
  if (synced) {
    return (
      <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200">
        Synced
      </span>
    );
  }
  if (approved) {
    return (
      <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200">
        Approved
      </span>
    );
  }
  return (
    <span className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
      Local
    </span>
  );
}

export default function Home() {
  const recordings = getRecordings();

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <h1 className="text-2xl font-bold">Recordings</h1>

      <div className="border border-neutral-200 dark:border-neutral-800 rounded-lg overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-neutral-50 dark:bg-neutral-900 text-left text-neutral-500 text-xs uppercase tracking-wider">
              <th className="px-4 py-3 w-12">ID</th>
              <th className="px-4 py-3">Title</th>
              <th className="px-4 py-3 w-32">Speaker</th>
              <th className="px-4 py-3 w-24">Duration</th>
              <th className="px-4 py-3 w-28">Date</th>
              <th className="px-4 py-3 w-20">Status</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-neutral-100 dark:divide-neutral-800">
            {recordings.map((rec) => (
              <tr
                key={rec.id}
                className="hover:bg-neutral-50 dark:hover:bg-neutral-900/50 transition-colors"
              >
                <td className="px-4 py-3 text-neutral-400 font-mono">
                  {rec.id}
                </td>
                <td className="px-4 py-3">
                  <Link
                    href={`/recordings/${rec.id}`}
                    className="text-blue-600 dark:text-blue-400 hover:underline font-medium"
                  >
                    {rec.title || rec.slug}
                  </Link>
                  {rec.group_id && (
                    <span className="ml-2 text-xs text-neutral-400">
                      {rec.group_title || "group"}
                    </span>
                  )}
                </td>
                <td className="px-4 py-3 text-neutral-600 dark:text-neutral-400">
                  {rec.speaker || "—"}
                </td>
                <td className="px-4 py-3 font-mono text-neutral-600 dark:text-neutral-400">
                  {formatDuration(rec.duration_ms)}
                </td>
                <td className="px-4 py-3 text-neutral-600 dark:text-neutral-400">
                  {rec.date || "—"}
                </td>
                <td className="px-4 py-3">
                  <StatusBadge
                    synced={!!rec.synced_at}
                    approved={!!rec.approved_at}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
