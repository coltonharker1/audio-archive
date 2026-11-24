import RemanenceCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            // Search stays on the split view itself, which owns the toolbar it sits in.
            splitView
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search every word on every tape")
                .searchFocused($isSearchFocused)
            StatusBar()
        }
        .onChange(of: model.searchRequested) { _, requested in
            if requested {
                isSearchFocused = true
                model.searchRequested = false
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.add(urls) }
            return !urls.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                DropOverlay()
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.importProgress != nil {
                    ImportBanner()
                }
                switch model.route {
                case .readAlong:
                    if let tape = model.selectedTape {
                        ReadAlongView(tape: tape)
                    }
                case .record:
                    RecordView()
                case .post:
                    if let tape = model.selectedTape {
                        SitePostView(tape: tape)
                    }
                case .review:
                    if let tape = model.selectedTape {
                        ReviewView(tape: tape)
                    }
                case .edit:
                    if let tape = model.selectedTape {
                        EditView(tape: tape)
                    }
                case .search:
                    SearchResultsView()
                case .catalog:
                    CatalogView()
                case .sitePosts:
                    SitePostsView()
                case .setup:
                    SetupView()
                case .shelf:
                    if let collection = model.selectedCollection {
                        CollectionView(collection: collection)
                            .id(collection.id)
                    } else if model.shelf.isEmpty && model.hasLoadedShelf {
                        EmptyShelfView()
                    } else {
                        ShelfView()
                    }
                    if model.selectedTape != nil {
                        TapePanel()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Breadcrumb()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // The breadcrumb says where this is, in place of the window's title.
            .toolbar(removing: .title)
            .toolbarBackground(Theme.bar, for: .windowToolbar)
        }
    }
}

/// Where the screen showing sits, such as "Library / Catalog".
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model

    private var crumbs: [String] {
        switch model.route {
        case .shelf:
            if let collection = model.selectedCollection {
                ["Collections", collection.collection.name]
            } else {
                ["Library", "Shelf"]
            }
        case .search: ["Library", "Search"]
        case .catalog: ["Library", "Catalog"]
        case .sitePosts: ["Library", "Site Posts"]
        case .setup: ["Setup"]
        // Leaving the recorder goes back to the collection it was opened from.
        case .record: [model.selectedCollection?.collection.name ?? "Shelf", "Recording"]
        case .review: tapeCrumbs("Review")
        case .edit: tapeCrumbs("Edit")
        case .readAlong: tapeCrumbs("Read Along")
        case .post: tapeCrumbs("Site Post")
        }
    }

    /// The first crumb is where Back goes from a tape's screen.
    private func tapeCrumbs(_ screen: String) -> [String] {
        var origin = model.backLabel
        if origin != "Results", let collection = model.selectedCollection {
            origin = collection.collection.name
        }
        let tape = model.selectedTape.map { $0.tape.catalogNumber ?? $0.tape.title }
        return [origin, tape, screen].compactMap(\.self)
    }

    /// Long names are cut here, since a toolbar item takes whatever width it asks for.
    private func shortened(_ name: String) -> String {
        name.count > 24 ? name.prefix(23).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    var body: some View {
        let crumbs = crumbs
        HStack(spacing: 10) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                let isHere = index == crumbs.count - 1
                if index > 0 {
                    Text("/")
                        .foregroundStyle(Theme.crumbSeparator)
                        .accessibilityHidden(true)
                }
                Text(shortened(crumb))
                    .fontWeight(isHere ? .semibold : .regular)
                    .foregroundStyle(isHere ? Theme.ink : Theme.muted)
                    .help(crumb)
                    .accessibilityLabel(crumb)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

/// Every place in the app, with the collections among them and Setup at the foot.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var namingCollection = false
    @State private var newCollectionName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remanence")
                        .font(Theme.serif(29))
                        .tracking(-1.2)
                        .foregroundStyle(Theme.ink)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 14)
                        .accessibilityAddTraits(.isHeader)

                    SidebarRow(title: "Recording", icon: "record.circle", item: .recording)

                    heading("Library")
                    SidebarRow(title: "Shelf", icon: "books.vertical", item: .shelf)
                    SidebarRow(title: "Catalog", icon: "number", item: .catalog)
                        .help("Every reel by RA number, to match the labels on the boxes")
                    SidebarRow(title: "Site Posts", icon: "globe", item: .sitePosts)
                        .help("Every post on the site")

                    heading("Collections")
                    ForEach(model.collections) { collection in
                        CollectionSidebarRow(collection: collection)
                    }
                    Button {
                        newCollectionName = ""
                        namingCollection = true
                    } label: {
                        SidebarLabel(title: "New collection…", icon: "plus")
                            .foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
            }

            HairlineRule()
                .padding(.horizontal, 12)
            SidebarRow(title: "Setup", icon: "slider.horizontal.3", item: .setup)
                .padding(12)
        }
        .background(Theme.rail.ignoresSafeArea())
        .alert("New Collection", isPresented: $namingCollection) {
            TextField("The Cable Man", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName
                Task { await model.createCollection(named: name) }
            }
            .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reels that came in the same box. Name it whatever you like.")
        }
    }

    private func heading(_ title: String) -> some View {
        CapLabel(title)
            .padding(.horizontal, 10)
            .padding(.top, 20)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One of the app's fixed destinations.
private struct SidebarRow: View {
    @Environment(AppModel.self) private var model

    let title: String
    let icon: String
    let item: SidebarItem

    var body: some View {
        let isSelected = model.sidebarSelection == item
        let showsRecordingDot = item == .recording && model.recordModel.isRecording
        Button {
            model.sidebarSelection = item
        } label: {
            SidebarLabel(title: title, icon: icon, isSelected: isSelected) {
                if showsRecordingDot {
                    Circle()
                        .fill(Theme.needle)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Recording now")
                }
            }
            .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The face of a sidebar row: an icon, a name and anything that trails it.
private struct SidebarLabel<Trailing: View>: View {
    let title: String
    let icon: String
    var isSelected = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.railSelected : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect(cornerRadius: 6))
    }
}

extension SidebarLabel where Trailing == EmptyView {
    init(title: String, icon: String) {
        self.init(title: title, icon: icon) { EmptyView() }
    }
}

/// A collection in the sidebar. Drop a tape on it to put the tape in it.
private struct CollectionSidebarRow: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var confirmingDelete = false
    let collection: ShelfCollection

    var body: some View {
        let item = SidebarItem.collection(collection.id)
        let isSelected = model.sidebarSelection == item
        Button {
            model.sidebarSelection = item
        } label: {
            SidebarLabel(title: collection.collection.name, icon: "folder", isSelected: isSelected) {
                Text("\(collection.tapeIDs.count)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
            }
            .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
        .help(collection.collection.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Theme.accent.opacity(0.25) : .clear)
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(TapeDrag.tapeID)
            let tapes = model.shelf.filter { ids.contains($0.id) }
            guard !tapes.isEmpty else { return false }
            let id = collection.id
            Task { for tape in tapes { await model.setCollection(tape, to: id) } }
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button("Delete Collection…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete the collection “\(collection.collection.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Collection", role: .destructive) {
                let id = collection.id
                Task { await model.deleteCollection(id) }
            }
        } message: {
            Text("Its reels stay on the shelf, outside any collection. Its write-up is removed, and its photos go to the Trash.")
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.paper.opacity(0.88)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(18)
            VStack(spacing: 6) {
                Text("Drop to add to your shelf")
                    .font(Theme.display(32))
                    .foregroundStyle(Theme.ink)
                Text("A folder becomes one tape, with a track for each file.")
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct EmptyShelfView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Text("Your shelf is empty")
                .font(Theme.display(38))
                .foregroundStyle(Theme.ink)
            Text("Drop audio here, or import your backup to bring your tapes home.")
                .foregroundStyle(Theme.inkMuted)
            Button("Import Backup…") { model.chooseBackupToImport() }
                .controlSize(.large)
                .padding(.top, 8)
                .disabled(model.importProgress != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let progress = model.importProgress {
            HStack(spacing: 12) {
                ProgressView(value: progress.fraction)
                    .frame(width: 160)
                    .accessibilityLabel("Import progress")
                Text(progress.tape.isEmpty ? "Reading your backup…" : "Checking and copying “\(progress.tape)”")
                    .lineLimit(1)
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Theme.card)
        }
    }
}
