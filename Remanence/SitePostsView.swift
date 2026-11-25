import RemanenceCore
import SwiftUI

/// Every post on the site, with the ones not in this library ready to bring in.
struct SitePostsView: View {
    @Environment(AppModel.self) private var model
    /// The width of the detail area, which sets sizes.
    @State private var width: CGFloat = 680

    private var push: PushModel { model.pushModel }
    private var listing: [SiteListing] { push.siteListing ?? [] }
    private var missing: [SiteListing] { listing.filter { !$0.isInLibrary } }

    private var size: LayoutSize { LayoutSize(detailWidth: width) }

    /// The mocks' padding follows the window's width, which is wider than this
    /// screen by the sidebar.
    private var padding: CGFloat { LayoutSize.pagePadding(windowWidth: width + 220) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header and the column names stay put while the rows scroll.
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "Library", title: "Site Posts", subtitle: summary, size: size) {
                    Button("Reload") { Task { await push.loadListing() } }
                        .buttonStyle(.paperStandard)
                        .disabled(push.isListing)
                        .help("Read the site’s posts again")
                }
                .padding(.bottom, 20)

                if let failure = push.importFailure {
                    Text(failure)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.attention)
                        .lineLimit(3)
                        .help(failure)
                        .textSelection(.enabled)
                        .padding(.bottom, 10)
                }

                if push.siteListing != nil {
                    SitePostColumnNames()
                }
            }
            .padding(.horizontal, padding)
            .padding(.top, 22)

            if let failure = push.listingFailure, push.siteListing == nil {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.attention)
                    .textSelection(.enabled)
                    .padding(.horizontal, padding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if push.siteListing == nil {
                ProgressView("Reading the site…")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(listing) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.bottom, 16)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HairlineRule()
                Text("Bringing a post in downloads its original audio and photos, so it can be edited here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .padding(.vertical, 14)
            }
            .padding(.horizontal, padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
        VStack(spacing: 0) {
            HStack(spacing: SitePostColumns.spacing) {
                Text(item.entry.catalogNumber)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .help(item.entry.catalogNumber)
                    .frame(width: SitePostColumns.number, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.entry.title)
                        .font(Theme.serif(size.rowName))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .help(item.entry.title)
                    Text(details(item))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .help(details(item))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                status(item)
                    .frame(width: SitePostColumns.status, alignment: .leading)

                action(item)
                    .frame(width: SitePostColumns.action, alignment: .trailing)
            }
            .padding(.horizontal, SitePostColumns.inset)
            .padding(.vertical, 11)
            HairlineRule()
        }
        .accessibilityElement(children: .contain)
    }

    /// A post that's only on the site says so in place of its state, so the state
    /// moves to the line under its title.
    private func details(_ item: SiteListing) -> String {
        let entry = item.entry
        var parts: [String] = []
        if !item.isInLibrary { parts.append(presence(entry).label) }
        parts.append(entry.trackCount == 1 ? "1 track" : "\(entry.trackCount) tracks")
        if entry.duration > 0 { parts.append(TimeLabel.clock(entry.duration)) }
        if entry.imageCount > 0 { parts.append(entry.imageCount == 1 ? "1 photo" : "\(entry.imageCount) photos") }
        return parts.joined(separator: " · ")
    }

    private func presence(_ entry: SiteEntrySummary) -> SitePresence {
        entry.published ? .published : .draftOnSite
    }

    @ViewBuilder private func status(_ item: SiteListing) -> some View {
        if item.isInLibrary {
            StatusBadge(text: presence(item.entry).label, tone: item.entry.published ? .published : .draft)
        } else {
            Text("Site only")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .fixedSize()
        }
    }

    @ViewBuilder private func action(_ item: SiteListing) -> some View {
        if let tapeID = item.tapeID {
            Button("Open") {
                if let tape = model.shelf.first(where: { $0.id == tapeID }) {
                    model.openPost(tape)
                }
            }
            .buttonStyle(.paperSmall)
            .accessibilityLabel("Open \(item.entry.catalogNumber)")
        } else if push.importingNumber == item.entry.catalogNumber {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(push.importProgress.map { "Track \(min($0.done + 1, $0.total)) of \($0.total)" } ?? "Starting…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            .fixedSize()
        } else {
            Button("Bring In") { push.importEntry(item) }
                .buttonStyle(.paperSmall)
                .disabled(push.isPushing || model.recordModel.isRecording || item.entry.trackCount == 0)
                .help(item.entry.trackCount == 0 ? "This post has no audio" : "Download this post into your library")
                .accessibilityLabel("Bring in \(item.entry.catalogNumber)")
        }
    }
}

/// The table's fixed column widths. The post's title takes what's left.
private enum SitePostColumns {
    static let number: CGFloat = 58
    static let status: CGFloat = 108
    /// Wide enough for "Track 12 of 15" beside its spinner.
    static let action: CGFloat = 120
    static let spacing: CGFloat = 10
    /// Space inside each row, at both ends.
    static let inset: CGFloat = 10
}

private struct SitePostColumnNames: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SitePostColumns.spacing) {
                CapLabel("Number")
                    .frame(width: SitePostColumns.number, alignment: .leading)
                CapLabel("Title")
                    .frame(maxWidth: .infinity, alignment: .leading)
                CapLabel("Status")
                    .frame(width: SitePostColumns.status, alignment: .leading)
                Color.clear
                    .frame(width: SitePostColumns.action, height: 1)
            }
            .padding(.horizontal, SitePostColumns.inset)
            .padding(.vertical, 9)
            HairlineRule()
        }
        // The rows are read out by what they hold.
        .accessibilityHidden(true)
    }
}
