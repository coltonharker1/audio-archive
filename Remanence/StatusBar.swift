import SwiftUI

/// The line along the foot of the window: which library this is, and what the screen
/// showing has to say.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let note = model.footerNote ?? model.pipelineSummary
        HStack(spacing: 9) {
            Circle()
                .fill(Theme.dotIdle)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(model.usesScratchLibrary ? "Scratch library" : "Local library")
                .fixedSize()
            Spacer(minLength: 16)
            Text(note)
                .lineLimit(1)
                .help(note)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 20)
        .frame(height: 31)
        .background(Theme.footer)
        .overlay(alignment: .top) { HairlineRule() }
    }
}
