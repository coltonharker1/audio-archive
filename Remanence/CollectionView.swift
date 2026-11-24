import AppKit
import RemanenceCore
import SwiftUI

/// A tape being dragged, to a collection in the sidebar or to a new place in one.
enum TapeDrag {
    private static let prefix = "remanence-tape:"

    static func payload(_ id: Int64) -> String { prefix + String(id) }

    static func tapeID(_ payload: String) -> Int64? {
        payload.hasPrefix(prefix) ? Int64(payload.dropFirst(prefix.count)) : nil
    }
}

/// One collection: what's written about it, its photos, and its reels in the order
/// they'll be shown.
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    let collection: ShelfCollection

    @State private var fields: CollectionFields?
    /// Which collection the fields were loaded from, so typing is never saved to another.
    @State private var loadedID: Int64?
    @State private var saved: CollectionFields?
    @State private var captions: [Int64: String] = [:]
    @State private var savedCaptions: [Int64: String] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var confirmingDelete = false
    @State private var confirmingRemoveFromSite = false

    private var tapes: [ShelfTape] { model.visibleTapes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                site
                details
                photos
                reels
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: collection.id) { load() }
        .onChange(of: collection.images) { _, images in
            for image in images where captions[image.id ?? 0] == nil {
                captions[image.id ?? 0] = image.caption ?? ""
                savedCaptions[image.id ?? 0] = image.caption ?? ""
            }
        }
        .onDisappear { saveNow() }
        .confirmationDialog("Delete the collection “\(collection.collection.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            let id = collection.id
            if collection.collection.isOnSite {
                Button("Delete Here and From the Site", role: .destructive) {
                    model.pushModel.removeCollectionFromSite(id, andHere: true)
                }
            } else {
                Button("Delete Collection", role: .destructive) {
                    Task { await model.deleteCollection(id) }
                }
            }
        } message: {
            Text(collection.collection.isOnSite
                 ? "It’s removed from the site too. Its reels stay, here and on the site, outside any collection. Its write-up is removed, and its photos go to the Trash."
                 : "Its reels stay on the shelf, outside any collection. Its write-up is removed, and its photos go to the Trash.")
        }
        .confirmationDialog("Remove “\(collection.collection.name)” from the site?", isPresented: $confirmingRemoveFromSite, titleVisibility: .visible) {
            Button("Remove from Site", role: .destructive) {
                model.pushModel.removeCollectionFromSite(collection.id)
            }
        } message: {
            Text("Its page goes away and its reels stay on the site, outside any collection. Everything here is kept, ready to push again.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("COLLECTION")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Menu {
                    if collection.collection.isOnSite {
                        Button("Remove from Site…") { confirmingRemoveFromSite = true }
                            .disabled(model.pushModel.isPushing)
                    }
                    Button("Delete Collection…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for this collection")
            }
            TextField("Name", text: binding(\.name))
                .textFieldStyle(.plain)
                .font(Theme.display(40))
                .foregroundStyle(Theme.ink)
            Text(summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    private var summary: String {
        let count = tapes.count == 1 ? "1 reel" : "\(tapes.count) reels"
        let duration = tapes.reduce(0) { $0 + $1.duration }
        return "\(count) · \(TimeLabel.long(duration)) · remanencearchive.com/collections/\(collection.collection.slug)"
    }

    // MARK: Site

    private var site: some View {
        let push = model.pushModel
        let record = collection.collection
        let isBusy = push.syncingCollectionID == collection.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: record.sitePublished ? "globe" : record.isOnSite ? "doc.badge.clock" : "circle.dashed")
                    .foregroundStyle(record.sitePublished ? Theme.good : Theme.inkMuted)
                Text(siteStatus)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if !record.isOnSite {
                    Button("Push to Site", systemImage: "arrow.up.circle") { send() }
                        .disabled(push.isPushing)
                        .help("Sends it as an unpublished draft, with its write-up, photos and reels")
                        .fixedSize()
                } else {
                    Button("Send Changes", systemImage: "arrow.up.circle") { send() }
                        .disabled(push.isPushing || !collection.hasUnsentChanges)
                        .fixedSize()
                    Button(record.sitePublished ? "Unpublish" : "Publish") { send(publish: !record.sitePublished) }
                        .disabled(push.isPushing)
                        .fixedSize()
                }
            }
            if isBusy, let progress = push.progress {
                Text(progressText(progress))
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            } else if let failure = push.collectionFailure, failure.id == collection.id {
                Text(failure.text)
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if let note = push.collectionNote, note.id == collection.id {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(3)
            } else if collection.missingReelCount > 0 {
                Text(collection.missingReelCount == 1
                     ? "1 reel isn’t on the site yet. It joins this collection there when it’s pushed."
                     : "\(collection.missingReelCount) reels aren’t on the site yet. They join this collection there when they’re pushed.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: 10))
    }

    private var siteStatus: String {
        let record = collection.collection
        if !record.isOnSite { return "Not on the site yet." }
        let state = record.sitePublished ? "Public on the site." : "On the site as a draft, not public."
        return collection.hasUnsentChanges ? "\(state) Changes here haven’t been sent." : state
    }

    private func progressText(_ progress: PushProgress) -> String {
        switch progress {
        case .uploading(let file, let total, let fraction): "Uploading photo \(file) of \(total), \(Int(fraction * 100))%"
        case .creating: "Sending to the site…"
        case .checking, .preparing: "Checking what the site already has…"
        }
    }

    /// Saves what's being typed first, so the push sends it.
    private func send(publish: Bool? = nil) {
        let id = collection.id
        Task {
            await saveAndWait()
            model.pushModel.pushCollection(id, publish: publish)
        }
    }

    // MARK: Writing

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                field("Where found") {
                    TextField("Garage sale, Joliet IL", text: binding(\.whereFound))
                        .textFieldStyle(.roundedBorder)
                }
                field("Date acquired") {
                    TextField("October 2023", text: binding(\.dateFound))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("Reels in this collection use these unless they have their own.")
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
            field("Write-up") {
                TextEditor(text: binding(\.description))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 200)
                    .background(Theme.card, in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.inkMuted.opacity(0.2)) }
                    .accessibilityLabel("Write-up")
                Text("What the box says about whoever kept it. Blank lines separate paragraphs.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    // MARK: Photos

    private var photos: some View {
        field("Photos") {
            if !collection.images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array(collection.images.enumerated()), id: \.element.id) { index, image in
                        photoCard(image, number: index + 1, count: collection.images.count)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Add Photos…", systemImage: "photo.badge.plus") { choosePhotos() }
                    .fixedSize()
                Text("The box, its lid, labels, track sheets. Or drop them here.")
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

    private func photoCard(_ image: CollectionImage, number: Int, count: Int) -> some View {
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

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos of the box, its labels or anything that came with it."
        guard panel.runModal() == .OK else { return }
        addPhotos(panel.urls)
    }

    private func addPhotos(_ urls: [URL]) {
        guard let library = model.library else { return }
        let id = collection.id
        Task.detached {
            for url in urls {
                do {
                    try await library.addImage(collectionID: id, from: url)
                } catch {
                    await MainActor.run { AppModel.shared.message = error.localizedDescription }
                }
            }
        }
    }

    private func move(_ image: CollectionImage, by offset: Int) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.moveCollectionImage(id: id, by: offset) }
    }

    private func remove(_ image: CollectionImage) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.removeCollectionImage(id: id) }
    }

    // MARK: Reels

    private var reels: some View {
        field("Reels") {
            if tapes.isEmpty {
                Text("No reels yet. Drag a tape from the shelf onto this collection in the sidebar, choose Collection in a tape’s menu, or pick this collection when you record.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(4)
            } else {
                Text("Drag reels into the order they should be shown in. The site’s index by number keeps RA order.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                VStack(spacing: 0) {
                    ForEach(Array(tapes.enumerated()), id: \.element.id) { index, tape in
                        ReelGap(place: index)
                        ReelRow(tape: tape, number: index + 1)
                    }
                    ReelGap(place: tapes.count)
                }
            }
        }
    }

    // MARK: Saving

    private func load() {
        let loaded = CollectionFields(collection.collection)
        loadedID = collection.id
        fields = loaded
        saved = loaded
        captions = Dictionary(uniqueKeysWithValues: collection.images.map { ($0.id ?? 0, $0.caption ?? "") })
        savedCaptions = captions
    }

    private func binding(_ path: WritableKeyPath<CollectionFields, String>) -> Binding<String> {
        Binding(
            get: { fields?[keyPath: path] ?? "" },
            set: { fields?[keyPath: path] = $0; scheduleSave() }
        )
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

    /// Saves anything typed and not yet saved, and returns once it's in the library.
    private func saveAndWait() async {
        saveTask?.cancel()
        guard let library = model.library, let id = loadedID else { return }
        if let fields, fields != saved {
            saved = fields
            await model.saveCollection(id, fields: fields)
        }
        for (imageID, caption) in captions where savedCaptions[imageID] != caption {
            savedCaptions[imageID] = caption
            try? await Task.detached { try await library.setCollectionCaption(imageID: imageID, caption: caption) }.value
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard let library = model.library, let id = loadedID else { return }
        if let fields, fields != saved {
            saved = fields
            Task { await model.saveCollection(id, fields: fields) }
        }
        for (imageID, caption) in captions where savedCaptions[imageID] != caption {
            savedCaptions[imageID] = caption
            Task.detached { try? await library.setCollectionCaption(imageID: imageID, caption: caption) }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One reel in a collection's list. Click to select it; drag the handle to move it.
private struct ReelRow: View {
    @Environment(AppModel.self) private var model
    let tape: ShelfTape
    let number: Int

    private var isSelected: Bool { model.selectedTapeID == tape.id }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 22, height: 28)
                .contentShape(.rect)
                .draggable(TapeDrag.payload(tape.id)) {
                    Text(tape.tape.title)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.card, in: .rect(cornerRadius: 6))
                }
                .help("Drag to move")
                .accessibilityLabel("Move \(tape.tape.title)")
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 18, alignment: .trailing)
                .fixedSize()
            Text(tape.tape.catalogNumber ?? "NEW")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 58, alignment: .leading)
                .fixedSize()
            Text(tape.tape.title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(tape.tape.pushedAt == nil ? "Not on the site" : "On the site")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize()
            Text(TimeLabel.clock(tape.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.board.opacity(0.45) : Theme.card, in: .rect(cornerRadius: 7))
        .contentShape(.rect)
        .onTapGesture { model.select(tape) }
        .contextMenu {
            Button("Remove from Collection") { Task { await model.setCollection(tape, to: nil) } }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The space between two reels, which shows where a dragged reel will land.
private struct ReelGap: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    let place: Int

    var body: some View {
        ZStack {
            Color.clear
            if isTargeted {
                Capsule().fill(Theme.accent).frame(height: 3)
            }
        }
        .frame(height: 8)
        .contentShape(.rect)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(TapeDrag.tapeID) else { return false }
            let tapes = model.visibleTapes
            // Counted among the others, so a reel moved down lands where it was dropped.
            var target = place
            if let current = tapes.firstIndex(where: { $0.id == id }), current < place { target -= 1 }
            Task { await model.moveInCollection(id, to: target) }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
