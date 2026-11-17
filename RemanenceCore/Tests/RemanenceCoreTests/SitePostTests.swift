import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RemanenceCore

@Suite struct SitePostTests {
    let library: Library
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-post-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try paths.createDirectories()
        library = Library(database: try AppDatabase.open(at: paths.database), paths: paths)
    }

    private func addTape(medium: String? = "Cassette") async throws -> (tapeID: Int64, sourceID: Int64) {
        try await library.database.writer.write { db in
            var tape = Tape(uuid: UUID().uuidString, title: "Box 4", medium: medium, approvedAt: Date(), createdAt: Date())
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, side: "A", masterPath: "masters/x/side-a.wav", duration: 60)
            try source.insert(db)
            return (tape.id!, source.id!)
        }
    }

    private func post(_ tapeID: Int64) async throws -> SitePost {
        try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID)! }
    }

    /// A small photo, optionally with a location, like one from a phone.
    private func photo(_ type: UTType, withLocation: Bool = true) throws -> URL {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let image = context.makeImage()!
        let url = root.appending(path: "photo-\(UUID().uuidString).\(type.preferredFilenameExtension!)")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if withLocation {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 35.1495, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 90.0490, kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func hasLocation(_ url: URL) -> Bool {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyGPSDictionary] != nil
    }

    private func type(of url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    // MARK: Fields

    @Test func postFieldsSaveAndClear() async throws {
        let tape = try await addTape()
        var fields = PostFields(tape: try await post(tape.tapeID).tape)
        fields.title = "  Estate Sale Reel "
        fields.description = "First paragraph.\n\n[photo 1]\n\nSecond."
        fields.medium = .reel7
        fields.recordedDate = "c. 1972–1975"
        fields.whereFound = "Estate sale, Memphis TN"
        fields.dateFound = "2024-03-15"
        try await library.savePost(tapeID: tape.tapeID, fields: fields)

        var saved = try await post(tape.tapeID).tape
        #expect(saved.title == "Estate Sale Reel")
        #expect(saved.description == "First paragraph.\n\n[photo 1]\n\nSecond.")
        #expect(saved.medium == "7\" Reel-to-Reel")
        #expect(saved.era == "c. 1972–1975")
        #expect(saved.whereFound == "Estate sale, Memphis TN")
        #expect(saved.dateFound == "2024-03-15")
        #expect(PostFields(tape: saved) == PostFields(tape: saved))

        fields.description = "   "
        fields.whereFound = ""
        fields.title = ""
        try await library.savePost(tapeID: tape.tapeID, fields: fields)
        saved = try await post(tape.tapeID).tape
        #expect(saved.description == nil)
        #expect(saved.whereFound == nil)
        #expect(saved.title == "Estate Sale Reel", "a title can't be blank, so it's kept")
    }

    @Test func editingTheTitleMakesItPermanent() async throws {
        let tape = try await addTape()
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE tape SET title_is_provisional = 1 WHERE id = ?", arguments: [tape.tapeID])
        }
        var fields = PostFields(tape: try await post(tape.tapeID).tape)
        fields.title = "Mine"
        try await library.savePost(tapeID: tape.tapeID, fields: fields)
        #expect(try await post(tape.tapeID).tape.titleIsProvisional == false)
    }

    @Test func mediaMatchTheSitesList() {
        #expect(SiteMedium.allCases.count == 12)
        for medium in SiteMedium.allCases {
            #expect(SiteMedium(label: medium.label) == medium)
        }
        // The names the app already uses for its machines.
        #expect(SiteMedium(label: "7\" Reel-to-Reel") == .reel7)
        #expect(SiteMedium(label: "Microcassette") == .microcassette)
        #expect(SiteMedium(label: "Cassette") == .cassette)
        #expect(SiteMedium(label: "Wax cylinder") == nil)
    }

    // MARK: Tracks

    @Test func tracksTakeWrittenTextSeparateFromTheSummary() async throws {
        let tape = try await addTape()
        try await library.database.writer.write { db in
            var track = Track(sourceId: tape.sourceID, name: "Side A")
            track.summaryShort = "Short."
            track.summary = #"{"summary_short":"Short.","summary_long":"Claude's long summary."}"#
            try track.insert(db)
        }
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, description: "My own words.")

        let track = try #require(try await post(tape.tapeID).tracks.first)
        #expect(track.description == "My own words.")
        #expect(track.summaryLong == "Claude's long summary.")
        #expect(track.name == "Side A")
    }

    @Test func aTrackWithoutARowGetsOne() async throws {
        let tape = try await addTape()
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, name: "Opening", description: "Words.")
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, name: "Opening Hymn")

        let track = try #require(try await post(tape.tapeID).tracks.first)
        #expect(track.name == "Opening Hymn")
        #expect(track.description == "Words.", "changing the name leaves the description alone")
        let rows = try await library.database.writer.read { try Track.fetchCount($0) }
        #expect(rows == 1)
    }

    @Test func markerTracksTakeTextToo() async throws {
        let tape = try await addTape()
        let marker = try await library.addMarker(sourceID: tape.sourceID, time: 20)
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: marker, description: "Second part.")

        let tracks = try await post(tape.tapeID).tracks
        #expect(tracks.count == 2)
        #expect(tracks[0].description == nil)
        #expect(tracks[1].description == "Second part.")
    }

    @Test func theSummaryReferenceCoversEveryTrack() async throws {
        let tape = try await addTape()
        let marker = try await library.addMarker(sourceID: tape.sourceID, time: 20, trackName: "Hymn")
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, name: "")
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE track SET summary = ?, summary_short = 'A sermon.' WHERE start_marker_id IS NULL",
                           arguments: [#"{"summary_short":"A sermon.","summary_long":"Long sermon."}"#])
            try db.execute(sql: "UPDATE track SET summary = ?, summary_short = 'A hymn.' WHERE start_marker_id = ?",
                           arguments: [#"{"summary_short":"A hymn.","summary_long":"Long hymn."}"#, marker])
        }
        let reference = try await post(tape.tapeID).summaryReference
        #expect(reference == "Track 1: A sermon.\n\nHymn: A hymn.")
    }

    // MARK: Photos

    @Test func jpegPhotosLoseTheirLocationButNotTheirPicture() async throws {
        let tape = try await addTape()
        let original = try photo(.jpeg)
        #expect(hasLocation(original))

        let image = try await library.addImage(tapeID: tape.tapeID, from: original)

        let stored = try library.url(forLibraryPath: image.path)
        #expect(!hasLocation(stored))
        #expect(type(of: stored) == UTType.jpeg.identifier)
        #expect(image.filename.hasSuffix(".jpg"))
        #expect(image.sha256 == (try sha256(of: stored)))
    }

    @Test func heicPhotosBecomeJPEGWithoutLocation() async throws {
        let tape = try await addTape()
        let original = try photo(.heic)

        let image = try await library.addImage(tapeID: tape.tapeID, from: original)

        let stored = try library.url(forLibraryPath: image.path)
        #expect(type(of: stored) == UTType.jpeg.identifier)
        #expect(!hasLocation(stored))
        #expect(image.filename.hasSuffix(".jpg"))
    }

    @Test func pngPhotosStayPNG() async throws {
        let tape = try await addTape()
        let image = try await library.addImage(tapeID: tape.tapeID, from: try photo(.png, withLocation: false))
        #expect(type(of: try library.url(forLibraryPath: image.path)) == UTType.png.identifier)
    }

    @Test func theSamePhotoIsOnlyAddedOnce() async throws {
        let tape = try await addTape()
        let original = try photo(.jpeg)
        try await library.addImage(tapeID: tape.tapeID, from: original)
        await #expect(throws: ImageImportError.alreadyAdded(original.lastPathComponent)) {
            try await library.addImage(tapeID: tape.tapeID, from: original)
        }
        #expect(try await post(tape.tapeID).images.count == 1)
    }

    @Test func nonImagesAreRefused() async throws {
        let tape = try await addTape()
        let text = root.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: ImageImportError.unreadable("notes.txt")) {
            try await library.addImage(tapeID: tape.tapeID, from: text)
        }
    }

    @Test func photosCanBeOrderedCaptionedAndRemoved() async throws {
        let tape = try await addTape()
        let first = try await library.addImage(tapeID: tape.tapeID, from: try photo(.jpeg))
        let second = try await library.addImage(tapeID: tape.tapeID, from: try photo(.png, withLocation: false))
        let third = try await library.addImage(tapeID: tape.tapeID, from: try photo(.heic))

        try await library.moveImage(id: third.id!, by: -1)
        try await library.setCaption(imageID: first.id!, caption: "  The box  ")
        #expect(try await post(tape.tapeID).images.map(\.id) == [first.id, third.id, second.id])
        #expect(try await post(tape.tapeID).images.first?.caption == "The box")

        try await library.moveImage(id: first.id!, by: -1)
        #expect(try await post(tape.tapeID).images.map(\.id) == [first.id, third.id, second.id], "can't move past the start")

        try await library.removeImage(id: first.id!)
        let images = try await post(tape.tapeID).images
        #expect(images.map(\.id) == [third.id, second.id])
        #expect(images.map(\.position) == [0, 1])
        #expect(!FileManager.default.fileExists(atPath: try library.url(forLibraryPath: first.path).path))
    }

    @Test func deletingATapeTrashesItsPhotos() async throws {
        let tape = try await addTape()
        let image = try await library.addImage(tapeID: tape.tapeID, from: try photo(.jpeg))
        let stored = try library.url(forLibraryPath: image.path)
        try await library.delete(tapeID: tape.tapeID, trash: { try FileManager.default.removeItem(at: $0) })

        #expect(!FileManager.default.fileExists(atPath: stored.path))
        #expect(try await library.database.writer.read { try TapeImage.fetchCount($0) } == 0)
    }
}
