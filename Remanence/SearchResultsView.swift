import RemanenceCore
import SwiftUI

/// Every tape and moment matching the search. Choosing a moment plays it.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    /// The width of the detail area, which sets sizes.
    @State private var width: CGFloat = 680

    private var size: LayoutSize { LayoutSize(detailWidth: width) }
    private var results: [SearchTapeResult] { model.searchResults }
    private var momentCount: Int { results.reduce(0) { $0 + $1.moments.count } }

    private var summary: String {
        let tapes = results.count == 1 ? "1 tape" : "\(results.count) tapes"
        let moments = momentCount == 1 ? "1 moment" : "\(momentCount) moments"
        return "\(moments) on \(tapes)"
    }

    /// Nothing is said until a first search has an answer.
    private var subtitle: String? {
        guard !model.isSearching || !results.isEmpty else { return nil }
        return results.isEmpty ? "Nothing matches “\(model.searchText)”." : summary
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                PageHeader(eyebrow: "Library", title: "Search", subtitle: subtitle, size: size)

                ForEach(results) { result in
                    TapeResult(result: result, size: size)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct TapeResult: View {
    @Environment(AppModel.self) private var model

    let result: SearchTapeResult
    let size: LayoutSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.openResult(result, moment: nil)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(Theme.serif(size.rowName))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    CapLabel(meta)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(result.title)
            .accessibilityValue(meta)

            ForEach(result.moments) { moment in
                Button {
                    model.openResult(result, moment: moment)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label(TimeLabel.clock(moment.time), systemImage: "play.fill")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.rust)
                            .frame(width: 80, alignment: .trailing)
                        Text(highlighted(moment.snippet))
                            .font(Theme.serif(15))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(highlighted(moment.snippet)))
                .accessibilityHint("Plays from \(TimeLabel.clock(moment.time))")
            }
        }
    }

    private var meta: String {
        var parts = [result.catalogNumber, result.medium?.uppercased()].compactMap(\.self)
        if result.moments.isEmpty {
            parts.append("IN ITS DETAILS")
        } else {
            parts.append(result.moments.count == 1 ? "1 MOMENT" : "\(result.moments.count) MOMENTS")
        }
        return parts.joined(separator: " · ")
    }

    /// Turns the search's highlight markers into visible emphasis.
    private func highlighted(_ snippet: String) -> AttributedString {
        var output = AttributedString()
        var isMatch = false
        var remainder = Substring(snippet)
        while !remainder.isEmpty {
            let marker = isMatch ? SearchHighlight.end : SearchHighlight.start
            if let range = remainder.range(of: marker) {
                output += piece(remainder[..<range.lowerBound], isMatch: isMatch)
                remainder = remainder[range.upperBound...]
                isMatch.toggle()
            } else {
                output += piece(remainder, isMatch: isMatch)
                break
            }
        }
        return output
    }

    private func piece(_ text: Substring, isMatch: Bool) -> AttributedString {
        var piece = AttributedString(String(text))
        if isMatch {
            piece.backgroundColor = Theme.highlight
        }
        return piece
    }
}
