import AppKit
import ImageIO
import RemanenceCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything the site will show for a tape: the writing on the left, and where the
/// post stands on the site, with its next step, on the right.
struct SitePostView: View {
    @Environment(AppModel.self) private var model
    let tape: ShelfTape
    @Binding var showsStatus: Bool
    let size: LayoutSize

    @State private var post: SitePost?
    @State private var fields: PostFields?
    @State private var trackText: [String: String] = [:]
    @State private var trackNames: [String: String] = [:]
    @State private var captions: [Int64: String] = [:]
    /// What the fields held when loaded or last saved. Only fields that differ from
    /// these were edited here, so only they are saved. Anything changed elsewhere,
    /// like a track renamed on the review screen, is left alone.
    @State private var savedFields: PostFields?
    @State private var savedText: [String: String] = [:]
    @State private var savedNames: [String: String] = [:]
    @State private var savedCaptions: [Int64: String] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var isManagingPhotos = false
    @State private var isEditingFinding = false
    /// The track whose name and description are showing.
    @State private var openTrackID: String?
    @State private var key = ""
    /// The approval the push plan was last worked out for, so a problem found before
    /// approving isn't shown after it.
    @State private var plannedApproval: Date?

    @State private var confirmingRefresh = false
    @State private var confirmingDelete = false

    private var push: PushModel { model.pushModel }
    private var isOnSite: Bool { tape.tape.pushedAt != nil }
    private var changes: SiteChanges? { post.flatMap(Pusher.changes(for:)) }
    private var needsRefresh: Bool { status.facts.needsRefresh }
    /// Nothing here can be edited while the post needs a refresh or is being synced.
    private var isLocked: Bool { needsRefresh || push.syncingTapeID == tape.id }

    private var status: SiteStatus {
        SiteStatus(SiteFacts(
            isOnSite: isOnSite,
            sitePublished: SiteSnapshot.decode(post?.tape.siteSnapshot)?.published,
            isApproved: tape.tape.approvedAt != nil,
            hasKey: push.hasKey,
            hasChanges: changes?.isEmpty == false,
            blockedReason: blockedReason,
            isPushing: push.pushingTapeID == tape.id,
            pushFailed: push.failure != nil
        ))
    }

    private var blockedReason: String? {
        if isOnSite { return push.isPushing ? "" : nil }
        if push.isPushing { return "Another tape is being pushed." }
        if model.recordModel.isRecording { return "Finish recording first." }
        if tape.status.isActive { return "This tape is still being processed." }
        if push.planProblem != nil { return "" }
        if fields?.medium == nil { return "Choose a medium first." }
        return nil
    }

    private var planProblem: String? {
        plannedApproval == tape.tape.approvedAt ? push.planProblem : nil
    }

    /// A push that failed, or a key that couldn't be kept.
    private var pushFailure: String? {
        push.pushingTapeID == nil ? push.failure : nil
    }

    /// Why the last thing sent about this post didn't work, such as the site's copy
    /// being newer than the one here. It stays until the next action.
    private var syncFailure: String? {
        push.syncingTapeID != tape.id && push.lastSyncedTapeID == tape.id ? push.syncFailure : nil
    }

    private var footerNote: String? {
        guard let post else { return nil }
        let count = post.tracks.count == 1 ? "1 track" : "\(post.tracks.count) tracks"
        return [tape.tape.catalogNumber, "\(count) in site order"].compactMap(\.self).joined(separator: " · ")
    }

    var body: some View {
        Group {
            if let post, fields != nil {
                HStack(alignment: .top, spacing: size == .regular ? 28 : 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !showsStatus { statusBar }
                        ScrollView {
                            writing(post)
                                .padding(.vertical, 14)
                                .frame(maxWidth: 780, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if showsStatus {
                        statusColumn(post)
                            .frame(width: size.rightColumn)
                    }
                }
                .padding(.horizontal, 28)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.paper)
        .task(id: tape.id) { await observe() }
        .task(id: tape.tape.approvedAt) {
            await push.load(tape)
            plannedApproval = tape.tape.approvedAt
        }
        .onChange(of: footerNote, initial: true) { _, note in model.footerNote = note }
        .onDisappear { saveNow() }
        .onChange(of: push.refreshes) { _, _ in reloadDrafts() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsStatus.toggle()
                } label: {
                    Label("Site Status", systemImage: "sidebar.trailing")
                }
                .help(showsStatus ? "Hide site status" : "Show site status")
            }
        }
        .sheet(isPresented: $isManagingPhotos, onDismiss: { saveNow() }) {
            PhotosSheet(
                tapeID: tape.id,
                post: $post,
                captions: $captions,
                isLocked: isLocked,
                onCaptionChange: scheduleSave
            )
        }
        .confirmationDialog("Replace what’s written here with what the site has?", isPresented: $confirmingRefresh) {
            Button("Refresh from Site", role: .destructive) { push.refresh(tape) }
        } message: {
            Text("Changes here that haven’t been sent to the site will be lost.")
        }
        .confirmationDialog("Delete \(tape.tape.catalogNumber ?? "this post") from the site?", isPresented: $confirmingDelete) {
            Button("Delete from Site", role: .destructive) { push.deleteFromSite(tape) }
        } message: {
            Text("The post is removed from the site for everyone. This tape, its masters and everything written here stay in your library, and it can be pushed again later as a new post with a new catalog number.")
        }
    }

    /// After a refresh, the fields show what was loaded rather than the old draft.
    private func reloadDrafts() {
        saveTask?.cancel()
        fields = nil
        savedFields = nil
        trackText = [:]
        trackNames = [:]
        captions = [:]
        savedText = [:]
        savedNames = [:]
        savedCaptions = [:]
        Task { await observe() }
    }

    // MARK: Loading and saving

    private func observe() async {
        guard let library = model.library else { return }
        post = nil
        fields = nil
        do {
            for try await update in library.postUpdates(tapeID: tape.id) {
                guard let update else { continue }
                // What's being typed is kept. Only the first load fills the fields.
                if fields == nil {
                    fields = PostFields(tape: update.tape)
                    savedFields = fields
                }
                for track in update.tracks where trackText[track.id] == nil {
                    trackText[track.id] = track.description ?? ""
                    trackNames[track.id] = track.name ?? ""
                    savedText[track.id] = trackText[track.id]
                    savedNames[track.id] = trackNames[track.id]
                }
                // Renaming a side from the header can rename its opening track while
                // this is showing. A name that isn't being edited here follows it.
                for track in update.tracks {
                    guard let before = post?.tracks.first(where: { $0.id == track.id }), before.name != track.name,
                          trackNames[track.id] == savedNames[track.id] else { continue }
                    trackNames[track.id] = track.name ?? ""
                    savedNames[track.id] = trackNames[track.id]
                }
                for image in update.images where captions[image.id ?? 0] == nil {
                    captions[image.id ?? 0] = image.caption ?? ""
                    savedCaptions[image.id ?? 0] = captions[image.id ?? 0]
                }
                post = update
            }
        } catch is CancellationError {
        } catch {
            model.message = "This post couldn’t be loaded. \(error.localizedDescription)"
        }
    }

    /// Saves shortly after typing stops, so every keystroke isn't a write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard let library = model.library, let fields, let post, !needsRefresh else { return }
        let tapeID = tape.id
        let fieldsChanged = fields != savedFields
        let tracks = post.tracks.compactMap { track -> (PostTrack, name: String?, text: String?)? in
            let name = trackNames[track.id].flatMap { $0 == savedNames[track.id] ? nil : $0 }
            let text = trackText[track.id].flatMap { $0 == savedText[track.id] ? nil : $0 }
            return name == nil && text == nil ? nil : (track, name, text)
        }
        let captionChanges = captions.filter { savedCaptions[$0.key] != $0.value }
        guard fieldsChanged || !tracks.isEmpty || !captionChanges.isEmpty else { return }

        savedFields = fields
        for (track, name, text) in tracks {
            if let name { savedNames[track.id] = name }
            if let text { savedText[track.id] = text }
        }
        for (id, caption) in captionChanges { savedCaptions[id] = caption }

        // A fresh task, because GRDB refuses writes from a cancelled one.
        Task.detached {
            do {
                if fieldsChanged { try await library.savePost(tapeID: tapeID, fields: fields) }
                for (track, name, text) in tracks {
                    try await library.saveTrack(sourceID: track.sourceID, startMarkerID: track.startMarkerID, name: name, description: text)
                }
                for (id, caption) in captionChanges {
                    try await library.setCaption(imageID: id, caption: caption)
                }
            } catch {
                await MainActor.run { AppModel.shared.message = "Couldn’t save. \(error.localizedDescription)" }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<PostFields, String>) -> Binding<String> {
        Binding(
            get: { fields?[keyPath: keyPath] ?? "" },
            set: { fields?[keyPath: keyPath] = $0; scheduleSave() }
        )
    }

    // MARK: Writing

    private func writing(_ post: SitePost) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                sectionTitle("Site Post")
                Spacer(minLength: 0)
                // Typing saves by itself. This saves without the wait.
                Button("Save") { saveNow() }
                    .buttonStyle(.paperStandard)
                    .disabled(isLocked)
                    .help("Save now. Changes also save by themselves.")
            }
            Group {
                labeled("Public title") {
                    TextField("Unlabeled Scotch reel, estate sale", text: binding(\.title))
                        .font(Theme.serif(size.rowName))
                        .paperField()
                        .accessibilityLabel("Public title")
                }
                labeled("Description") {
                    editor(binding(\.description), font: Theme.serif(size == .regular ? 20 : 16), minHeight: 180, label: "Description")
                    hint("Blank lines separate paragraphs. A paragraph of just [photo 2] places the second photo there.")
                }
                HStack(alignment: .top, spacing: size == .regular ? 26 : 14) {
                    labeled("Estimated date") {
                        TextField("c. 1972–1975", text: binding(\.recordedDate))
                            .paperField()
                            .accessibilityLabel("Estimated recording date")
                        if let era = post.eraReference, fields?.recordedDate.isEmpty == true {
                            Button("Claude suggests \(era). Use It") {
                                fields?.recordedDate = era
                                scheduleSave()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .lineLimit(2)
                        }
                    }
                    labeled("Medium") {
                        Picker("Medium", selection: Binding(
                            get: { fields?.medium },
                            set: { fields?.medium = $0; scheduleSave() }
                        )) {
                            if fields?.medium == nil { Text("Choose…").tag(SiteMedium?.none) }
                            ForEach(SiteMedium.allCases) { medium in
                                Text(medium.label).tag(SiteMedium?.some(medium))
                            }
                        }
                        .labelsHidden()
                        .padding(.top, 5)
                    }
                }
            }
            .disabled(isLocked)
            finding(post)
            tracks(post)
        }
    }

    /// Where and when it was found, in a line until it needs changing.
    private func finding(_ post: SitePost) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    findingLine(post)
                        .fixedSize()
                    Spacer(minLength: 0)
                    findingButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    findingLine(post)
                    findingButton
                }
            }
            if isEditingFinding {
                HStack(alignment: .top, spacing: size == .regular ? 26 : 14) {
                    labeled("Where found") {
                        TextField(post.collection?.whereFound ?? "Estate sale, Memphis TN", text: binding(\.whereFound))
                            .paperField()
                            .accessibilityLabel("Where found")
                    }
                    labeled("Date acquired") {
                        TextField(post.collection?.dateFound ?? "2024-03-15", text: binding(\.dateFound))
                            .paperField()
                            .accessibilityLabel("Date acquired")
                    }
                }
                .disabled(isLocked)
                if let collection = post.collection {
                    hint("Left blank, these come from its collection, \(collection.name).")
                }
            }
        }
    }

    /// What the post will say: what's typed here, or else the collection's.
    private func findingLine(_ post: SitePost) -> some View {
        let values = [
            (own: fields?.whereFound ?? "", inherited: post.collection?.whereFound),
            (own: fields?.dateFound ?? "", inherited: post.collection?.dateFound),
        ].compactMap { value -> (text: String, isInherited: Bool)? in
            let own = value.own.trimmingCharacters(in: .whitespacesAndNewlines)
            if !own.isEmpty { return (own, false) }
            return value.inherited.map { ($0, true) }
        }
        let inherited = values.filter(\.isInherited).count
        var line = values.map(\.text).joined(separator: " · ")
        if values.isEmpty {
            line = "Where and when it was found isn’t written yet."
        } else if inherited == values.count {
            line += "  (from collection)"
        } else if inherited > 0 {
            line += "  (partly from collection)"
        }
        return Text(line)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .lineLimit(2)
            .help(line)
    }

    private var findingButton: some View {
        Button(isEditingFinding ? "Hide finding details" : "Edit finding details…") {
            isEditingFinding.toggle()
        }
        .buttonStyle(.paperSmall)
    }

    // MARK: Tracks

    private func tracks(_ post: SitePost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                sectionTitle(post.tracks.count == 1 ? "Public track" : "Public tracks")
                Spacer(minLength: 0)
                textButton("Edit track order →") { model.switchTab(.edit) }
            }
            hint("Open a track to name and describe it. The description shows under its title in the site’s player.")
            VStack(spacing: 0) {
                ForEach(Array(post.tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track, index: index, count: post.tracks.count)
                }
            }
        }
    }

    /// A track as the site will list it. Opening it shows its name and description.
    @ViewBuilder private func trackRow(_ track: PostTrack, index: Int, count: Int) -> some View {
        let isOpen = openTrackID == track.id
        // What the site calls a track with no name of its own.
        let unnamed = count == 1 ? tape.tape.title : "Track \(index + 1)"
        let typed = trackNames[track.id] ?? ""
        // The side, as Review shows it. The recording's name would repeat the title.
        let side = tape.items.first { $0.source.id == track.sourceID }?.source.side.map { "Side \($0)" }

        Button {
            openTrackID = isOpen ? nil : track.id
        } label: {
            NumberedTrackRow(
                number: String(format: "%02d", index + 1),
                detail: [side, TimeLabel.clock(track.start)].compactMap(\.self).joined(separator: " · "),
                duration: TimeLabel.clock(track.duration),
                size: size,
                isPicked: isOpen
            ) {
                HStack(spacing: 6) {
                    Text(typed.isEmpty ? unnamed : typed)
                        .font(Theme.serif(size.rowName))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Closes its name and description" : "Opens its name and description")

        if isOpen {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    labeled("Track name") {
                        TextField(unnamed, text: Binding(
                            get: { trackNames[track.id] ?? "" },
                            set: { trackNames[track.id] = $0; scheduleSave() }
                        ))
                        .paperField()
                        .accessibilityLabel("Name of track \(index + 1)")
                    }
                    labeled("Track description") {
                        editor(Binding(
                            get: { trackText[track.id] ?? "" },
                            set: { trackText[track.id] = $0; scheduleSave() }
                        ), font: .system(size: 13), minHeight: 72, label: "Description of track \(index + 1)")
                    }
                }
                .disabled(isLocked)
                if let summary = track.summaryLong ?? track.summaryShort {
                    ReferenceBox(title: "Claude’s summary of this track", text: summary) {
                        trackText[track.id] = summary
                        scheduleSave()
                    } canUse: { !isLocked && (trackText[track.id] ?? "").isEmpty }
                }
            }
            .padding(12)
            .background(Theme.inset, in: .rect(cornerRadius: 4))
            .padding(.vertical, 8)
        }
    }

    // MARK: Site status

    private func statusColumn(_ post: SitePost) -> some View {
        let status = status
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    CapLabel("Site status")
                    Text(status.heading)
                        .font(Theme.serif(size.sectionTitle))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(status.explanation)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                steps(status)
                messages
                HairlineRule()
                    .padding(.vertical, 4)
                photograph(post)
                if let reference = post.summaryReference {
                    HairlineRule()
                        .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        CapLabel("Writing reference")
                            .accessibilityAddTraits(.isHeader)
                        ReferenceBox(title: "Claude’s summary", text: reference) {
                            fields?.description = reference
                            scheduleSave()
                        } canUse: { !isLocked && fields?.description.isEmpty == true }
                    }
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, size == .regular ? 24 : 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
    }

    /// The stage's main button, and the smaller things that can be done.
    @ViewBuilder private func steps(_ status: SiteStatus) -> some View {
        if push.syncingTapeID == tape.id {
            syncing
        } else if status.stage == .pushing {
            progressView(status)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if status.stage == .needsKey {
                    keyEntry
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { buttons(status) }
                        VStack(alignment: .leading, spacing: 8) { buttons(status) }
                    }
                }
                if status.stage == .readyToCreateDraft {
                    if let planProblem {
                        Text(planProblem)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.attention)
                    }
                    if let blockedReason, !blockedReason.isEmpty {
                        hint(blockedReason)
                    }
                }
                if status.canWithdrawApproval {
                    textButton("Withdraw approval") {
                        Task { await model.setApproved(tape, false) }
                    }
                }
                if !status.otherActions.isEmpty || status.offersRemoval {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { otherSteps(status) }
                        VStack(alignment: .leading, spacing: 8) { otherSteps(status) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func buttons(_ status: SiteStatus) -> some View {
        if let action = status.mainAction {
            Button(action.title) { perform(action) }
                .buttonStyle(PaperButtonStyle(isPrimary: action != .stop))
                .disabled(!status.isEnabled(action))
        }
        if let action = status.besideAction {
            Button(action.title) { perform(action) }
                .buttonStyle(.paperStandard)
                .disabled(!status.isEnabled(action))
        }
    }

    @ViewBuilder private func otherSteps(_ status: SiteStatus) -> some View {
        ForEach(status.otherActions, id: \.self) { action in
            textButton(action.title) { perform(action) }
                .disabled(!status.isEnabled(action))
        }
        if status.offersRemoval {
            Menu("More") {
                Button("Remove from site…", role: .destructive) { confirmingDelete = true }
                    .disabled(!status.canRemove)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(status.facts.needsRefresh ? "Refresh from the site first to remove this post" : "Remove this post from the site")
        }
    }

    private func perform(_ action: SiteAction) {
        switch action {
        case .approve:
            saveNow()
            Task { await model.setApproved(tape, true) }
        case .createDraft, .tryAgain:
            afterSaving { push.start(tape) }
        case .stop:
            push.cancel()
        case .refresh:
            if changes?.isEmpty == false { confirmingRefresh = true } else { push.refresh(tape) }
        case .publish:
            afterSaving { push.setPublished(tape, true) }
        case .unpublish:
            afterSaving { push.setPublished(tape, false) }
        case .update:
            afterSaving { push.update(tape) }
        }
    }

    /// Lets the last save land before the post is read to be sent.
    private func afterSaving(_ send: @escaping @MainActor () -> Void) {
        saveNow()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            send()
        }
    }

    /// How the last thing sent went, and how what's written here compares with the site.
    @ViewBuilder private var messages: some View {
        if let pushFailure {
            failureText(pushFailure)
        }
        if let syncFailure {
            failureText(syncFailure)
        } else if push.syncingTapeID != tape.id, push.lastSyncedTapeID == tape.id, let note = push.syncNote {
            hint(note)
        }
        if isOnSite, !needsRefresh, let changes {
            if changes.isEmpty {
                Text("Matches the site.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.goodText)
            } else {
                Text("To send: \(changes.summary.joined(separator: ", "))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
            }
            ForEach(changes.notSent, id: \.self) { note in
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.attention)
            }
        }
    }

    private func failureText(_ failure: String) -> some View {
        Text(failure)
            .font(.system(size: 13))
            .foregroundStyle(Theme.attention)
            .textSelection(.enabled)
    }

    /// With the column hidden, the post's state, its next step and any failure stay
    /// above the writing.
    private var statusBar: some View {
        let status = status
        let blocked = status.stage == .readyToCreateDraft
            ? planProblem ?? blockedReason.flatMap { $0.isEmpty ? nil : $0 }
            : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusBadge(
                    text: status.heading,
                    tone: !isOnSite ? .idle : status.facts.sitePublished == true ? .published : .draft
                )
                Spacer(minLength: 0)
                if push.syncingTapeID == tape.id {
                    syncing
                } else if status.stage == .needsKey {
                    Button("Enter Site Key…") { showsStatus = true }
                        .buttonStyle(.paperStandard)
                } else {
                    if status.stage == .pushing {
                        Text(progressLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    buttons(status)
                }
            }
            if let problem = pushFailure ?? syncFailure ?? blocked {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.attention)
                    .lineLimit(2)
                    .help(problem)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { HairlineRule() }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            hint("Enter the site’s sync API key. It’s kept in your Keychain.")
            SecureField("SYNC_API_KEY", text: $key)
                .paperField()
                .onSubmit { saveKey() }
                .accessibilityLabel("Site sync API key")
            Button("Save Key") { saveKey() }
                .buttonStyle(.paperPrimary)
                .disabled(key.isEmpty)
        }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        push.saveKey(key)
        key = ""
    }

    private var syncing: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progressLabel)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
    }

    private func progressView(_ status: SiteStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progressLabel)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if case .uploading(_, _, let fraction) = push.progress {
                ProgressView(value: fraction).tint(Theme.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
            }
            buttons(status)
            hint("Stopping keeps what’s finished, so pushing again picks up from there.")
        }
    }

    private var progressLabel: String {
        switch push.progress {
        case .preparing(let track, let total): "Cutting track \(track) of \(total)…"
        case .checking: "Checking what the site already has…"
        case .uploading(let file, let total, let fraction): "Uploading file \(file) of \(total), \(Int(fraction * 100))%"
        case .creating: isOnSite ? "Updating the post…" : "Creating the post…"
        case nil: isOnSite ? "Talking to the site…" : "Starting…"
        }
    }

    // MARK: Photos

    /// The post's first photo, and the way to the rest.
    private func photograph(_ post: SitePost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CapLabel("Post photograph")
                .accessibilityAddTraits(.isHeader)
            if let image = post.images.first {
                Thumbnail(url: try? model.library?.url(forLibraryPath: image.path))
                    .frame(width: 125, height: 150)
                    .clipShape(.rect(cornerRadius: 3))
                    .accessibilityLabel("Photo 1")
                if let caption = captions[image.id ?? 0], !caption.isEmpty {
                    Text(caption)
                        .font(Theme.serif(13).italic())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                }
                if post.images.count > 1 {
                    hint("First of \(post.images.count) photos.")
                }
            } else {
                hint("No photos yet. Drop some here, or add them from Manage photos.")
            }
            textButton("Manage photos…") { isManagingPhotos = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isDropTargeted ? 8 : 0)
        .background(isDropTargeted ? Theme.inset : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .dropDestination(for: URL.self) { urls, _ in
            // Taken even when locked, so photos aren't imported as audio instead.
            if !isLocked, let library = model.library {
                addPhotos(urls, to: tape.id, in: library) { AppModel.shared.message = $0 }
            }
            return true
        } isTargeted: { isDropTargeted = $0 && !isLocked }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.serif(size.sectionTitle))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
    }

    /// A quiet action, drawn as words.
    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .underline()
                .foregroundStyle(Theme.ink)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func editor(_ text: Binding<String>, font: Font, minHeight: CGFloat, label: String) -> some View {
        TextEditor(text: text)
            .font(font)
            .foregroundStyle(Theme.ink)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Theme.field, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.fieldBorder)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(label)
    }
}

/// Copies photos into a tape's post, one at a time, reporting any that can't be.
private func addPhotos(
    _ urls: [URL],
    to tapeID: Int64,
    in library: Library,
    failed: @escaping @MainActor @Sendable (String) -> Void
) {
    Task.detached {
        for url in urls {
            do {
                try await library.addImage(tapeID: tapeID, from: url)
            } catch {
                await failed(error.localizedDescription)
            }
        }
    }
}

/// Every photo on a post, in the order the site numbers them.
private struct PhotosSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false
    /// Shown here, since the window's own alert waits behind a sheet.
    @State private var problem: String?

    let tapeID: Int64
    @Binding var post: SitePost?
    @Binding var captions: [Int64: String]
    let isLocked: Bool
    let onCaptionChange: () -> Void

    private var images: [TapeImage] { post?.images ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Photos")
                    .font(Theme.serif(27))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(.paperPrimary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            HairlineRule()

            ScrollView {
                if images.isEmpty {
                    Text("No photos yet.")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                            card(image, number: index + 1)
                        }
                    }
                    .padding(20)
                }
            }
            .disabled(isLocked)

            HairlineRule()

            VStack(alignment: .leading, spacing: 8) {
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.attention)
                        .lineLimit(3)
                        .help(problem)
                }
                HStack(spacing: 10) {
                    Button("Add Photos…", systemImage: "photo.badge.plus") { choose() }
                        .buttonStyle(.paperStandard)
                        .disabled(isLocked)
                    Text(isLocked
                         ? "Refresh from the site before changing its photos."
                         : "Or drop them here. Locations are removed, and HEIC becomes JPEG. A paragraph of just [photo 2] in the description places the second photo there.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                }
            }
            .padding(20)
        }
        // A fixed size, so the text in it is never measured at no width.
        .frame(width: 580, height: 500)
        .background(isDropTargeted ? Theme.inset : Theme.paper)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !isLocked
        } isTargeted: { isDropTargeted = $0 && !isLocked }
    }

    private func card(_ image: TapeImage, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(url: try? model.library?.url(forLibraryPath: image.path))
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 3))
            HStack(spacing: 6) {
                Text("Photo \(number)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                Spacer(minLength: 0)
                Button("Earlier", systemImage: "chevron.left") { move(image, by: -1) }
                    .disabled(number == 1)
                Button("Later", systemImage: "chevron.right") { move(image, by: 1) }
                    .disabled(number == images.count)
                Button("Remove", systemImage: "trash") { remove(image) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            TextField("Caption (optional)", text: Binding(
                get: { captions[image.id ?? 0] ?? "" },
                set: { captions[image.id ?? 0] = $0; onCaptionChange() }
            ))
            .font(.system(size: 12))
            .paperField()
            .accessibilityLabel("Caption of photo \(number)")
        }
        .padding(8)
        .background(Theme.inset, in: .rect(cornerRadius: 4))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos of the tape, its box, labels or anything that came with it."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        guard let library = model.library, !isLocked else { return }
        problem = nil
        addPhotos(urls, to: tapeID, in: library) { problem = $0 }
    }

    private func move(_ image: TapeImage, by offset: Int) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.moveImage(id: id, by: offset) }
    }

    private func remove(_ image: TapeImage) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.removeImage(id: id) }
    }
}

/// Claude's text, shown beside what you write. It's only ever used if you choose to.
private struct ReferenceBox: View {
    let title: String
    let text: String
    let use: () -> Void
    let canUse: () -> Bool
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                // Stacked where a column is too narrow for both.
                ViewThatFits(in: .horizontal) {
                    HStack { choices }
                    VStack(alignment: .leading) { choices }
                }
            }
            .padding(.top, 4)
        } label: {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var choices: some View {
        if canUse() {
            Button("Use as a Starting Point") { use() }
                .fixedSize()
        }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .fixedSize()
    }
}

/// A small copy of a photo, made off the main thread so large photos don't stall typing.
struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.hero
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 400,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: thumbnail, size: .zero)
            }.value
        }
    }
}
