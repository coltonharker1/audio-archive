import RemanenceCore
import SwiftUI

/// Every reel by RA number, so the numbers can match the labels on the boxes. Drag a
/// reel to a new place, or type a number. Nothing changes until Apply.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The numbers as they'll be after Apply, by tape.
    @State private var staged: [Int64: String] = [:]
    /// What's being typed into a number field, by tape.
    @State private var typing: [Int64: String] = [:]
    @State private var order: [Int64] = []
    @State private var failure: String?
    @State private var isApplying = false
    @State private var confirming = false

    private var byID: [Int64: ShelfTape] { Dictionary(uniqueKeysWithValues: model.shelf.map { ($0.id, $0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                Section {
                    ForEach(order, id: \.self) { id in
                        if let tape = byID[id] { row(tape) }
                    }
                    .onMove(perform: move)
                } footer: {
                    if !unnumbered.isEmpty {
                        Text("Tapes without a number are below. Type one to give it a number.")
                    }
                }
                if !unnumbered.isEmpty {
                    Section("No number") {
                        ForEach(unnumbered) { tape in row(tape) }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Theme.paper)
        .task {
            reset()
            await model.pushModel.refreshSiteNumbers()
        }
        // With nothing staged, the list follows the shelf, as it does just after Apply.
        .onChange(of: model.shelf) { _, _ in
            if staged.isEmpty && typing.isEmpty && !isApplying { reset() }
        }
        .confirmationDialog("Renumber \(changes.count == 1 ? "1 reel" : "\(changes.count) reels")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Renumber") { apply() }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Catalog")
                    .font(Theme.display(24))
                    .foregroundStyle(Theme.ink)
                Text("Every reel by RA number. Drag a reel to a new place to swap numbers along, or type a number. Nothing changes until you apply.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func row(_ tape: ShelfTape) -> some View {
        let original = tape.tape.catalogNumber ?? ""
        let number = staged[tape.id] ?? original
        let changed = number != original
        return HStack(spacing: 12) {
            TextField("RA-000", text: Binding(
                get: { typing[tape.id] ?? number },
                set: { typing[tape.id] = $0 }
            ))
            .font(.system(size: 13, weight: changed ? .semibold : .regular, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: 92)
            .onSubmit { commitTyping(tape) }
            .accessibilityLabel("Number for \(tape.tape.title)")
            if changed, !original.isEmpty {
                Text("was \(original)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
            }
            Text(tape.tape.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Group {
                if let collection = model.collection(of: tape) {
                    Label(collection.collection.name, systemImage: "shippingbox")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.inkMuted)
            .frame(width: 190, alignment: .leading)
            Text(status(of: tape))
                .font(.system(size: 11))
                .foregroundStyle(isPublished(tape) ? Theme.good : Theme.inkMuted)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .listRowBackground(changed ? Theme.accent.opacity(0.08) : Color.clear)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
            }
            Spacer()
            if isApplying { ProgressView().controlSize(.small) }
            Button("Revert") { reset() }
                .disabled(changes.isEmpty || isApplying)
            Button("Apply") {
                commitAllTyping()
                if !changes.isEmpty { confirming = true }
            }
            .keyboardShortcut(.defaultAction)
            .disabled((changes.isEmpty && typing.isEmpty) || isApplying)
        }
        .padding(16)
    }

    // MARK: State

    private var unnumbered: [ShelfTape] {
        model.shelf.filter { $0.tape.catalogNumber == nil && !order.contains($0.id) }
    }

    private var changes: [Renumbering] {
        staged.compactMap { id, number in
            guard let tape = byID[id], tape.tape.catalogNumber != number, !number.isEmpty else { return nil }
            return Renumbering(tapeID: id, catalogNumber: number)
        }
    }

    private var summary: String {
        let count = changes.count
        guard count > 0 else { return "\(order.count) reels numbered." }
        let onSite = changes.filter { byID[$0.tapeID]?.tape.pushedAt != nil }.count
        var text = "\(count) \(count == 1 ? "change" : "changes")"
        if onSite > 0 { text += ", \(onSite) on the site" }
        return text + "."
    }

    private var confirmMessage: String {
        let published = changes.filter { byID[$0.tapeID].map(isPublished) ?? false }
        let onSite = changes.filter { byID[$0.tapeID]?.tape.pushedAt != nil }
        var lines: [String] = []
        if !onSite.isEmpty { lines.append("\(onSite.count) of these \(onSite.count == 1 ? "is" : "are") on the site and \(onSite.count == 1 ? "moves" : "move") there too.") }
        if !published.isEmpty {
            lines.append("\(published.count == 1 ? "1 is" : "\(published.count) are") public. \(published.count == 1 ? "Its old address keeps working" : "Their old addresses keep working"), sent on to the new one.")
        }
        lines.append("Relabel the boxes to match.")
        return lines.joined(separator: " ")
    }

    private func status(of tape: ShelfTape) -> String {
        if tape.tape.pushedAt == nil { return "Not pushed" }
        return isPublished(tape) ? "Published" : "Draft"
    }

    private func isPublished(_ tape: ShelfTape) -> Bool {
        SiteSnapshot.decode(tape.tape.siteSnapshot)?.published ?? false
    }

    private func reset() {
        staged = [:]
        typing = [:]
        failure = nil
        order = model.shelf
            .filter { $0.tape.catalogNumber != nil }
            .sorted { (CatalogNumber.parse($0.tape.catalogNumber ?? "") ?? .max) < (CatalogNumber.parse($1.tape.catalogNumber ?? "") ?? .max) }
            .map(\.id)
    }

    private func number(of id: Int64) -> String? {
        staged[id] ?? byID[id]?.tape.catalogNumber
    }

    /// Moving a reel keeps the same set of numbers and deals them out in the new order,
    /// so the reels between where it was and where it went each shift by one.
    private func move(from source: IndexSet, to destination: Int) {
        commitAllTyping()
        let numbers = order.compactMap(number(of:)).sorted { (CatalogNumber.parse($0) ?? 0) < (CatalogNumber.parse($1) ?? 0) }
        order.move(fromOffsets: source, toOffset: destination)
        for (id, number) in zip(order, numbers) { stage(id, number) }
        failure = nil
    }

    private func stage(_ id: Int64, _ number: String) {
        if byID[id]?.tape.catalogNumber == number { staged[id] = nil } else { staged[id] = number }
    }

    private func commitTyping(_ tape: ShelfTape) {
        guard let text = typing[tape.id] else { return }
        typing[tape.id] = nil
        if text.trimmingCharacters(in: .whitespaces).isEmpty { stage(tape.id, tape.tape.catalogNumber ?? ""); return }
        guard let newNumber = CatalogNumber.normalized(text) else {
            failure = "“\(text)” isn’t a catalog number. They look like RA-012."
            return
        }
        failure = nil
        stage(tape.id, newNumber)
        if !order.contains(tape.id) { order.append(tape.id) }
        order.sort { (CatalogNumber.parse(number(of: $0) ?? "") ?? .max) < (CatalogNumber.parse(number(of: $1) ?? "") ?? .max) }
    }

    private func commitAllTyping() {
        for id in typing.keys {
            if let tape = byID[id] { commitTyping(tape) }
        }
    }

    private func apply() {
        let changes = changes
        isApplying = true
        failure = nil
        Task {
            do {
                try await model.pushModel.renumber(changes)
                reset()
                model.message = changes.count == 1 ? "Renumbered 1 reel. Relabel its box." : "Renumbered \(changes.count) reels. Relabel their boxes."
            } catch {
                failure = error.localizedDescription
            }
            isApplying = false
        }
    }
}
