import RemanenceCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @State private var showsSitePosts = false
    @State private var showsCatalog = false
    @State private var namingCollection = false
    @State private var newCollectionName = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: Binding(
                get: { model.sidebarSelection },
                set: { if let item = $0 { model.sidebarSelection = item } }
            )) {
                Section("Library") {
                    ForEach(ShelfFilter.allCases) { filter in
                        HStack {
                            Text(filter.rawValue)
                            Spacer()
                            Text("\(model.shelf.filter(filter.includes).count)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .tag(SidebarItem.filter(filter))
                    }
                }
                Section("Collections") {
                    ForEach(model.collections) { collection in
                        CollectionSidebarRow(collection: collection)
                            .tag(SidebarItem.collection(collection.id))
                    }
                    Button {
                        newCollectionName = ""
                        namingCollection = true
                    } label: {
                        Label("New Collection", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
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
            .background(Theme.paper)
        }
        .toolbar {
            if model.route == .shelf {
                ToolbarItem(placement: .primaryAction) {
                    Button("Catalog", systemImage: "number") { showsCatalog = true }
                        .help("Every reel by RA number, to match the labels on the boxes")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Site Posts", systemImage: "globe") { showsSitePosts = true }
                        .help("Every post on the site")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Record a Tape", systemImage: "record.circle") { model.openRecording() }
                }
            }
        }
        .sheet(isPresented: $showsSitePosts) { SitePostsView() }
        .sheet(isPresented: $showsCatalog) { CatalogView() }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search every word on every tape")
        .searchFocused($isSearchFocused)
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
}

/// A collection in the sidebar. Drop a tape on it to put the tape in it.
private struct CollectionSidebarRow: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var confirmingDelete = false
    let collection: ShelfCollection

    var body: some View {
        HStack {
            Label(collection.collection.name, systemImage: "shippingbox")
                .lineLimit(1)
            Spacer()
            Text("\(collection.tapeIDs.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .background(isTargeted ? Theme.accent.opacity(0.25) : .clear, in: .rect(cornerRadius: 5))
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
