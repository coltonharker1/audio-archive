import RemanenceCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(ShelfFilter.allCases, selection: Binding(
                get: { model.filter },
                set: { if let filter = $0 { model.filter = filter } }
            )) { filter in
                HStack {
                    Text(filter.rawValue)
                    Spacer()
                    Text("\(model.shelf.filter(filter.includes).count)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .tag(filter)
            }
            .listStyle(.sidebar)
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
                case .search:
                    SearchResultsView()
                case .shelf:
                    if model.shelf.isEmpty && model.hasLoadedShelf {
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
                    Button("Record a Tape", systemImage: "record.circle") { model.openRecording() }
                }
            }
        }
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
