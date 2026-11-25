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
