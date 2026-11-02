import RemanenceCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

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
                if model.shelf.isEmpty && model.hasLoadedShelf {
                    EmptyShelfView()
                } else {
                    ShelfView()
                }
                if model.selectedTape != nil {
                    TapePanel()
                }
            }
            .background(Theme.paper)
        }
    }
}

private struct EmptyShelfView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Text("Your shelf is empty")
                .font(Theme.display(38))
                .foregroundStyle(Theme.ink)
            Text("Import your backup to bring your tapes home.")
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
