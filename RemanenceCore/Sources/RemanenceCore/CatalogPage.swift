import Foundation

/// A catalog entry read from a page saved from the Remanence site.
///
/// The site's pages embed their data as Next.js flight chunks. Only the title and
/// tracks are required, because without them the audio can't be matched up.
public struct CatalogPage: Equatable, Sendable {
    public struct Track: Decodable, Equatable, Sendable {
        public let title: String
        public let audioUrl: String
        public let downloadUrl: String?

        var audioFile: String { Self.fileName(audioUrl) }
        /// The separate master, if there is one. Some tracks list the same file
        /// for both streaming and download, as with RA-006.
        var downloadFile: String? {
            guard let name = downloadUrl.map(Self.fileName), name != audioFile else { return nil }
            return name
        }

        private static func fileName(_ url: String) -> String {
            url.split(separator: "/").last.map(String.init) ?? url
        }
    }

    public let catalogNumber: String
    public let title: String
    public let medium: String?
    public let era: String?
    public let description: String
    public let tracks: [Track]

    public enum ParseError: LocalizedError, Equatable {
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let what): "The catalog page has no \(what)."
            }
        }
    }

    public init(html: String) throws {
        let data = try Self.flightData(in: html)

        guard let numberKey = data.range(of: #""catalogNumber":"#) else {
            throw ParseError.missing("catalog number")
        }
        let afterNumber = data[numberKey.upperBound...]
        guard let number = Self.leadingJSON(in: afterNumber, as: String.self) else {
            throw ParseError.missing("catalog number")
        }
        catalogNumber = number

        guard let titleKey = afterNumber.range(of: #""title":"#),
              let title = Self.leadingJSON(in: afterNumber[titleKey.upperBound...], as: String.self) else {
            throw ParseError.missing("title")
        }
        self.title = title

        guard let tracksKey = afterNumber.range(of: #""tracks":"#),
              let tracks = Self.leadingJSON(in: afterNumber[tracksKey.upperBound...], as: [Track].self),
              !tracks.isEmpty else {
            throw ParseError.missing("tracks")
        }
        self.tracks = tracks

        let header = data.range(of: "ra-detail-grid").map { String(data[..<$0.lowerBound]) } ?? data
        medium = Self.firstMatch(of: #"\d+\\" Reel-to-Reel|Microcassette|Cassette"#, in: header)
            .map { $0.replacingOccurrences(of: "\\\"", with: "\"") }
        era = Self.firstCapture(
            of: #""ra-dot"\}\],\["\$","span",null,\{"children":"([^"]+)"\}\]"#,
            in: header
        )
        description = Self.descriptionParagraphs(in: data).joined(separator: "\n\n")
    }

    /// Joins the page's flight chunks into one decoded string.
    private static func flightData(in html: String) throws -> String {
        let pattern = try NSRegularExpression(
            pattern: #"self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)"#,
            options: [.dotMatchesLineSeparators]
        )
        var joined = ""
        let range = NSRange(html.startIndex..., in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let literal = Range(match.range(at: 1), in: html),
                  let chunk = try? JSONDecoder().decode(String.self, from: Data(html[literal].utf8)) else { continue }
            joined += chunk
        }
        return joined
    }

    /// Decodes the JSON value at the very start of the text, ignoring what follows.
    private static func leadingJSON<T: Decodable>(in text: Substring, as type: T.Type) -> T? {
        var depth = 0
        var inString = false
        var escaped = false
        var end: Substring.Index?

        scan: for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    if depth == 0 {
                        end = text.index(after: index)
                        break scan
                    }
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth == 0 {
                    end = text.index(after: index)
                    break scan
                }
            default: break
            }
        }

        guard let end else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text[..<end].utf8))
    }

    private static func descriptionParagraphs(in data: String) -> [String] {
        guard let start = data.range(of: #""children":"Description""#) else { return [] }
        var section = data[start.upperBound...]
        if let end = section.range(of: #""children":"Provenance""#) {
            section = section[..<end.lowerBound]
        }
        guard let pattern = try? NSRegularExpression(
            pattern: #"\["\$","p","\d+",\{"children":("(?:[^"\\]|\\.)*")\}\]"#
        ) else { return [] }

        let references = textReferences(in: data)
        let text = String(section)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let literal = Range(match.range(at: 1), in: text),
                  let value = try? JSONDecoder().decode(String.self, from: Data(text[literal].utf8)) else { return nil }
            guard value.hasPrefix("$") else { return value }
            if value.hasPrefix("$$") { return String(value.dropFirst()) }
            return references[String(value.dropFirst())]
        }
    }

    /// Long strings aren't inline in flight data. A paragraph holds a reference
    /// like `$13`, and the text sits elsewhere as `13:T<hex byte length>,<text>`.
    private static func textReferences(in data: String) -> [String: String] {
        guard let pattern = try? NSRegularExpression(pattern: #"(?:^|\n)?([0-9a-f]+):T([0-9a-f]+),"#) else {
            return [:]
        }
        var references: [String: String] = [:]
        var position = data.startIndex

        while position < data.endIndex,
              let match = pattern.firstMatch(in: data, range: NSRange(position..., in: data)),
              let whole = Range(match.range, in: data),
              let id = Range(match.range(at: 1), in: data),
              let hex = Range(match.range(at: 2), in: data),
              let length = Int(data[hex], radix: 16) {
            // Skip text that only looks like a reference, in the middle of a word.
            let startsRow = whole.lowerBound == position
                || data[whole.lowerBound] == "\n"
                || data[data.index(before: whole.lowerBound)] == "\n"
            guard startsRow,
                  let end = data.utf8.index(whole.upperBound, offsetBy: length, limitedBy: data.endIndex) else {
                position = whole.upperBound
                continue
            }
            references[String(data[id])] = String(data[whole.upperBound..<end])
            position = end
        }
        return references
    }

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
