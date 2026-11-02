import Foundation

/// Where Remanence keeps its files.
///
/// The library holds irreplaceable audio, so it lives somewhere easy to find and
/// back up. Models can be downloaded again, so they stay in Application Support.
public struct LibraryPaths: Sendable {
    public let library: URL
    public let support: URL

    public init(library: URL, support: URL) {
        self.library = library
        self.support = support
    }

    public static var standard: LibraryPaths {
        let fileManager = FileManager.default
        return LibraryPaths(
            library: fileManager.homeDirectoryForCurrentUser
                .appending(path: "Music/Remanence", directoryHint: .isDirectory),
            support: URL.applicationSupportDirectory
                .appending(path: "Remanence", directoryHint: .isDirectory)
        )
    }

    public var database: URL { library.appending(path: "library.sqlite") }
    public var masters: URL { library.appending(path: "masters", directoryHint: .isDirectory) }
    public var processed: URL { library.appending(path: "processed", directoryHint: .isDirectory) }
    public var peaks: URL { library.appending(path: "peaks", directoryHint: .isDirectory) }
    public var models: URL { support.appending(path: "models", directoryHint: .isDirectory) }

    public func createDirectories() throws {
        for directory in [masters, processed, peaks, models] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
