import RemanenceCore
import SwiftUI

/// Every tape and moment matching the search. Choosing a moment plays it.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    private var results: [SearchTapeResult] { model.searchResults }
    private var momentCount: Int { results.reduce(0) { $0 + $1.moments.count } }

    private var summary: String {
        let tapes = results.count == 1 ? "1 tape" : "\(results.count) tapes"
        let moments = momentCount == 1 ? "1 moment" : "\(momentCount) moments"
        return "\(moments) on \(tapes)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search")
                        .font(Theme.display(44))
                        .foregroundStyle(Theme.ink)
                    if !model.isSearching || !results.isEmpty {
                        Text(results.isEmpty ? "Nothing matches “\(model.searchText)”." : summary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }

                ForEach(results) { result in
                    TapeResult(result: result)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
    }
}

private struct TapeResult: View {
    @Environment(AppModel.self) private var model

    let result: SearchTapeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.openResult(result, moment: nil)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(Theme.display(23))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    Text(meta)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.inkMuted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            ForEach(result.moments) { moment in
                Button {
                    model.openResult(result, moment: moment)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label(TimeLabel.clock(moment.time), systemImage: "play.fill")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 80, alignment: .trailing)
                        Text(highlighted(moment.snippet))
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
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
            piece.backgroundColor = Color(red: 0.902, green: 0.812, blue: 0.624)
        }
        return piece
    }
}
