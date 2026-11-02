import AppKit
import RemanenceCore
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let’s get set up")
                        .font(.system(size: 38, weight: .regular, design: .serif))
                        .foregroundStyle(Theme.ink)
                    Text("Remanence needs a few tools to listen to your tapes.")
                        .foregroundStyle(Theme.inkMuted)
                }

                VStack(spacing: 0) {
                    ForEach(model.requirements) { requirement in
                        RequirementRow(requirement: requirement)
                        if requirement.id != model.requirements.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Theme.card, in: .rect(cornerRadius: 10))

                HStack {
                    Spacer()
                    Button("Check Again") { Task { await model.refresh() } }
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct RequirementRow: View {
    @Environment(AppModel.self) private var model
    let requirement: Requirement

    private var state: RequirementState? { model.states[requirement.id] }
    private var progress: Double? { model.downloads[requirement.id] }

    var body: some View {
        HStack(spacing: 12) {
            statusIcon.frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.name)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(detailIsProblem ? Theme.attention : Theme.inkMuted)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusIcon: some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.good)
                .accessibilityLabel("Ready")
        case .none:
            ProgressView().controlSize(.small)
        default:
            Image(systemName: requirement.isOptional ? "circle.dashed" : "exclamationmark.circle.fill")
                .foregroundStyle(requirement.isOptional ? Theme.inkMuted : Theme.attention)
                .accessibilityLabel(requirement.isOptional ? "Optional, not installed" : "Needs attention")
        }
    }

    private var detail: String {
        if let error = model.downloadErrors[requirement.id] { return error }
        switch state {
        case .failed(let message): return message
        case .incomplete: return "The download didn’t finish. Download it again."
        case .missing where requirement.isOptional: return "\(requirement.purpose). Optional."
        default: return requirement.purpose
        }
    }

    private var detailIsProblem: Bool {
        if model.downloadErrors[requirement.id] != nil { return true }
        switch state {
        case .failed, .incomplete: return true
        default: return false
        }
    }

    @ViewBuilder private var action: some View {
        if state == .ready || state == nil {
            EmptyView()
        } else {
            switch requirement.kind {
            case .model:
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 120)
                        .accessibilityLabel("Downloading")
                } else {
                    Button("Download") { Task { await model.download(requirement) } }
                }
            case .tool(_, let installCommand):
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                }
                .help(installCommand)
            }
        }
    }
}
