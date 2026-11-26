Reviewer: grok-4.7-build-fast.


The plan lists every leaking prefix. I'll inspect the staged diff and the new sweep code against that list.

The staged temp-folder fix matches the approved plan. Every test path that used `temporaryDirectory` now goes through `TestFolders`, and both sweeps stay inside the bounds the plan set.

Test folders live under `$TMPDIR/remanence-tests/<pid>-<uuid>/`. Each test still gets its own UUID directory. Removal is only at process exit, so nothing is deleted while a test can still have a database open, and failing runs are not kept. The dead-run sweep deletes a sibling only when its name is `<pid>-<UUID>` and `kill(pid, 0)` fails with `ESRCH`, so a live run of another process is left alone, and a reused pid only delays cleanup. It never lists or deletes outside `remanence-tests`.

The app sweep runs in a detached task from `applicationDidFinishLaunching`, uses `try?` throughout, and only removes top-level `remanence-job-<UUID>` entries in the temp directory whose modification date is older than 24 hours. Library paths and masters are not in that set. `StaleWorkFolderTests` checks the old folder, a fresh one, the `remanence-jobs-` prefix, a non-UUID suffix, and a nested job folder. No debug logging, UI changes, or other behavior changes are in the diff.

No findings.

VERDICT: PASS
