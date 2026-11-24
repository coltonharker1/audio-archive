import AppKit
import ImageIO
import RemanenceCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything the site will show for a tape, written here and then pushed.
struct SitePostView: View {
    @Environment(AppModel.self) private var model
    let tape: ShelfTape

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

    @State private var confirmingRefresh = false
    @State private var confirmingDelete = false

    private var push: PushModel { model.pushModel }
    private var isOnSite: Bool { tape.tape.pushedAt != nil }
    /// A post on the site that the app hasn't read yet can't be edited, or a later
    /// update would be worked out against nothing.
    private var needsRefresh: Bool { isOnSite && post?.tape.siteSnapshot == nil }
    private var changes: SiteChanges? { post.flatMap(Pusher.changes(for:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                siteStatusLine
                if let post, fields != nil {
                    if isOnSite { siteSection }
                    Group {
                        details
                        descriptionSection(post)
                        photos(post)
                        tracks(post)
                    }
                    .disabled(needsRefresh || push.syncingTapeID == tape.id)
                    if !isOnSite { pushSection }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
        .task(id: tape.id) { await observe() }
        .task(id: tape.tape.approvedAt) { await push.load(tape) }
        .onDisappear { saveNow() }
        .onChange(of: push.refreshes) { _, _ in reloadDrafts() }
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

    // MARK: Sections

    private var siteStatusLine: some View {
        Text(isOnSite ? "ON THE SITE · \(tape.tape.catalogNumber ?? "")" : "NOT ON THE SITE YET")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.inkMuted)
    }

    @ViewBuilder private var siteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = post.flatMap({ SiteSnapshot.decode($0.tape.siteSnapshot) }) {
                HStack(spacing: 10) {
                    Label(
                        snapshot.published ? "Published. Visitors can see it." : "Not published. Only you can see it.",
                        systemImage: snapshot.published ? "eye" : "eye.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(snapshot.published ? Theme.goodText : Theme.inkMuted)
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if push.hasKey {
                        Button(snapshot.published ? "Unpublish" : "Publish") {
                            push.setPublished(tape, !snapshot.published)
                        }
                        .disabled(needsRefresh || push.isPushing)
                        .fixedSize()
                    }
                }
            }
            if needsRefresh {
                Text("Refresh from the site to load what it has now, including anything changed in its admin. Then edit here and send the changes with Update on Site.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(3)
            } else if let changes {
                if changes.isEmpty {
                    Text("Matches the site.")
                        .font(.callout)
                        .foregroundStyle(Theme.goodText)
                } else {
                    Text("To send: \(changes.summary.joined(separator: ", "))")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(3)
                }
                ForEach(changes.notSent, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.attention)
                        .lineLimit(3)
                }
            }
            if push.syncingTapeID == tape.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progressLabel)
                        .font(.callout)
                        .lineLimit(1)
                }
            } else {
                if push.lastSyncedTapeID != tape.id {
                    EmptyView()
                } else if let failure = push.syncFailure {
                    Text(failure)
                        .foregroundStyle(Theme.attention)
                        .lineLimit(4)
                } else if let note = push.syncNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(3)
                }
                if !push.hasKey {
                    keyEntry
                } else {
                    HStack {
                        if !needsRefresh {
                            Button("Update on Site", systemImage: "arrow.up.circle") {
                                saveNow()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(300))
                                    push.update(tape)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(changes?.isEmpty != false || push.isPushing)
                            .fixedSize()
                        }
                        Button("Refresh from Site", systemImage: "arrow.down.circle") {
                            if changes?.isEmpty == false { confirmingRefresh = true } else { push.refresh(tape) }
                        }
                        .disabled(push.isPushing)
                        .fixedSize()
                        Spacer(minLength: 8)
                        Button("Delete from Site…", systemImage: "trash") { confirmingDelete = true }
                            .disabled(push.isPushing || needsRefresh)
                            .fixedSize()
                            .help(needsRefresh ? "Refresh from the site first" : "Remove this post from the site")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 10))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Title") {
                TextField("Unlabeled Scotch reel, estate sale", text: binding(\.title))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.display(20))
            }
            HStack(alignment: .top, spacing: 14) {
                field("Medium") {
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
                }
                field("Estimated recording date") {
                    TextField("c. 1972–1975", text: binding(\.recordedDate))
                        .textFieldStyle(.roundedBorder)
                    if let era = post?.eraReference, fields?.recordedDate.isEmpty == true {
                        Button("Claude suggests \(era). Use It") {
                            fields?.recordedDate = era
                            scheduleSave()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .lineLimit(1)
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                field("Where found") {
                    TextField(post?.collection?.whereFound ?? "Estate sale, Memphis TN", text: binding(\.whereFound))
                        .textFieldStyle(.roundedBorder)
                }
                field("Date acquired") {
                    TextField(post?.collection?.dateFound ?? "2024-03-15", text: binding(\.dateFound))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let collection = post?.collection {
                Text("Left blank, these come from its collection, \(collection.name).")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func descriptionSection(_ post: SitePost) -> some View {
        field("Description") {
            editor(binding(\.description), minHeight: 180, label: "Description")
            Text("Blank lines separate paragraphs. A paragraph of just [photo 2] places the second photo there.")
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(2)
            if let reference = post.summaryReference {
                ReferenceBox(title: "Claude’s summary, for reference", text: reference) {
                    fields?.description = reference
                    scheduleSave()
                } canUse: { fields?.description.isEmpty == true }
            }
        }
    }

    private func photos(_ post: SitePost) -> some View {
        field("Photos") {
            if !post.images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array(post.images.enumerated()), id: \.element.id) { index, image in
                        photoCard(image, number: index + 1, count: post.images.count)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Add Photos…", systemImage: "photo.badge.plus") { choosePhotos() }
                    .fixedSize()
                Text("Or drop them here. Locations are removed, and HEIC becomes JPEG.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
            }
        }
        .padding(isDropTargeted ? 8 : 0)
        .background(isDropTargeted ? Theme.card : .clear, in: .rect(cornerRadius: 10))
        .dropDestination(for: URL.self) { urls, _ in
            addPhotos(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func photoCard(_ image: TapeImage, number: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(url: try? model.library?.url(forLibraryPath: image.path))
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 6))
            HStack(spacing: 4) {
                Text("Photo \(number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
                Spacer(minLength: 0)
                Button("Earlier", systemImage: "chevron.left") { move(image, by: -1) }
                    .disabled(number == 1)
                Button("Later", systemImage: "chevron.right") { move(image, by: 1) }
                    .disabled(number == count)
                Button("Remove", systemImage: "trash") { remove(image) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            TextField("Caption (optional)", text: Binding(
                get: { captions[image.id ?? 0] ?? "" },
                set: { captions[image.id ?? 0] = $0; scheduleSave() }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
        .padding(8)
        .background(Theme.card, in: .rect(cornerRadius: 8))
    }

    private func tracks(_ post: SitePost) -> some View {
        field(post.tracks.count == 1 ? "Track" : "Tracks") {
            Text("Each track’s description shows under its title in the site’s player.")
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(2)
            ForEach(Array(post.tracks.enumerated()), id: \.element.id) { index, track in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize()
                        TextField(post.tracks.count == 1 ? tape.tape.title : "Track \(index + 1)", text: Binding(
                            get: { trackNames[track.id] ?? "" },
                            set: { trackNames[track.id] = $0; scheduleSave() }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Text(TimeLabel.clock(track.duration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize()
                    }
                    editor(Binding(
                        get: { trackText[track.id] ?? "" },
                        set: { trackText[track.id] = $0; scheduleSave() }
                    ), minHeight: 64, label: "Description of track \(index + 1)")
                    if let summary = track.summaryLong ?? track.summaryShort {
                        ReferenceBox(title: "Claude’s summary of this track", text: summary) {
                            trackText[track.id] = summary
                            scheduleSave()
                        } canUse: { (trackText[track.id] ?? "").isEmpty }
                    }
                }
                .padding(10)
                .background(Theme.card.opacity(0.6), in: .rect(cornerRadius: 8))
            }
        }
    }

    // MARK: Pushing

    @ViewBuilder private var pushSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let result = push.finished?.tapeID == tape.id ? push.finished?.result : nil {
                Text("\(result.catalogNumber) is on the site")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.goodText)
            }
            if let failure = push.failure, push.pushingTapeID == nil {
                Text(failure)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(4)
            }
            if push.pushingTapeID == tape.id {
                progressView
            } else if tape.tape.approvedAt == nil {
                HStack {
                    Button("Looks Good", systemImage: "hand.thumbsup") {
                        saveNow()
                        Task { await model.setApproved(tape, true) }
                    }
                    .fixedSize()
                    Text("Mark it as Looks Good when it’s ready to push.")
                        .font(.callout)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(2)
                }
            } else if !push.hasKey {
                keyEntry
            } else {
                if let problem = push.planProblem {
                    Text(problem)
                        .foregroundStyle(Theme.attention)
                        .lineLimit(3)
                }
                Text("Pushing creates the post unpublished, with a catalog number from the site. Publish it here once you’ve checked it on the site.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(3)
                HStack {
                    Button(push.failure == nil ? "Push to Site" : "Try Again", systemImage: "arrow.up.circle") {
                        saveNow()
                        Task {
                            // Lets the last save land before the push reads the post.
                            try? await Task.sleep(for: .milliseconds(300))
                            push.start(tape)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(blockedReason != nil)
                    .fixedSize()
                    if let reason = blockedReason {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var blockedReason: String? {
        if push.isPushing { return "Another tape is being pushed." }
        if model.recordModel.isRecording { return "Finish recording first." }
        if tape.status.isActive { return "This tape is still being processed." }
        if push.planProblem != nil { return "" }
        if fields?.medium == nil { return "Choose a medium first." }
        return nil
    }

    @State private var key = ""

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter the site’s sync API key. It’s kept in your Keychain.")
                .font(.callout)
                .foregroundStyle(Theme.inkMuted)
            HStack {
                SecureField("SYNC_API_KEY", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button("Save") {
                    push.saveKey(key)
                    key = ""
                }
                .disabled(key.isEmpty)
                .fixedSize()
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progressLabel)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            if case .uploading(_, _, let fraction) = push.progress {
                ProgressView(value: fraction).tint(Theme.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
            }
            Button("Stop") { push.cancel() }
                .fixedSize()
            Text("Stopping keeps what’s finished, so pushing again picks up from there.")
                .font(.callout)
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(2)
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

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos of the tape, its box, labels or anything that came with it."
        guard panel.runModal() == .OK else { return }
        addPhotos(panel.urls)
    }

    private func addPhotos(_ urls: [URL]) {
        guard let library = model.library, !needsRefresh else { return }
        let tapeID = tape.id
        Task.detached {
            for url in urls {
                do {
                    try await library.addImage(tapeID: tapeID, from: url)
                } catch {
                    await MainActor.run { AppModel.shared.message = error.localizedDescription }
                }
            }
        }
    }

    private func move(_ image: TapeImage, by offset: Int) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.moveImage(id: id, by: offset) }
    }

    private func remove(_ image: TapeImage) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.removeImage(id: id) }
    }

    // MARK: Pieces

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat, label: String) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Theme.card, in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.inkMuted.opacity(0.2)) }
            .accessibilityLabel(label)
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
                        .foregroundStyle(Theme.inkMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                HStack {
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
            .padding(.top, 4)
        } label: {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
        }
    }
}

/// A small copy of a photo, made off the main thread so large photos don't stall typing.
struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.board
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
