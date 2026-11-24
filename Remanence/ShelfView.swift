import RemanenceCore
import SwiftUI

struct ShelfView: View {
    @Environment(AppModel.self) private var model

    private var tapes: [ShelfTape] { model.visibleTapes }

    /// Large reels get their own shelf, as they would in a real room.
    private var largeTapes: [ShelfTape] {
        tapes.filter { TapeFormat(medium: $0.tape.medium) == .sevenInchReel }
    }

    private var smallTapes: [ShelfTape] {
        tapes.filter { TapeFormat(medium: $0.tape.medium) != .sevenInchReel }
    }

    private var summary: String {
        let duration = tapes.reduce(0) { $0 + $1.duration }
        let count = tapes.count == 1 ? "1 tape" : "\(tapes.count) tapes"
        return "\(count) · \(TimeLabel.long(duration))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Shelf")
                        .font(Theme.display(44))
                        .foregroundStyle(Theme.ink)
                    Text(summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.inkMuted)
                }
                .padding(.horizontal, 32)

                ShelfTabs()
                    .padding(.horizontal, 32)

                if tapes.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 32)
                }
                if !largeTapes.isEmpty {
                    WrappingShelves(tapes: largeTapes, objectHeight: 196, columnWidth: 196)
                }
                if !smallTapes.isEmpty {
                    WrappingShelves(tapes: smallTapes, objectHeight: 136, columnWidth: 164)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
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

/// Fills as many shelves as the window needs, so no tape is ever out of sight.
private struct WrappingShelves: View {
    let tapes: [ShelfTape]
    let objectHeight: CGFloat
    let columnWidth: CGFloat

    @State private var width: CGFloat = 800

    private let spacing: CGFloat = 30
    private let margin: CGFloat = 32
    /// Room above the tapes so a lifted one isn't clipped.
    private let headroom: CGFloat = 14

    private var rows: [[ShelfTape]] {
        let perRow = max(1, Int((width - margin * 2 + spacing) / (columnWidth + spacing)))
        return stride(from: 0, to: tapes.count, by: perRow).map {
            Array(tapes[$0..<min($0 + perRow, tapes.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(rows, id: \.first?.id) { row in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Theme.board)
                        .frame(height: 10)
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 4)
                        .offset(y: headroom + objectHeight)

                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(row) { tape in
                            TapeColumn(tape: tape, objectHeight: objectHeight, width: columnWidth, headroom: headroom)
                        }
                    }
                    .padding(.horizontal, margin)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct TapeColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var confirmingDelete = false
    @State private var namingCollection = false
    @State private var newCollectionName = ""

    let tape: ShelfTape
    let objectHeight: CGFloat
    let width: CGFloat
    let headroom: CGFloat

    private var isSelected: Bool { model.selectedTapeID == tape.id }
    private var isLifted: Bool { isSelected || isHovering }

    private var caption: String {
        if let activity = model.activityText(for: tape) { return activity }
        let place = tape.tape.pushedAt == nil ? "Ready to review" : "On the site"
        return "\(place) · \(TimeLabel.clock(tape.duration))"
    }

    private var captionColor: Color {
        switch tape.status {
        case .failed: Theme.attention
        case .working: Theme.accent
        case .idle, .waiting: Theme.inkMuted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.select(tape)
            } label: {
                TapeObject(tape: tape)
                    .shadow(
                        color: .black.opacity(isSelected ? 0.34 : 0.24),
                        radius: isSelected ? 11 : 4,
                        y: isSelected ? 10 : 3
                    )
                    .offset(y: isLifted && !reduceMotion ? -7 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: width, height: objectHeight + headroom, alignment: .bottomLeading)
            .accessibilityLabel(tape.tape.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { isHovering = hovering }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: isSelected)
            .draggable(TapeDrag.payload(tape.id)) {
                TapeObject(tape: tape).scaleEffect(0.6)
            }
            .contextMenu {
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

            Text(tape.tape.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .padding(.top, 22)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(captionColor)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(width: width, alignment: .leading)
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
