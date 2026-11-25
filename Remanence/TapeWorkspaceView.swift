import RemanenceCore
import SwiftUI

/// One tape's screens: a header and a row of tabs, with the chosen screen below.
struct TapeWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var size = LayoutSize.compact
    /// Whether Review's track column is showing.
    @State private var showsReviewTracks = true
    /// Whether Edit's track settings are showing.
    @State private var showsEditInspector = true
    /// Whether Read Along's details are showing.
    @State private var showsReadAlongDetails = true
    /// Whether Site Post's status column is showing.
    @State private var showsSiteStatus = true

    let tape: ShelfTape

    /// Review's track column holds Side options at its foot, so the header only
    /// offers them while that column isn't on screen.
    private var showsSideOptionsInHeader: Bool {
        !(model.route == .review && showsReviewTracks && model.reviewModel.isReady)
    }

    var body: some View {
        VStack(spacing: 0) {
            TapeHeader(tape: tape, size: size, showsSideOptions: showsSideOptionsInHeader)
            // Only the tab showing is in the view tree, because screens save what was
            // typed in them as they leave it.
            tab
                .id(tape.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.paper)
        .onGeometryChange(for: LayoutSize.self) { geometry in
            LayoutSize(detailWidth: geometry.size.width)
        } action: {
            size = $0
        }
    }

    @ViewBuilder private var tab: some View {
        switch model.route {
        case .review: ReviewView(showsTracks: $showsReviewTracks, size: size)
        case .edit: EditView(tape: tape, showsInspector: $showsEditInspector, size: size)
        case .readAlong: ReadAlongView(tape: tape, showsDetails: $showsReadAlongDetails, size: size)
        case .post: SitePostView(tape: tape, showsStatus: $showsSiteStatus, size: size)
        case .shelf, .search, .record, .catalog, .sitePosts, .setup: EmptyView()
        }
    }
}

/// The tape's number, title and place, with the tabs underneath.
private struct TapeHeader: View {
    @Environment(AppModel.self) private var model

    let tape: ShelfTape
    let size: LayoutSize
    let showsSideOptions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let eyebrow {
                    EyebrowLabel(eyebrow)
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
                TapeActivity(tape: tape)
            }
            .frame(minHeight: 16)

            Text(tape.tape.title)
                .font(Theme.serif(size.pageTitle))
                .tracking(size == .regular ? -1.9 : -1)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .help(tape.tape.title)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

            subtitle

            TapeTabs()
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
    }

    /// Such as `RA-019 / 5" Reel-to-Reel`, or nil when the tape has neither yet.
    private var eyebrow: String? {
        let medium = tape.tape.medium.map { SiteMedium(rawValue: $0)?.label ?? $0 }
        let parts = [tape.tape.catalogNumber, medium].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private var subtitle: some View {
        HStack(spacing: 8) {
            if let collection = model.collection(of: tape) {
                HStack(spacing: 4) {
                    Text("From the collection")
                        .fixedSize()
                    Button {
                        model.sidebarSelection = .collection(collection.id)
                    } label: {
                        Text(collection.collection.name)
                            .underline()
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(collection.collection.name)")
                }
                separator
            }
            if tape.items.count > 1 {
                SideSwitcher(tape: tape)
                separator
            } else if let side = tape.items.first?.source.side {
                Text("Side \(side)")
                    .lineLimit(1)
                separator
            }
            Text(TimeLabel.clock(model.selectedItem?.source.duration ?? tape.duration))
                .font(Theme.mono())
                .fixedSize()
            Spacer(minLength: 8)
            if showsSideOptions {
                SideOptionsMenu(tape: tape)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.muted)
        .frame(minHeight: 22)
    }

    private var separator: some View {
        Text("·")
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// What's being done with the tape, or what went wrong and a way to try again.
private struct TapeActivity: View {
    @Environment(AppModel.self) private var model

    let tape: ShelfTape

    var body: some View {
        if case .failed(let reason) = tape.status {
            HStack(spacing: 8) {
                Text(reason)
                    .lineLimit(1)
                    .help(reason)
                    .textSelection(.enabled)
                Button("Try Again") { Task { await model.retry(tape) } }
                    .controlSize(.small)
                    .fixedSize()
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.attention)
        } else if let text = model.activityText(for: tape) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
        }
    }
}

/// Which of the tape's recordings is chosen.
private struct SideSwitcher: View {
    @Environment(AppModel.self) private var model

    let tape: ShelfTape

    var body: some View {
        let name = model.selectedItem?.name ?? "Recording"
        Menu {
            Picker("Recording", selection: Binding(
                get: { model.selectedItemIndex },
                set: { if $0 != model.selectedItemIndex { model.choose(itemAt: $0) } }
            )) {
                ForEach(Array(tape.items.enumerated()), id: \.element.id) { index, item in
                    Text(item.name).tag(index)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // Cut here, since a menu takes whatever width its label asks for.
            Text(name.count > 24 ? name.prefix(23).trimmingCharacters(in: .whitespaces) + "…" : name)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(name)
        .accessibilityLabel("Recording: \(name)")
    }
}

/// Renaming and deleting the chosen recording. Only offered while the tape isn't on
/// the site.
struct SideOptionsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: SideAction?
    @State private var renaming: SideAction?
    @State private var newSideName = ""

    let tape: ShelfTape

    /// A tape's only recording can be renamed once it has a side name, and never
    /// deleted from here.
    static func isOffered(for tape: ShelfTape, item: ShelfTape.Item?) -> Bool {
        guard tape.tape.pushedAt == nil, let item else { return false }
        return tape.items.count > 1 || item.source.side != nil
    }

    var body: some View {
        if let item = model.selectedItem, Self.isOffered(for: tape, item: item) {
            Menu("Side options") {
                Button("Rename Side…") {
                    newSideName = item.source.side ?? ""
                    renaming = SideAction(tape: tape, item: item)
                }
                if tape.items.count > 1 {
                    Button("Delete Side…", role: .destructive) {
                        deleting = SideAction(tape: tape, item: item)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .confirmationDialog(
                deleting.map { "Delete \($0.item.name)?" } ?? "",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { action in
                Button("Delete", role: .destructive) {
                    Task { await model.removeSide(action.item, of: action.tape) }
                }
            } message: { _ in
                Text("Its audio moves to the Trash, and its transcript and track markers are removed. The sides after it move up.")
            }
            .alert(
                "Rename Side",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                presenting: renaming
            ) { action in
                TextField("Side", text: $newSideName)
                Button("Rename") {
                    let name = newSideName
                    Task { await model.renameSide(action.item, to: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text("A new name for \(action.item.name), like B.")
            }
        }
    }
}

/// A side waiting for a name or for confirmation.
private struct SideAction {
    let tape: ShelfTape
    let item: ShelfTape.Item
}

private struct TapeTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Route.tapeTabs, id: \.self) { tab in
                let isSelected = model.route == tab
                Button {
                    model.switchTab(tab)
                } label: {
                    Text(tab.tabTitle ?? "")
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 6)
                        .padding(.bottom, 9)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Rectangle().fill(Theme.ink).frame(height: 2)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { HairlineRule() }
    }
}
