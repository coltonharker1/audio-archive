import RemanenceCore
import SwiftUI

/// Every reel by RA number, so the numbers can match the labels on the boxes. Drag a
/// reel to a new place, or type a number. The changes wait in the right column, and
/// nothing changes until Apply.
struct CatalogView: View {
    @Environment(AppModel.self) private var model

    /// What's being typed into a number field, by tape.
    @State private var typing: [Int64: String] = [:]
    @State private var confirming = false
    /// The width of the detail area, which sets sizes.
    @State private var width: CGFloat = 680

    private var size: LayoutSize { LayoutSize(detailWidth: width) }

    /// The mocks' padding follows the window's width, which is wider than this
    /// screen by the sidebar.
    private var padding: CGFloat { LayoutSize.pagePadding(windowWidth: width + 220) }

    private var columnSpacing: CGFloat { size == .regular ? 28 : 18 }

    var body: some View {
        let pending = model.catalogStaging.pending(in: model.shelf)

        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Library", title: "Catalog", subtitle: "RA numbers match the labels on the boxes.", size: size)
                .padding(.bottom, 25)
            HStack(alignment: .top, spacing: columnSpacing) {
                list
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(width: 1)
                        .accessibilityHidden(true)
                    pendingColumn(pending)
                        .padding(.leading, columnSpacing - 4)
                }
                .frame(width: size.rightColumn)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, padding)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task {
            model.openCatalogList()
            await model.pushModel.refreshSiteNumbers()
        }
        .confirmationDialog("Renumber \(pending.count == 1 ? "1 reel" : "\(pending.count) reels")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Renumber") { model.applyCatalog() }
        } message: {
            Text(confirmMessage(pending))
        }
    }

    // MARK: The list

    private var list: some View {
        let staging = model.catalogStaging
        let byID = Dictionary(uniqueKeysWithValues: model.shelf.map { ($0.id, $0) })
        let unnumbered = staging.unnumbered(in: model.shelf)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("By RA number")
                    .font(Theme.serif(size.sectionTitle))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(staging.order.count == 1 ? "1 reel" : "\(staging.order.count) reels")
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
            }
            // A list rather than a drawn table, which keeps its drag to reorder. The
            // column names are a row of it, so they line up with the rows.
            List {
                CatalogColumnNames()
                    .catalogListRow()
                ForEach(staging.order, id: \.self) { id in
                    if let tape = byID[id] {
                        row(tape)
                            .catalogListRow()
                    }
                }
                .onMove { source, destination in
                    // Committing typing can re-sort the list or shorten it, so the drag
                    // is held by tape rather than by place.
                    let order = model.catalogStaging.order
                    let moved = source.filter(order.indices.contains).map { order[$0] }
                    let before = order.indices.contains(destination) ? order[destination] : nil
                    commitAllTyping()
                    model.moveInCatalog(moved, before: before)
                }
                .moveDisabled(model.isApplyingCatalog)

                note(unnumbered.isEmpty
                    ? "Drag a reel or enter its new number to stage a change."
                    : "Drag a reel or enter its new number to stage a change. Tapes without a number are below. Type one to give it a number.")
                    .catalogListRow()

                if !unnumbered.isEmpty {
                    CapLabel("No number")
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, CatalogColumns.inset)
                        .padding(.top, 14)
                        .padding(.bottom, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { HairlineRule() }
                        .catalogListRow()
                    ForEach(unnumbered) { tape in
                        row(tape)
                            .catalogListRow()
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .lineLimit(5)
            .padding(.horizontal, CatalogColumns.inset)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ tape: ShelfTape) -> some View {
        let original = tape.tape.catalogNumber
        let number = model.catalogStaging.number(of: tape)
        let changed = number != original
        let collection = model.collection(of: tape)?.collection.name

        return HStack(spacing: CatalogColumns.spacing) {
            Group {
                // Only numbered reels can be dragged.
                if model.catalogStaging.order.contains(tape.id) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(Theme.muted)
                        .help("Drag to move")
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: CatalogColumns.move, alignment: .leading)

            Text(original ?? "—")
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .help(original ?? "No number")
                .frame(width: CatalogColumns.current, alignment: .leading)
                .accessibilityLabel(original.map { "Now \($0)" } ?? "No number")

            VStack(alignment: .leading, spacing: 3) {
                Text(tape.tape.title)
                    .font(Theme.serif(size.rowName))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .help(tape.tape.title)
                if let collection {
                    Text(collection)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .help(collection)
                        .accessibilityLabel("In the collection \(collection)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("RA-000", text: Binding(
                get: { typing[tape.id] ?? number ?? "" },
                set: { typing[tape.id] = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: changed ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .padding(6)
            .background(Theme.field, in: .rect(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.fieldBorder) }
            .frame(width: CatalogColumns.proposed)
            .onSubmit { commitTyping(tape.id) }
            .disabled(model.isApplyingCatalog)
            .accessibilityLabel("Proposed number for \(tape.tape.title)")
        }
        .padding(.horizontal, CatalogColumns.inset)
        .padding(.vertical, 9)
        .background(changed ? Theme.picked : .clear)
        .overlay(alignment: .bottom) { HairlineRule() }
    }

    // MARK: Pending changes

    private func pendingColumn(_ pending: [CatalogStaging.Pending]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CapLabel("Pending changes")
                .padding(.bottom, 6)
            Text(pending.heading ?? "Nothing staged")
                .font(Theme.serif(size.sectionTitle - 3))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 14)

            if !pending.isEmpty {
                // The list scrolls only when it's too long, so Apply stays in view.
                ViewThatFits(in: .vertical) {
                    pendingList(pending)
                    ScrollView { pendingList(pending) }
                }
                HairlineRule()
                    .padding(.vertical, 16)
                Text(pending.explanation)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(6)
                    .layoutPriority(1)
            }

            if let failure = model.catalogFailure {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.attention)
                    .lineLimit(7)
                    .help(failure)
                    .textSelection(.enabled)
                    .padding(.top, 12)
                    .layoutPriority(1)
            }

            HStack(spacing: 9) {
                Button(applyTitle(pending.count)) {
                    commitAllTyping()
                    if !model.catalogStaging.staged.isEmpty { confirming = true }
                }
                .buttonStyle(.paperPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled((pending.isEmpty && typing.isEmpty) || model.isApplyingCatalog)
                Button("Revert") {
                    typing = [:]
                    model.revertCatalog()
                }
                .buttonStyle(.paperStandard)
                .disabled(pending.isEmpty || model.isApplyingCatalog)
                if model.isApplyingCatalog {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Applying")
                }
            }
            .padding(.top, 16)
            .layoutPriority(1)
        }
        // No spacer below, which would take half the room the list could have.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Each changed reel, its two numbers and where it stands with the site.
    private func pendingList(_ pending: [CatalogStaging.Pending]) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: model.shelf.map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(pending) { change in
                VStack(alignment: .leading, spacing: 0) {
                    Text(change.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .help(change.title)
                    HStack(spacing: 10) {
                        Text(change.current ?? "No number")
                        Spacer(minLength: 0)
                        Text("→  \(change.proposed)")
                    }
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.vertical, 8)
                    if let tape = byID[change.tapeID] {
                        siteBadge(SitePresence(tape))
                            .padding(.bottom, 8)
                    }
                    HairlineRule()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func siteBadge(_ place: SitePresence) -> StatusBadge {
        let tone: StatusBadge.Tone = switch place {
        case .localOnly: .idle
        case .draftOnSite: .draft
        case .published: .published
        }
        return StatusBadge(text: place.label, tone: tone)
    }

    private func applyTitle(_ count: Int) -> String {
        switch count {
        case 0: "Apply…"
        case 1: "Apply 1 change…"
        default: "Apply \(count) changes…"
        }
    }

    private func confirmMessage(_ pending: [CatalogStaging.Pending]) -> String {
        let tapes = pending.compactMap { change in model.shelf.first { $0.id == change.tapeID } }
        let published = tapes.filter { SiteSnapshot.decode($0.tape.siteSnapshot)?.published ?? false }
        let onSite = tapes.filter { $0.tape.pushedAt != nil }
        var lines: [String] = []
        if !onSite.isEmpty { lines.append("\(onSite.count) of these \(onSite.count == 1 ? "is" : "are") on the site and \(onSite.count == 1 ? "moves" : "move") there too.") }
        if !published.isEmpty {
            lines.append("\(published.count == 1 ? "1 is" : "\(published.count) are") public. \(published.count == 1 ? "Its old address keeps working" : "Their old addresses keep working"), sent on to the new one.")
        }
        lines.append("Relabel the boxes to match.")
        return lines.joined(separator: " ")
    }

    // MARK: Typing

    private func commitTyping(_ id: Int64) {
        guard let text = typing.removeValue(forKey: id) else { return }
        model.typeCatalogNumber(text, for: id)
    }

    private func commitAllTyping() {
        for id in typing.keys.sorted() { commitTyping(id) }
    }
}

/// The table's fixed column widths. The reel's title takes what's left.
private enum CatalogColumns {
    static let move: CGFloat = 30
    static let current: CGFloat = 58
    static let proposed: CGFloat = 78
    static let spacing: CGFloat = 8
    /// Space inside each row, at both ends.
    static let inset: CGFloat = 6
}

private struct CatalogColumnNames: View {
    var body: some View {
        HStack(spacing: CatalogColumns.spacing) {
            CapLabel("Move")
                .fixedSize()
                .frame(width: CatalogColumns.move, alignment: .leading)
            CapLabel("Current")
                .frame(width: CatalogColumns.current, alignment: .leading)
            CapLabel("Reel")
                .frame(maxWidth: .infinity, alignment: .leading)
            CapLabel("Proposed")
                .frame(width: CatalogColumns.proposed, alignment: .leading)
        }
        .padding(.horizontal, CatalogColumns.inset)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { HairlineRule() }
        // The rows are read out by what they hold.
        .accessibilityHidden(true)
    }
}

private extension View {
    /// A row of the Catalog's list, which draws its own rules and spacing.
    func catalogListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
