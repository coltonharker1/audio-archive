import CryptoKit
import Foundation
@testable import RemanenceCore

/// Writes a small but real backup folder: playable WAV files, a manifest and
/// catalog pages in the same flight-chunk format as the live site.
struct BackupFixture {
    struct FixtureTrack {
        let title: String
        let audio: String
        var download: String?
    }

    let folder: URL
    let library: LibraryPaths

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        folder = root.appending(path: "backup", directoryHint: .isDirectory)
        library = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try library.createDirectories()
        try "entry\tfile\tbytes\tsha256\tlast_modified\n".write(
            to: folder.appending(path: "manifest.tsv"), atomically: true, encoding: .utf8
        )
    }

    /// Adds an entry. Each file's content varies by name, so hashes differ.
    func addEntry(_ entry: String, title: String, medium: String, tracks: [FixtureTrack]) throws {
        let directory = folder.appending(path: entry, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in tracks.flatMap({ [$0.audio, $0.download].compactMap(\.self) }) {
            try addAudio(name, to: entry)
        }
        try writePage(entry, title: title, medium: medium, tracks: tracks)
    }

    func addAudio(_ name: String, to entry: String) throws {
        let directory = folder.appending(path: entry, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Self.wav(seconds: 1, seed: name)
        try data.write(to: directory.appending(path: name))

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let line = "\(entry)\t\(name)\t\(data.count)\t\(hash)\tTue, 07 Apr 2026 23:23:57 GMT\n"
        let manifest = folder.appending(path: "manifest.tsv")
        let handle = try FileHandle(forWritingTo: manifest)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    func writePage(_ entry: String, title: String, medium: String, tracks: [FixtureTrack]) throws {
        let trackJSON = tracks.map { track -> String in
            var fields = [
                "\"title\":\(Self.quoted(track.title))",
                "\"audioUrl\":\"https://example.r2.dev/audio/\(track.audio)\"",
                "\"duration\":1",
            ]
            if let download = track.download {
                fields.append("\"downloadUrl\":\"https://example.r2.dev/audio/\(download)\"")
            }
            return "{" + fields.joined(separator: ",") + "}"
        }.joined(separator: ",")

        // The site stores long paragraphs as references to separate text rows. The
        // em dash makes the byte length differ from the character count.
        let longText = Self.longParagraph
        let data = """
            ["$","span",null,{"children":\(Self.quoted(medium))}],\
            [["$","span",null,{"className":"ra-dot"}],["$","span",null,{"children":"1968"}]],\
            ["$","div",null,{"className":"ra-detail-grid"}],\
            {"catalogNumber":"\(entry)","title":\(Self.quoted(title)),"tracks":[\(trackJSON)],"totalLength":"1:00"},\
            ["$","h2",null,{"children":"Description"}],\
            ["$","p","0",{"children":"First paragraph."}],\
            ["$","p","1",{"children":"Second \\"quoted\\" paragraph."}],\
            ["$","p","2",{"children":"$1a"}],\
            ["$","p","3",{"children":"$1b"}],\
            ["$","h2",null,{"children":"Provenance"}],\
            ["$","p","0",{"children":"Not part of the description."}]
            1a:T\(String(longText.utf8.count, radix: 16)),\(longText)1b:T\(String(Self.shortRef.utf8.count, radix: 16)),\(Self.shortRef)
            2c:["$","div",null,{}]
            """
        let middle = data.index(data.startIndex, offsetBy: data.count / 2)
        let html = "<html><script>self.__next_f.push([1,\(Self.quoted(String(data[..<middle])))])</script>"
            + "<script>self.__next_f.push([1,\(Self.quoted(String(data[middle...])))])</script></html>"

        let pages = folder.appending(path: "catalog-pages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try html.write(to: pages.appending(path: "\(entry).html"), atomically: true, encoding: .utf8)
    }

    func open() throws -> (AppDatabase, BackupImporter, Library) {
        let database = try AppDatabase.open(at: library.database)
        return (
            database,
            BackupImporter(database: database, paths: library),
            Library(database: database, paths: library)
        )
    }

    static let longParagraph = "A long paragraph — stored apart: 12:Tab, isn't a row here."
    static let shortRef = "Directly after another text row."

    private static func quoted(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }

    /// One channel of 16-bit, 8 kHz silence with a tone derived from the seed.
    static func wav(seconds: Int, seed: String) -> Data {
        let rate = 8000
        let frequency = 200 + Double(seed.utf8.reduce(0) { $0 &+ Int($1) } % 800)
        var samples = Data(capacity: rate * seconds * 2)
        for index in 0..<(rate * seconds) {
            let value = Int16(sin(Double(index) * 2 * .pi * frequency / Double(rate)) * 8000)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }

        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var file = Data("RIFF".utf8)
        file += little(UInt32(36 + samples.count))
        file += Data("WAVEfmt ".utf8)
        file += little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1))
        file += little(UInt32(rate)) + little(UInt32(rate * 2))
        file += little(UInt16(2)) + little(UInt16(16))
        file += Data("data".utf8) + little(UInt32(samples.count)) + samples
        return file
    }
}
