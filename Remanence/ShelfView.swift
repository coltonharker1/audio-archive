import RemanenceCore
import SwiftUI

/// The whole library as a list, under tabs that narrow it.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    /// The width of the detail area, which sets sizes and column widths.
    @State private var width: CGFloat = 680

    private var tapes: [ShelfTape] { model.visibleTapes }
    private var size: LayoutSize { LayoutSize(detailWidth: width) }

    /// The mocks' padding follows the window's width, which is wider than this
    /// screen by the sidebar.
    private var padding: CGFloat { LayoutSize.pagePadding(windowWidth: width + 220) }

    private var subtitle: String {
        let count = model.shelf.count
        return "\(count) \(count == 1 ? "reel" : "reels") in your library"
    }

    /// Background work, said in the footer: the one tape being worked on, or a
    /// summary when there are several.
    private var footerNote: String {
        let working = model.workingTapes
        guard let tape = working.first else { return "" }
        guard working.count == 1, let activity = model.activityText(for: tape) else { return model.pipelineSummary }
        return "Background activity · \(activity) \(tape.tape.catalogNumber ?? tape.tape.title)"
    }

    var body: some View {
        let columns = ShelfColumns(size)
        let last = model.resumable
        // Under the hero, the compact window gives up some space to keep the rows.
        let isTight = last != nil && size == .compact
        VStack(alignment: .leading, spacing: 0) {
            // The header and the column names stay put while the rows scroll.
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "Library", title: "Shelf", subtitle: subtitle, size: size) {
                    Button("Import audio…") { model.chooseAudioToImport() }
                        .buttonStyle(.paperStandard)
                    Button {
                        model.openRecording()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .accessibilityHidden(true)
                            Text("Record a tape")
                        }
                    }
                    .buttonStyle(.paperPrimary)
                }
                .padding(.bottom, isTight ? 10 : 14)

                if let last {
                    LastOpened(resumable: last, size: size)
                        .padding(.bottom, isTight ? 6 : 28)
                }

                ShelfTabs()
                    .padding(.bottom, 8)

                if !tapes.isEmpty {
                    ShelfColumnNames(columns: columns)
                }
            }
            .padding(.horizontal, padding)
            .padding(.top, isTight ? 12 : 18)

            if tapes.isEmpty {
                Text("Nothing here yet.")
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, padding)
                    .padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                // The hero's row is marked only while no other row is picked, so one
                // row at a time looks selected.
                let pickedElsewhere = tapes.contains { $0.id == model.selectedTapeID && $0.id != last?.tape.id }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tapes) { tape in
                            ShelfRow(
                                tape: tape,
                                columns: columns,
                                size: size,
                                isLastOpened: tape.id == last?.tape.id && !pickedElsewhere,
                                verticalPadding: isTight ? 10 : 11
                            )
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.bottom, 24)
                }
                // Each tab starts at its top.
                .id(model.filter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: footerNote, initial: true) { _, note in model.footerNote = note }
    }
}

/// The last tape worked on, with a way back to where it was left.
private struct LastOpened: View {
    @Environment(AppModel.self) private var model

    let resumable: WorkPosition.Resolved
    let size: LayoutSize

    private var tape: ShelfTape { resumable.tape }

    /// One scale for every format, so each keeps its size beside the others. The
    /// largest box, at 196 points, just fits.
    private var pictureScale: CGFloat { min(1, (size.heroHeight - 16) / 196) }

    private var eyebrow: String {
        ["Last opened", tape.tape.catalogNumber].compactMap(\.self).joined(separator: "  /  ")
    }

    /// Medium and length. The collection, if any, comes first as a link.
    private var details: String {
        let medium = tape.tape.medium.map { SiteMedium(rawValue: $0)?.label ?? $0 }
        return [medium, TimeLabel.clock(tape.duration)]
            .compactMap(\.self)
            .joined(separator: "  ·  ")
    }

    /// The collection opens from here, as it does from the tape's row.
    private var subtitle: some View {
        HStack(spacing: 0) {
            if let collection = model.collection(of: tape) {
                Button {
                    model.sidebarSelection = .collection(collection.id)
                } label: {
                    Text(collection.collection.name)
                        .lineLimit(1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open \(collection.collection.name)")
                Text("  ·  ")
                    .fixedSize()
            }
            Text(details)
                .lineLimit(1)
                .fixedSize()
                .help(details)
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.muted)
    }

    var body: some View {
        HStack(spacing: 0) {
            TapeObject(tape: tape)
                .scaleEffect(pictureScale)
                .frame(width: size == .regular ? 300 : 180, height: size.heroHeight)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                EyebrowLabel(eyebrow)
                Text(tape.tape.title)
                    .font(Theme.serif(size.heroTitle))
                    .foregroundStyle(Theme.ink)
                    // Two lines as in the mock, then cut. The compact hero is only 150
                    // tall, so its title sits a little closer to its neighbours.
                    .lineLimit(2)
                    .help(tape.tape.title)
                    .padding(.vertical, size == .regular ? 7 : 3)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
                subtitle
                HStack(spacing: 12) {
                    Button("\(resumable.buttonTitle)  →") { model.resume() }
                        .buttonStyle(.paperPrimary)
                        .accessibilityLabel(resumable.buttonTitle)
                    Text("at \(TimeLabel.clock(resumable.position.playhead))")
                        .font(Theme.mono())
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
                .padding(.top, size == .regular ? 17 : 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, size == .regular ? 25 : 12)
        .frame(height: size.heroHeight)
        .background(Theme.hero, in: .rect(cornerRadius: 3))
    }
}

/// The table's fixed column widths. The reel's title takes what's left.
private struct ShelfColumns {
    let number: CGFloat = 58
    let collection: CGFloat
    let length: CGFloat = 56
    let status: CGFloat
    let spacing: CGFloat = 10
    /// Space inside each row, at both ends.
    let inset: CGFloat = 10

    init(_ size: LayoutSize) {
        collection = size == .regular ? 220 : 104
        // Wide enough for the longest activity, "Reading the waveform…".
        status = size == .regular ? 170 : 156
    }
}

private struct ShelfColumnNames: View {
    let columns: ShelfColumns

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: columns.spacing) {
                CapLabel("Number")
                    .frame(width: columns.number, alignment: .leading)
                CapLabel("Reel")
                    .frame(maxWidth: .infinity, alignment: .leading)
                CapLabel("Collection")
                    .frame(width: columns.collection, alignment: .leading)
                CapLabel("Length")
                    .frame(width: columns.length, alignment: .leading)
                CapLabel("Status")
                    .frame(width: columns.status, alignment: .leading)
            }
            .padding(.horizontal, columns.inset)
            .padding(.vertical, 9)
            HairlineRule()
        }
        // The rows are read out by what they hold.
        .accessibilityHidden(true)
    }
}

/// The shelf's four filters, each with how many tapes it shows.
private struct ShelfTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(ShelfFilter.allCases) { filter in
                    tab(filter)
                }
                Spacer(minLength: 0)
            }
            HairlineRule()
        }
    }

    private func tab(_ filter: ShelfFilter) -> some View {
        let isSelected = model.filter == filter
        let count = model.shelf.filter(filter.includes).count
        return Button {
            model.filter = filter
        } label: {
            HStack(spacing: 7) {
                Text(filter.label)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(Theme.ink)
            .fixedSize()
            .padding(.top, 9)
            .padding(.bottom, 11)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(Theme.ink).frame(height: 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One tape on the shelf. A click picks it, so Space plays it. A double-click,
/// Return or a click on its title opens it.
private struct ShelfRow: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false
    @State private var namingCollection = false
    @State private var newCollectionName = ""

    let tape: ShelfTape
    let columns: ShelfColumns
    let size: LayoutSize
    /// The tape the hero shows, whose row is marked too while no other row is picked.
    let isLastOpened: Bool
    let verticalPadding: CGFloat

    private var isSelected: Bool { model.selectedTapeID == tape.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: columns.spacing) {
                Text(tape.tape.catalogNumber ?? "—")
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .help(tape.tape.catalogNumber ?? "No number")
                    .frame(width: columns.number, alignment: .leading)
                    .accessibilityLabel(tape.tape.catalogNumber ?? "No number")

                VStack(alignment: .leading, spacing: 4) {
                    title
                    failure
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                collection
                    .frame(width: columns.collection, alignment: .leading)

                Text(TimeLabel.clock(tape.duration))
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .frame(width: columns.length, alignment: .leading)

                status
            }
            .padding(.horizontal, columns.inset)
            .padding(.vertical, verticalPadding)
            HairlineRule()
        }
        .background(isSelected || isLastOpened ? Theme.picked : .clear)
        .contentShape(.rect)
        .draggable(TapeDrag.payload(tape.id)) {
            TapeObject(tape: tape).scaleEffect(0.6)
        }
        .onTapGesture { model.select(tape) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openReview(tape) })
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Select") { model.select(tape) }
        .alert("New Collection", isPresented: $namingCollection) {
            TextField("The Cable Man", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName
                Task { await model.createCollection(named: name, with: [tape]) }
            }
            .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(tape.tape.title)” goes in it. Add more reels by dragging them onto it in the sidebar.")
        }
        .confirmationDialog(
            "Move “\(tape.tape.title)” to the Trash?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await model.delete(tape) } }
        } message: {
            Text("Its audio can be restored from the Trash. Its details in Remanence are removed, and this doesn’t change the site.")
        }
    }

    private var title: some View {
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
        .help(tape.tape.title)
    }

    /// Why processing stopped, and a way to start it again.
    @ViewBuilder private var failure: some View {
        if case .failed(let reason) = tape.status {
            HStack(spacing: 8) {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.attention)
                    .lineLimit(1)
                    .help(reason)
                Button("Try Again") { Task { await model.retry(tape) } }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var collection: some View {
        if let collection = model.collection(of: tape) {
            Button {
                model.sidebarSelection = .collection(collection.id)
            } label: {
                Text(collection.collection.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open \(collection.collection.name)")
        } else {
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    private var status: some View {
        let status = model.status(of: tape)
        let text = status.label ?? model.activityText(for: tape) ?? ""
        return StatusBadge(text: text, tone: tone(of: status))
            // A badge keeps its full width, so a long one is cut at the column's edge.
            .frame(width: columns.status, alignment: .leading)
            .clipped()
            .help(text)
    }

    private func tone(of status: ShelfStatus) -> StatusBadge.Tone {
        switch status {
        case .published: .published
        case .draftOnSite, .onSiteUnread: .draft
        case .recording, .working, .failed: .working
        case .waiting, .approved, .readyToReview: .idle
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { model.openReview(tape) }
        Menu("Collection") {
            ForEach(model.collections) { collection in
                Toggle(collection.collection.name, isOn: Binding(
                    get: { tape.tape.collectionId == collection.id },
                    set: { isOn in
                        let id = isOn ? collection.id : nil
                        Task { await model.setCollection(tape, to: id) }
                    }
                ))
            }
            if !model.collections.isEmpty { Divider() }
            Button("New Collection…") {
                newCollectionName = ""
                namingCollection = true
            }
            if tape.tape.collectionId != nil {
                Button("Remove from Collection") { Task { await model.setCollection(tape, to: nil) } }
            }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { confirmingDelete = true }
    }
}

/// A tape drawn at a size that follows its real format.
struct TapeObject: View {
    let tape: ShelfTape

    private static let colors: [(box: Color, label: Color)] = [
        (Color(red: 0.847, green: 0.800, blue: 0.690), Theme.ink),
        (Color(red: 0.184, green: 0.290, blue: 0.271), Color(red: 0.937, green: 0.906, blue: 0.831)),
        (Color(red: 0.725, green: 0.522, blue: 0.247), Theme.ink),
        (Color(red: 0.478, green: 0.231, blue: 0.165), Color(red: 0.953, green: 0.914, blue: 0.839)),
        (Color(red: 0.557, green: 0.420, blue: 0.341), Color(red: 0.984, green: 0.961, blue: 0.914)),
        (Color(red: 0.216, green: 0.255, blue: 0.310), Theme.paper),
        (Color(red: 0.420, green: 0.455, blue: 0.376), Color(red: 0.984, green: 0.969, blue: 0.925)),
    ]

    private var colors: (box: Color, label: Color) {
        let number = tape.tape.catalogNumber
            .flatMap { Int($0.drop { !$0.isNumber }) }
            ?? tape.tape.uuid.utf8.reduce(0) { $0 + Int($1) }
        return Self.colors[number % Self.colors.count]
    }

    var body: some View {
        switch TapeFormat(medium: tape.tape.medium) {
        case .sevenInchReel: reelBox(size: 196, titleSize: 24, padding: 12)
        case .fiveInchReel, .unknown: reelBox(size: 136, titleSize: 19, padding: 10)
        case .cassette: cassette(width: 150, height: 96)
        case .microcassette: cassette(width: 122, height: 80)
        }
    }

    private var label: String {
        tape.tape.catalogNumber ?? "NEW"
    }

    private func reelBox(size: CGFloat, titleSize: CGFloat, padding: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            colors.box

            ReelRings()
                .stroke(colors.label.opacity(0.22), lineWidth: 1.2)
                .frame(width: size * 0.88, height: size * 0.88)
                .offset(x: size * 0.36, y: size * 0.36)

            VStack(alignment: .leading, spacing: size * 0.07) {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                Text(tape.tape.title)
                    .font(Theme.display(titleSize))
                    .lineSpacing(-2)
                    .minimumScaleFactor(0.7)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(colors.label)
            .padding(padding)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 3))
    }

    private func cassette(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: height * 0.1) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color(red: 0.91, green: 0.875, blue: 0.784), in: .rect(cornerRadius: 2))

            HStack(spacing: width * 0.17) {
                CassetteHub()
                CassetteHub()
            }
            .frame(height: height * 0.32)
        }
        .padding(8)
        .frame(width: width, height: height, alignment: .top)
        .background(Color(red: 0.149, green: 0.133, blue: 0.11), in: .rect(cornerRadius: 5))
    }
}

private struct ReelRings: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for scale in [1.0, 0.68, 0.18] {
            let inset = rect.width * (1 - scale) / 2
            path.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
        }
        return path
    }
}

private struct CassetteHub: View {
    var body: some View {
        ZStack {
            Circle().stroke(Theme.paper, lineWidth: 1.3)
            Circle().stroke(Theme.paper, lineWidth: 1.3).padding(6)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
