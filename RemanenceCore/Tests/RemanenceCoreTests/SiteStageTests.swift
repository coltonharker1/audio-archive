import Testing
@testable import RemanenceCore

@Suite struct SiteStageTests {
    private func onSite(published: Bool?, changes: Bool = false, key: Bool = true, blocked: String? = nil) -> SiteStatus {
        SiteStatus(SiteFacts(isOnSite: true, sitePublished: published, isApproved: true, hasKey: key,
                             hasChanges: changes, blockedReason: blocked))
    }

    @Test func anUnapprovedTapeNeedsApproval() {
        for hasKey in [true, false] {
            let status = SiteStatus(SiteFacts(isApproved: false, hasKey: hasKey))
            #expect(status.stage == .needsApproval)
            #expect(status.heading == "Local only")
            #expect(status.mainAction == .approve)
            #expect(status.mainAction?.title == "Approve for push")
            #expect(!status.canWithdrawApproval)
            #expect(!status.offersRemoval)
        }
    }

    @Test func anApprovedTapeWithNoKeyNeedsOne() {
        let status = SiteStatus(SiteFacts(isApproved: true, hasKey: false))
        #expect(status.stage == .needsKey)
        #expect(status.heading == "Local only")
        #expect(status.mainAction == nil)
        #expect(status.otherActions.isEmpty)
        #expect(status.canWithdrawApproval)
    }

    @Test func anApprovedTapeIsReadyToCreateADraft() {
        let status = SiteStatus(SiteFacts(isApproved: true))
        #expect(status.stage == .readyToCreateDraft)
        #expect(status.heading == "Local only")
        #expect(status.mainAction == .createDraft)
        #expect(status.mainAction?.title == "Create unpublished draft")
        #expect(status.besideAction == nil)
        #expect(status.isEnabled(.createDraft))
        #expect(status.canWithdrawApproval)
    }

    @Test func afterAFailureTheButtonTriesAgain() {
        let status = SiteStatus(SiteFacts(isApproved: true, pushFailed: true))
        #expect(status.stage == .readyToCreateDraft)
        #expect(status.mainAction == .tryAgain)
        #expect(status.mainAction?.title == "Try Again")
    }

    @Test func aRunningPushOffersOnlyStop() {
        // The tape is marked as on the site just before the push finishes.
        for isOnSite in [false, true] {
            let status = SiteStatus(SiteFacts(isOnSite: isOnSite, isApproved: true, blockedReason: "", isPushing: true))
            #expect(status.stage == .pushing)
            #expect(status.mainAction == .stop)
            #expect(status.isEnabled(.stop))
            #expect(status.otherActions.isEmpty)
            #expect(!status.offersRemoval)
            #expect(!status.canWithdrawApproval)
        }
    }

    @Test func aPostTheAppHasntReadNeedsARefreshAndIsNeverADraftStage() {
        for changes in [false, true] {
            let status = onSite(published: nil, changes: changes)
            #expect(status.stage == .needsRefresh)
            #expect(status.facts.needsRefresh)
            #expect(status.heading == "Draft on site")
            #expect(!status.explanation.contains("Only you"))
            #expect(status.mainAction == .refresh)
            #expect(status.besideAction == nil)
            #expect(status.otherActions.isEmpty)
            #expect(!status.isEnabled(.publish))
            #expect(status.offersRemoval)
            #expect(!status.canRemove)
        }
    }

    @Test func publishingIsTheMainButtonOnADraftThatMatchesTheSite() {
        let status = onSite(published: false)
        #expect(status.stage == .draft)
        #expect(status.heading == "Draft on site")
        #expect(status.mainAction == .publish)
        #expect(status.mainAction?.title == "Publish reel")
        #expect(status.isEnabled(.publish))
        #expect(status.besideAction == nil)
        #expect(status.otherActions == [.update, .refresh])
        #expect(!status.isEnabled(.update))
        #expect(status.isEnabled(.refresh))
        #expect(status.canRemove)
        #expect(!status.canWithdrawApproval)
    }

    @Test func updatingIsTheMainButtonOnADraftWithChanges() {
        let status = onSite(published: false, changes: true)
        #expect(status.stage == .draftWithChanges)
        #expect(status.heading == "Draft on site")
        #expect(status.mainAction == .update)
        #expect(status.isEnabled(.update))
        #expect(status.besideAction == .publish)
        #expect(status.otherActions == [.refresh])
    }

    @Test func aPublishedPostOffersToUnpublish() {
        let status = onSite(published: true)
        #expect(status.stage == .published)
        #expect(status.heading == "Published")
        #expect(status.mainAction == .unpublish)
        #expect(status.mainAction?.title == "Unpublish reel")
        #expect(status.otherActions == [.update, .refresh])
        #expect(!status.isEnabled(.update))
    }

    @Test func aPublishedPostWithChangesOffersToUpdate() {
        let status = onSite(published: true, changes: true)
        #expect(status.stage == .publishedWithChanges)
        #expect(status.heading == "Published")
        #expect(status.mainAction == .update)
        #expect(status.besideAction == .unpublish)
        #expect(status.otherActions == [.refresh])
    }

    @Test func onlyADraftEverOffersToPublish() {
        for isOnSite in [false, true] {
            for published in [nil, false, true] as [Bool?] {
                for hasKey in [false, true] {
                    for changes in [false, true] {
                        let status = SiteStatus(SiteFacts(
                            isOnSite: isOnSite, sitePublished: published, isApproved: true, hasKey: hasKey, hasChanges: changes
                        ))
                        let offered = [status.mainAction, status.besideAction].compactMap(\.self) + status.otherActions
                        #expect(offered.contains(.publish) == (isOnSite && hasKey && published == false))
                    }
                }
            }
        }
    }

    @Test func aPostOnTheSiteWithNoKeyKeepsItsHeadingAndOffersNothing() {
        for (published, heading) in [(true, "Published"), (false, "Draft on site"), (nil, "Draft on site")] as [(Bool?, String)] {
            let status = onSite(published: published, changes: true, key: false)
            #expect(status.stage == .needsKey)
            #expect(status.heading == heading)
            #expect(status.mainAction == nil)
            #expect(status.besideAction == nil)
            #expect(status.otherActions.isEmpty)
            #expect(!status.offersRemoval)
            #expect(!status.canWithdrawApproval)
        }
    }

    @Test func aBlockedReasonKeepsTheStageButDisablesItsButton() {
        let reason = "Finish recording first."
        let ready = SiteStatus(SiteFacts(isApproved: true, blockedReason: reason))
        #expect(ready.stage == .readyToCreateDraft)
        #expect(ready.mainAction == .createDraft)
        #expect(!ready.isEnabled(.createDraft))
        // Taking approval back sends nothing, so it stays possible.
        #expect(ready.canWithdrawApproval)

        let unapproved = SiteStatus(SiteFacts(blockedReason: reason))
        #expect(unapproved.isEnabled(.approve))

        // An empty reason blocks too. It just isn't written out.
        for published in [false, true] {
            for changes in [false, true] {
                let blocked = onSite(published: published, changes: changes, blocked: "")
                let free = onSite(published: published, changes: changes)
                #expect(blocked.stage == free.stage)
                #expect(blocked.mainAction == free.mainAction)
                for action in [SiteAction.publish, .unpublish, .update, .refresh] {
                    #expect(!blocked.isEnabled(action))
                }
                #expect(!blocked.canRemove)
            }
        }
        #expect(!onSite(published: nil, blocked: "").isEnabled(.refresh))
    }

    @Test func everyStageIsReached() {
        let facts = [
            SiteFacts(),
            SiteFacts(isApproved: true, hasKey: false),
            SiteFacts(isApproved: true),
            SiteFacts(isApproved: true, isPushing: true),
            SiteFacts(isOnSite: true),
            SiteFacts(isOnSite: true, sitePublished: false),
            SiteFacts(isOnSite: true, sitePublished: false, hasChanges: true),
            SiteFacts(isOnSite: true, sitePublished: true),
            SiteFacts(isOnSite: true, sitePublished: true, hasChanges: true),
        ]
        #expect(facts.map(SiteStage.init) == SiteStage.allCases)
    }
}
