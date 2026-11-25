I'll review the staged collection-save fixes against the findings notes and the redesign rules, without changing anything.

The review is read-only and covers only the staged collection-save fixes. I'll read the fix notes and the cached diff first, then check each claim against the redesign rules.

The three Phase 12 findings are fixed, and the staged diff stays inside that work. Push, Publish, Unpublish, and Send Changes now wait for a library write that already started. A blank name is put back when the edit sheet closes. A confirmed on-site delete holds the site sheet's buttons until that removal is underway.

`saveNow()` keeps each library write in `pendingWrite`, chained after the write before it. `saveAndWait()` waits for that task, then writes anything still unsaved. Closing the edit or photos sheet still goes through `saveNow()`, and Push, Send Changes, Publish, Unpublish, and Delete go through `saveAndWait()`, so a send sees the text that was just saved. Caption writes still run in a detached task. The name and details still go through `performDetached`.

`CollectionFields.keepingName(_:)` matches `saveCollection`: a blank or whitespace-only name is replaced with the stored name, and a typed name is left as it is. Sheet dismiss calls `keepName()` on both `fields` and `saved` before `saveNow()`, so reopening Edit collection shows that name and a blank name alone does not start another write. `aBlankNameIsKeptAndTheFieldsShowTheKeptOne` covers the library keep and the field restore.

Deleting a collection that is on the site sets `isDeleting` before `saveAndWait()`. The site sheet disables Remove from Site, Push, Send Changes, and Publish/Unpublish while that is set, and the remove confirmation returns without sending. `isDeleting` clears only after `removeCollectionFromSite(_:andHere: true)`, which sets `syncingCollectionID` before it returns, so `isPushing` keeps those buttons disabled for the rest of the removal. The progress spinner still follows `syncingCollectionID` only.

Nothing else from the phase review was skipped. The diff is those three files. Masters are untouched. Push and Send Changes still call `send(nil)`, so a first push stays an unpublished draft. The site clock and `CollectionSync` are untouched. The reported run is 445 tests, including the new one. This review did not re-run them.

No findings.

VERDICT: PASS
