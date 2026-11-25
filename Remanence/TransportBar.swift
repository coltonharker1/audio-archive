import RemanenceCore
import SwiftUI

/// Play, pause and scrub, on the read-along screen.
struct TransportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 34, height: 34)
                    .background(Theme.primary, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(model.player.failure != nil)
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")

            if let failure = model.player.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(2)
                    .help(failure)
                Spacer(minLength: 0)
            } else {
                Text(TimeLabel.clock(model.player.currentTime))
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
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
                    .font(Theme.mono())
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                    .frame(minWidth: 48, alignment: .leading)
            }
        }
    }
}
