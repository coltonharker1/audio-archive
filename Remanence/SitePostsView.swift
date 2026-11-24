import RemanenceCore
import SwiftUI

/// Every post on the site, with the ones not in this library ready to bring in.
struct SitePostsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var push: PushModel { model.pushModel }
    private var listing: [SiteListing] { push.siteListing ?? [] }
    private var missing: [SiteListing] { listing.filter { !$0.isInLibrary } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Site Posts")
                        .font(Theme.display(24))
                        .foregroundStyle(Theme.ink)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(2)
                }
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") { Task { await push.loadListing() } }
                    .labelStyle(.iconOnly)
                    .disabled(push.isListing)
                    .help("Read the site’s posts again")
            }
            .padding(20)

            if let failure = push.importFailure {
                Text(failure)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(3)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            if let failure = push.listingFailure, push.siteListing == nil {
                Text(failure)
                    .foregroundStyle(Theme.attention)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if push.siteListing == nil {
                ProgressView("Reading the site…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(listing) { item in
                    row(item)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Bringing a post in downloads its original audio and photos, so it can be edited here.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 600, height: 520)
        .background(Theme.paper)
        .task { await push.loadListing() }
    }

    private var summary: String {
        guard push.siteListing != nil else { return "Every post on remanencearchive.com." }
        let count = listing.count
        let posts = count == 1 ? "1 post" : "\(count) posts"
        return missing.isEmpty
            ? "\(posts), all in your library."
            : "\(posts). \(missing.count) \(missing.count == 1 ? "isn’t" : "aren’t") in your library yet."
    }

    private func row(_ item: SiteListing) -> some View {
        HStack(spacing: 12) {
            Text(item.entry.catalogNumber)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.title)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .help(item.entry.title)
                Text(details(item.entry))
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            action(item)
        }
        .padding(.vertical, 4)
    }

    private func details(_ entry: SiteEntrySummary) -> String {
        var parts = [entry.published ? "Published" : "Not published"]
        parts.append(entry.trackCount == 1 ? "1 track" : "\(entry.trackCount) tracks")
        if entry.duration > 0 { parts.append(TimeLabel.clock(entry.duration)) }
        if entry.imageCount > 0 { parts.append(entry.imageCount == 1 ? "1 photo" : "\(entry.imageCount) photos") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func action(_ item: SiteListing) -> some View {
        if let tapeID = item.tapeID {
            Button("Open") {
                if let tape = model.shelf.first(where: { $0.id == tapeID }) {
                    dismiss()
                    model.openPost(tape)
                }
            }
            .fixedSize()
        } else if push.importingNumber == item.entry.catalogNumber {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(push.importProgress.map { "Track \(min($0.done + 1, $0.total)) of \($0.total)" } ?? "Starting…")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .monospacedDigit()
            }
            .fixedSize()
        } else {
            Button("Bring In", systemImage: "arrow.down.circle") { push.importEntry(item) }
                .disabled(push.isPushing || model.recordModel.isRecording || item.entry.trackCount == 0)
                .fixedSize()
                .help(item.entry.trackCount == 0 ? "This post has no audio" : "Download this post into your library")
        }
    }
}
