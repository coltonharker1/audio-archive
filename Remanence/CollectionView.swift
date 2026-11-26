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

/// One collection as a page to read: its write-up beside the box photographs, and
/// its reels in the order they'll be shown. Editing, photos and the site draft open
/// in sheets.
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
    /// Library writes started without waiting, which a push waits for first.
    @State private var pendingWrite: Task<Void, Never>?
    /// Whether a confirmed delete is saving before it starts, so nothing else races it.
    @State private var isDeleting = false
    @State private var isDropTargeted = false
    @State private var sheet: CollectionSheet?
    /// The width of the detail area, which sets sizes and whether the columns stack.
    @State private var width: CGFloat = 680

    private var tapes: [ShelfTape] { model.visibleTapes }
    private var size: LayoutSize { LayoutSize(detailWidth: width) }

    /// The mocks' padding follows the window's width, which is wider than this
    /// screen by the sidebar.
    private var padding: CGFloat { LayoutSize.pagePadding(windowWidth: width + 220) }

    /// With less room than this, the write-up and the photos go one above the other.
    private static let twoColumnWidth: CGFloat = 560

    /// What's written, including anything typed that the library hasn't sent back yet.
    private var written: CollectionFields { fields ?? CollectionFields(collection.collection) }

    /// A collection keeps its name while the field for it is empty.
    private var name: String {
        let typed = written.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? collection.collection.name : typed
    }

    /// Where and when the box was found.
    private var found: String? {
        let parts = [written.whereFound, written.dateFound]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        let tapes = tapes
        let places = tapes.map { SitePresence($0) }
        let footerNote = CollectionCounts(collection.collection, reels: places).footerNote

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "Collection", title: name, subtitle: found, size: size) {
                    Button("Edit collection…") { sheet = .edit }
                        .buttonStyle(.paperStandard)
                        .accessibilityLabel("Edit collection…")
                    Button("Manage site draft…") { sheet = .site }
                        .buttonStyle(.paperStandard)
                        .accessibilityLabel("Manage site draft…")
                }
                .padding(.bottom, 25)

                columns

                HairlineRule()
                    .padding(.vertical, 22)

                reels(tapes, places: places)
            }
            .padding(.horizontal, padding)
            .padding(.top, 22)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: footerNote, initial: true) { _, note in model.footerNote = note }
        .task(id: collection.id) { load() }
        .onChange(of: collection.images) { _, images in
            for image in images where captions[image.id ?? 0] == nil {
                captions[image.id ?? 0] = image.caption ?? ""
                savedCaptions[image.id ?? 0] = image.caption ?? ""
            }
        }
        .onDisappear { saveNow() }
        .sheet(item: $sheet, onDismiss: { keepName(); saveNow() }) { sheet in
            switch sheet {
            case .edit:
                EditCollectionSheet(
                    collectionID: collection.id,
                    fields: $fields,
                    onChange: scheduleSave,
                    delete: delete
                )
            case .photos:
                CollectionPhotosSheet(
                    collectionID: collection.id,
                    captions: $captions,
                    onCaptionChange: scheduleSave
                )
            case .site:
                CollectionSiteSheet(collectionID: collection.id, isDeleting: isDeleting, send: send)
            case .addReels:
                AddReelsSheet(collectionID: collection.id)
            }
        }
    }

    // MARK: Writing and photos

    @ViewBuilder private var columns: some View {
        if width - padding * 2 >= Self.twoColumnWidth {
            HStack(alignment: .top, spacing: 26) {
                writeUp
                photos
            }
        } else {
            VStack(alignment: .leading, spacing: 26) {
                writeUp
                photos
            }
        }
    }

    private var writeUp: some View {
        let text = written.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let fontSize: CGFloat = size == .regular ? 21 : 17
        return VStack(alignment: .leading, spacing: 12) {
            CapLabel("Collection write-up")
                .accessibilityAddTraits(.isHeader)
            if text.isEmpty {
                Text("Nothing written yet. Edit collection is where to say what the box says about whoever kept it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                Text(text)
                    .font(Theme.serif(fontSize))
                    .lineSpacing(fontSize * 0.22)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: fontSize * 42, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photos: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CapLabel("Box photographs")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { sheet = .photos } label: {
                    Text("Manage photos…")
                        .font(.system(size: 12))
                        .underline()
                        .foregroundStyle(Theme.ink)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Manage photos…")
            }
            if collection.images.isEmpty {
                Text("The box, its lid, labels, track sheets. Or drop them here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(Array(collection.images.enumerated()), id: \.element.id) { index, image in
                        plate(image, number: index + 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isDropTargeted ? 8 : 0)
        .background(isDropTargeted ? Theme.inset : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .dropDestination(for: URL.self) { urls, _ in
            guard let library = model.library else { return false }
            addCollectionPhotos(urls, to: collection.id, in: library) { AppModel.shared.message = $0 }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func plate(_ image: CollectionImage, number: Int) -> some View {
        let caption = captions[image.id ?? 0] ?? image.caption ?? ""
        return VStack(alignment: .leading, spacing: 5) {
            PhotoWell(url: try? model.library?.url(forLibraryPath: image.path), height: 104)
                .accessibilityElement()
                .accessibilityLabel("Photo \(number)")
            if !caption.isEmpty {
                Text(caption)
                    .font(Theme.serif(13).italic())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
                    .help(caption)
            }
        }
    }

    // MARK: Reels

    private func reels(_ tapes: [ShelfTape], places: [SitePresence]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Reels in this collection")
                    .font(Theme.serif(size.sectionTitle))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !tapes.isEmpty {
                    Text(TimeLabel.long(tapes.reduce(0) { $0 + $1.duration }))
                        .font(Theme.mono())
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                Button("Add reels…") { sheet = .addReels }
                    .buttonStyle(.paperStandard)
                    .accessibilityLabel("Add reels…")
            }
            if tapes.isEmpty {
                Text("No reels yet. Drag a tape from the shelf onto this collection in the sidebar, choose Collection in a tape’s menu, or pick this collection when you record.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(4)
            } else {
                Text("Drag to set the collection’s reading order. Its public page lists published reels.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                VStack(spacing: 0) {
                    ReelColumnNames()
                    ForEach(Array(tapes.enumerated()), id: \.element.id) { index, tape in
                        ReelGap(place: index, isRuled: index > 0)
                        ReelRow(tape: tape, number: index + 1, place: places[index], size: size)
                    }
                    ReelGap(place: tapes.count, isRuled: true)
                }
            }
        }
    }

    // MARK: Sending and deleting

    /// Saves what's being typed first, so the push sends it.
    private func send(publish: Bool? = nil) {
        let id = collection.id
        Task {
            await saveAndWait()
            model.pushModel.pushCollection(id, publish: publish)
        }
    }

    /// Deletes the collection, from the site too if it's there.
    private func delete() {
        let id = collection.id
        // Read now, as the dialog was: a push can finish while the sheet is open.
        let isOnSite = model.collections.first { $0.id == id }?.collection.isOnSite ?? collection.collection.isOnSite
        // The site sheet shows how a removal from the site goes.
        sheet = isOnSite ? .site : nil
        isDeleting = isOnSite
        Task {
            await saveAndWait()
            if isOnSite {
                // Marks the push model busy before returning, so the sheet stays disabled.
                model.pushModel.removeCollectionFromSite(id, andHere: true)
                isDeleting = false
            } else {
                await model.deleteCollection(id)
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

    /// Saves shortly after typing stops, so every keystroke isn't a write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// A blank name isn't saved, so the fields go back to the name the library kept.
    private func keepName() {
        let stored = collection.collection.name
        fields = fields?.keepingName(stored)
        saved = saved?.keepingName(stored)
    }

    /// Saves anything typed and not yet saved, and returns once it's in the library,
    /// along with any write already started.
    private func saveAndWait() async {
        saveTask?.cancel()
        await pendingWrite?.value
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
        var changed: CollectionFields?
        if let fields, fields != saved {
            saved = fields
            changed = fields
        }
        var captionChanges: [(Int64, String)] = []
        for (imageID, caption) in captions where savedCaptions[imageID] != caption {
            savedCaptions[imageID] = caption
            captionChanges.append((imageID, caption))
        }
        guard changed != nil || !captionChanges.isEmpty else { return }
        // After any write before it, so they land in order, and kept so a push can wait.
        let previous = pendingWrite
        let model = model
        pendingWrite = Task {
            await previous?.value
            if let changed { await model.saveCollection(id, fields: changed) }
            for (imageID, caption) in captionChanges {
                try? await Task.detached { try await library.setCollectionCaption(imageID: imageID, caption: caption) }.value
            }
        }
    }
}

/// What opens over a collection's page.
private enum CollectionSheet: String, Identifiable {
    case edit, photos, site, addReels

    var id: String { rawValue }
}

/// The table's fixed column widths. The reel's title takes what's left.
private enum ReelColumns {
    static let order: CGFloat = 56
    static let number: CGFloat = 58
    static let length: CGFloat = 56
    static let site: CGFloat = 104
    static let spacing: CGFloat = 10
    /// Space inside each row, at both ends.
    static let inset: CGFloat = 10
}

private struct ReelColumnNames: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ReelColumns.spacing) {
                CapLabel("Order")
                    .frame(width: ReelColumns.order, alignment: .leading)
                CapLabel("Number")
                    .frame(width: ReelColumns.number, alignment: .leading)
                CapLabel("Reel")
                    .frame(maxWidth: .infinity, alignment: .leading)
                CapLabel("Length")
                    .frame(width: ReelColumns.length, alignment: .leading)
                CapLabel("Site")
                    .frame(width: ReelColumns.site, alignment: .leading)
            }
            .padding(.horizontal, ReelColumns.inset)
            .padding(.vertical, 9)
            HairlineRule()
        }
        // The rows are read out by what they hold.
        .accessibilityHidden(true)
    }
}

/// One reel in a collection's list. Click to select it, double-click it or click
/// its title to open it, and drag the handle to move it.
private struct ReelRow: View {
    @Environment(AppModel.self) private var model
    let tape: ShelfTape
    let number: Int
    let place: SitePresence
    let size: LayoutSize

    private var isSelected: Bool { model.selectedTapeID == tape.id }

    private var tone: StatusBadge.Tone {
        switch place {
        case .localOnly: .idle
        case .draftOnSite: .draft
        case .published: .published
        }
    }

    var body: some View {
        HStack(spacing: ReelColumns.spacing) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Theme.muted)
                    .frame(width: 22, height: 28)
                    .contentShape(.rect)
                    .draggable(TapeDrag.payload(tape.id)) {
                        Text(tape.tape.title)
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.inset, in: .rect(cornerRadius: 6))
                    }
                    .help("Drag to move")
                    .accessibilityLabel("Move \(tape.tape.title)")
                Text("\(number)")
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
            }
            .frame(width: ReelColumns.order, alignment: .leading)

            Text(tape.tape.catalogNumber ?? "—")
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .help(tape.tape.catalogNumber ?? "No number")
                .frame(width: ReelColumns.number, alignment: .leading)
                .accessibilityLabel(tape.tape.catalogNumber ?? "No number")

            Button {
                model.openReview(tape)
            } label: {
                Text(tape.tape.title)
                    .font(Theme.serif(size.rowName))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open \(tape.tape.title)")
            .accessibilityLabel(tape.tape.title)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TimeLabel.clock(tape.duration))
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .frame(width: ReelColumns.length, alignment: .leading)

            StatusBadge(text: place.label, tone: tone)
                .frame(width: ReelColumns.site, alignment: .leading)
        }
        .padding(.horizontal, ReelColumns.inset)
        .padding(.vertical, 4)
        .background(isSelected ? Theme.picked : .clear)
        .contentShape(.rect)
        .onTapGesture { model.select(tape) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openReview(tape) })
        .contextMenu {
            Button("Open") { model.openReview(tape) }
            Button("Remove from Collection") { Task { await model.setCollection(tape, to: nil) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Select") { model.select(tape) }
    }
}

/// The space between two reels, which shows where a dragged reel will land.
private struct ReelGap: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    let place: Int
    /// Whether it draws the line under the reel above.
    let isRuled: Bool

    var body: some View {
        ZStack {
            Color.clear
            if isTargeted {
                Capsule().fill(Theme.accent).frame(height: 3)
            } else if isRuled {
                HairlineRule()
            }
        }
        .frame(height: 11)
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

/// A photo cropped to fill a space of a set height, however wide that is.
private struct PhotoWell: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        Theme.hero
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay { Thumbnail(url: url).allowsHitTesting(false) }
            .clipShape(.rect(cornerRadius: 3))
    }
}

/// Copies photos into a collection, one at a time, reporting any that can't be.
private func addCollectionPhotos(
    _ urls: [URL],
    to collectionID: Int64,
    in library: Library,
    failed: @escaping @MainActor @Sendable (String) -> Void
) {
    Task.detached {
        for url in urls {
            do {
                try await library.addImage(collectionID: collectionID, from: url)
            } catch {
                await failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Sheets

/// A sheet's title and Done button, over its contents.
private struct SheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Theme.serif(27))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(.paperPrimary)
                    .accessibilityLabel("Done")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            HairlineRule()
        }
    }
}

/// The name, where and when the box was found, the write-up, and deleting it all.
private struct EditCollectionSheet: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false

    let collectionID: Int64
    @Binding var fields: CollectionFields?
    let onChange: () -> Void
    let delete: () -> Void

    private var record: TapeCollection? {
        model.collections.first { $0.id == collectionID }?.collection
    }

    var body: some View {
        let name = record?.name ?? ""
        let isOnSite = record?.isOnSite == true
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Edit collection")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("Name") {
                        TextField("Name", text: binding(\.name))
                            .font(Theme.serif(19))
                            .paperField()
                            .accessibilityLabel("Name")
                    }
                    HStack(alignment: .top, spacing: 14) {
                        labeled("Where found") {
                            TextField("Garage sale, Joliet IL", text: binding(\.whereFound))
                                .paperField()
                                .accessibilityLabel("Where found")
                        }
                        labeled("Date acquired") {
                            TextField("October 2023", text: binding(\.dateFound))
                                .paperField()
                                .accessibilityLabel("Date acquired")
                        }
                    }
                    hint("Reels in this collection use these unless they have their own.")
                    labeled("Write-up") {
                        TextEditor(text: binding(\.description))
                            .font(Theme.serif(16))
                            .foregroundStyle(Theme.ink)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 220)
                            .background(Theme.field, in: .rect(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Theme.fieldBorder)
                                    .allowsHitTesting(false)
                            }
                            .accessibilityLabel("Write-up")
                        hint("What the box says about whoever kept it. Blank lines separate paragraphs.")
                    }
                }
                .padding(20)
            }

            HairlineRule()

            HStack {
                Button("Delete Collection…", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.paperStandard)
                    .accessibilityLabel("Delete Collection…")
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        // A fixed size, so the text in it is never measured at no width.
        .frame(width: 560, height: 560)
        .background(Theme.paper)
        .confirmationDialog("Delete the collection “\(name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(isOnSite ? "Delete Here and From the Site" : "Delete Collection", role: .destructive) {
                delete()
            }
        } message: {
            Text(isOnSite
                 ? "It’s removed from the site too. Its reels stay, here and on the site, outside any collection. Its write-up is removed, and its photos go to the Trash."
                 : "Its reels stay on the shelf, outside any collection. Its write-up is removed, and its photos go to the Trash.")
        }
    }

    private func binding(_ path: WritableKeyPath<CollectionFields, String>) -> Binding<String> {
        Binding(
            get: { fields?[keyPath: path] ?? "" },
            set: { fields?[keyPath: path] = $0; onChange() }
        )
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
}

/// A collection's photos, in the order its page shows them.
private struct CollectionPhotosSheet: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    /// Shown here, since the window's own alert waits behind a sheet.
    @State private var problem: String?

    let collectionID: Int64
    @Binding var captions: [Int64: String]
    let onCaptionChange: () -> Void

    private var images: [CollectionImage] {
        model.collections.first { $0.id == collectionID }?.images ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Box photographs")

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
                        .accessibilityLabel("Add Photos…")
                    Text("The box, its lid, labels, track sheets. Or drop them here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            .padding(20)
        }
        // A fixed size, so the text in it is never measured at no width.
        .frame(width: 580, height: 500)
        .background(isDropTargeted ? Theme.inset : Theme.paper)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func card(_ image: CollectionImage, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PhotoWell(url: try? model.library?.url(forLibraryPath: image.path), height: 110)
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
        panel.message = "Choose photos of the box, its labels or anything that came with it."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        guard let library = model.library else { return }
        problem = nil
        addCollectionPhotos(urls, to: collectionID, in: library) { problem = $0 }
    }

    private func move(_ image: CollectionImage, by offset: Int) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.moveCollectionImage(id: id, by: offset) }
    }

    private func remove(_ image: CollectionImage) {
        guard let library = model.library, let id = image.id else { return }
        Task.detached { try? await library.removeCollectionImage(id: id) }
    }
}

/// Where the collection stands on the site, and what can be sent there.
private struct CollectionSiteSheet: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingRemove = false

    let collectionID: Int64
    /// A confirmed delete is saving before it removes the collection from the site.
    let isDeleting: Bool
    /// Saves what's typed and sends the collection. A value changes whether it's public.
    let send: (Bool?) -> Void

    /// Whether anything is going to the site, or about to.
    private var isBusy: Bool { model.pushModel.isPushing || isDeleting }

    var body: some View {
        let collection = model.collections.first { $0.id == collectionID }
        let name = collection?.collection.name ?? ""
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Site draft")

            ScrollView {
                if let collection {
                    panel(collection)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if collection?.collection.isOnSite == true {
                HairlineRule()
                HStack {
                    Button("Remove from Site…", role: .destructive) { confirmingRemove = true }
                        .buttonStyle(.paperStandard)
                        .accessibilityLabel("Remove from Site…")
                        .disabled(isBusy)
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        }
        // A fixed size, so the text in it is never measured at no width.
        .frame(width: 500, height: 420)
        .background(Theme.paper)
        .confirmationDialog("Remove “\(name)” from the site?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove from Site", role: .destructive) {
                guard !isDeleting else { return }
                model.pushModel.removeCollectionFromSite(collectionID)
            }
        } message: {
            Text("Its page goes away and its reels stay on the site, outside any collection. Everything here is kept, ready to push again.")
        }
    }

    private func panel(_ collection: ShelfCollection) -> some View {
        let push = model.pushModel
        let record = collection.collection
        let isSyncing = push.syncingCollectionID == collection.id
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                CapLabel("Site status")
                Text(status(collection))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
            }

            if isSyncing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if let progress = push.progress {
                        Text(progressText(progress))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                    }
                }
            } else {
                HStack(spacing: 9) {
                    if !record.isOnSite {
                        Button("Push to Site") { send(nil) }
                            .buttonStyle(.paperPrimary)
                            .accessibilityLabel("Push to Site")
                            .disabled(isBusy)
                            .help("Sends it as an unpublished draft, with its write-up, photos and reels")
                    } else {
                        Button("Send Changes") { send(nil) }
                            .buttonStyle(.paperPrimary)
                            .accessibilityLabel("Send Changes")
                            .disabled(isBusy || !collection.hasUnsentChanges)
                        Button(record.sitePublished ? "Unpublish" : "Publish") { send(!record.sitePublished) }
                            .buttonStyle(.paperStandard)
                            .accessibilityLabel(record.sitePublished ? "Unpublish" : "Publish")
                            .disabled(isBusy)
                    }
                }
            }

            if !isSyncing {
                if let failure = push.collectionFailure, failure.id == collection.id {
                    Text(failure.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.attention)
                        .textSelection(.enabled)
                } else if let note = push.collectionNote, note.id == collection.id {
                    Text(note.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                } else if collection.missingReelCount > 0 {
                    Text(collection.missingReelCount == 1
                         ? "1 reel isn’t on the site yet. It joins this collection there when it’s pushed."
                         : "\(collection.missingReelCount) reels aren’t on the site yet. They join this collection there when they’re pushed.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }

            HairlineRule()

            VStack(alignment: .leading, spacing: 6) {
                CapLabel("Page address")
                Text("remanencearchive.com/collections/\(record.slug)")
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }
        }
    }

    private func status(_ collection: ShelfCollection) -> String {
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
}

/// Picks tapes to put at the end of a collection. A tape in another one moves here.
private struct AddReelsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<ShelfTape.ID> = []

    let collectionID: Int64

    var body: some View {
        // Every tape that isn't in this collection.
        let others = model.shelf.filter { $0.tape.collectionId != collectionID }
        let chosen = others.filter { picked.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add reels")
                    .font(Theme.serif(27))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("They join the end of the reading order. A reel in another collection moves to this one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            .padding(20)

            HairlineRule()

            ScrollView {
                if others.isEmpty {
                    Text(model.shelf.isEmpty ? "No tapes on the shelf yet." : "Every tape is already in this collection.")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(others) { tape in
                            row(tape)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }

            HairlineRule()

            HStack(spacing: 9) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.paperStandard)
                    .accessibilityLabel("Cancel")
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Add \(chosen.count) reels" : "Add reel") { add(chosen) }
                    .buttonStyle(.paperPrimary)
                    .accessibilityLabel(chosen.count > 1 ? "Add \(chosen.count) reels" : "Add reel")
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
            .padding(20)
        }
        // A fixed size, so the text in it is never measured at no width.
        .frame(width: 520, height: 480)
        .background(Theme.paper)
    }

    private func row(_ tape: ShelfTape) -> some View {
        let current = model.collection(of: tape)?.collection.name
        return VStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { picked.contains(tape.id) },
                set: { isOn in
                    if isOn { picked.insert(tape.id) } else { picked.remove(tape.id) }
                }
            )) {
                HStack(spacing: 10) {
                    Text(tape.tape.catalogNumber ?? "—")
                        .font(Theme.mono())
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .frame(width: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tape.tape.title)
                            .font(Theme.serif(16))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if let current {
                            Text("In \(current)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(TimeLabel.clock(tape.duration))
                        .font(Theme.mono())
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
                .padding(.leading, 4)
                .contentShape(.rect)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel([
                tape.tape.catalogNumber, tape.tape.title, current.map { "In \($0)" }, TimeLabel.clock(tape.duration),
            ].compactMap(\.self).joined(separator: ", "))
            .padding(.vertical, 9)
            HairlineRule()
        }
    }

    /// One at a time, so they land in the order listed.
    private func add(_ tapes: [ShelfTape]) {
        let model = model
        let id = collectionID
        Task {
            for tape in tapes { await model.setCollection(tape, to: id) }
        }
        dismiss()
    }
}
