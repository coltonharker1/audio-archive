import RemanenceCore
import SwiftUI

/// The selected tape's details and playback, along the bottom of the shelf.
struct TapePanel: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: SideAction?
    @State private var renaming: SideAction?
    @State private var newSideName = ""

    var body: some View {
        if let tape = model.selectedTape {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    details(for: tape)
                    activity(for: tape)
                    TransportBar()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if tape.items.count > 1 {
                    trackList(for: tape)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Theme.card)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.board).frame(height: 1)
            }
        }
    }

    private func details(for tape: ShelfTape) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tape.tape.title)
                .font(Theme.display(24))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(meta(for: tape))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
            if let collection = model.collection(of: tape) {
                Button {
                    model.sidebarSelection = .collection(collection.id)
                } label: {
                    Label("Part of \(collection.collection.name)", systemImage: "shippingbox")
                        .font(.system(size: 12))
                }
                .buttonStyle(.link)
                .help("Open the collection")
            }
            if let description = tape.tape.description {
                Text(description)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
                    .padding(.top, 2)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Read Along", systemImage: "text.alignleft") {
                    model.openReadAlong(tape)
                }
                Button("Review", systemImage: "waveform") {
                    model.openReview(tape)
                }
                Button("Edit", systemImage: "slider.horizontal.3") {
                    model.openEdit(tape)
                }
                Button("Site Post", systemImage: "doc.richtext") {
                    model.openPost(tape)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func activity(for tape: ShelfTape) -> some View {
        if case .failed(let reason) = tape.status {
            HStack(spacing: 10) {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button("Try Again") { Task { await model.retry(tape) } }
            }
        } else if let text = model.activityText(for: tape) {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.accent)
        }
    }

    private func meta(for tape: ShelfTape) -> String {
        var parts = [tape.tape.catalogNumber, tape.tape.medium?.uppercased()].compactMap(\.self)
        if tape.trackCount > 1 { parts.append("\(tape.trackCount) TRACKS") }
        parts.append(TimeLabel.clock(tape.duration))
        if let era = tape.tape.era { parts.append(era.uppercased()) }
        return parts.joined(separator: " · ")
    }

    private func trackList(for tape: ShelfTape) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(tape.items.enumerated()), id: \.element.id) { index, item in
                    let isCurrent = index == model.selectedItemIndex
                    Button {
                        model.play(itemAt: index)
                    } label: {
                        HStack {
                            Text(item.name)
                                .lineLimit(1)
                                .fontWeight(isCurrent ? .semibold : .regular)
                            Spacer(minLength: 8)
                            Text(TimeLabel.clock(item.source.duration))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                        .background(isCurrent ? Theme.board.opacity(0.45) : .clear, in: .rect(cornerRadius: 5))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    .contextMenu {
                        if tape.tape.pushedAt == nil {
                            Button("Rename Side…") {
                                newSideName = item.source.side ?? ""
                                renaming = SideAction(tape: tape, item: item)
                            }
                            Button("Delete Side…", role: .destructive) {
                                deleting = SideAction(tape: tape, item: item)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 280, height: 132)
        .confirmationDialog(
            deleting.map { "Delete \($0.item.name)?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { action in
            Button("Delete", role: .destructive) {
                Task { await model.removeSide(action.item, of: action.tape) }
            }
        } message: { action in
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

/// A side waiting for a name or for confirmation.
private struct SideAction {
    let tape: ShelfTape
    let item: ShelfTape.Item
}

/// Play, pause and scrub. Shared by the shelf panel and the read-along screen.
struct TransportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 44, height: 44)
                    .background(Theme.ink, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(model.player.failure != nil)
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")

            if let failure = model.player.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
            } else {
                Text(TimeLabel.clock(model.player.currentTime))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { model.player.currentTime },
                        set: { model.player.scrub(to: $0) }
                    ),
                    in: 0...max(model.player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            Task { await model.player.seek(to: model.player.currentTime) }
                        }
                    }
                )
                .tint(Theme.accent)
                .accessibilityLabel("Playback position")
                .accessibilityValue(TimeLabel.clock(model.player.currentTime))

                Text(TimeLabel.clock(model.player.duration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(minWidth: 48, alignment: .leading)
            }
        }
    }
}
