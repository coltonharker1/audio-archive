import AppKit
import RemanenceCore
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model
    /// The width of the area it fills, which sets sizes.
    @State private var width: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    eyebrow: "Setup",
                    title: "Let’s get set up",
                    subtitle: "Remanence needs a few tools to listen to your tapes.",
                    size: LayoutSize(detailWidth: width)
                )

                VStack(spacing: 0) {
                    ForEach(model.requirements) { requirement in
                        RequirementRow(requirement: requirement)
                        if requirement.id != model.requirements.last?.id {
                            HairlineRule()
                                .padding(.horizontal, 14)
                        }
                    }
                }
                .background(Theme.inset, in: .rect(cornerRadius: 4))

                HStack {
                    Spacer()
                    Button("Check Again") { Task { await model.refresh() } }
                        .buttonStyle(.paperStandard)
                        .accessibilityLabel("Check Again")
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
                    .font(Theme.serif(16))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(detailIsProblem ? Theme.attention : Theme.muted)
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
                .foregroundStyle(requirement.isOptional ? Theme.muted : Theme.attention)
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
                        .tint(Theme.rust)
                        .frame(width: 120)
                        .accessibilityLabel("Downloading")
                } else {
                    Button("Download") { Task { await model.download(requirement) } }
                        .buttonStyle(.paperSmall)
                        .accessibilityLabel("Download")
                }
            case .tool(_, let installCommand):
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                }
                .buttonStyle(.paperSmall)
                .accessibilityLabel("Copy Install Command")
                .help(installCommand)
            }
        }
    }
}
