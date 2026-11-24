import Foundation
import Security

/// What a push asks of the site. Tests stand in for it, so nothing reaches the real site.
public protocol SiteAPI: Sendable {
    /// Which of these files the site already has.
    func existingFiles(_ hashes: [String]) async throws -> Set<String>
    func requestUpload(_ file: PushFile) async throws -> SiteUpload
    func upload(_ file: PushFile, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func recordFile(_ file: PushFile, key: String) async throws
    /// Creates the unpublished entry. A tape that's already on the site gets its
    /// existing entry back, unchanged.
    func createEntry(_ entry: SiteEntry) async throws -> SitePostState
    func fetchEntry(tapeUUID: String, catalogNumber: String?) async throws -> SitePostState
    /// Changes only what's sent. Throws `SiteError.changedOnSite` if the post changed
    /// on the site since `expectedUpdatedAt`.
    func updateEntry(_ update: SiteUpdate) async throws -> SitePostState
    /// Every post on the site, briefly.
    func listEntries() async throws -> [SiteEntrySummary]
    /// Removes a post. Throws `SiteError.changedOnSite` if it changed since `expectedUpdatedAt`.
    func deleteEntry(tapeUUID: String, catalogNumber: String?, expectedUpdatedAt: String) async throws
    func fetchCollection(uuid: String) async throws -> SiteCollectionState
    /// Creates or updates a collection, whole. Throws `SiteError.changedOnSite` if it
    /// changed since `expectedUpdatedAt`, or exists when that's nil.
    func saveCollection(_ push: SiteCollectionPush) async throws -> SiteCollectionState
    func deleteCollection(uuid: String, expectedUpdatedAt: String) async throws
    /// Moves posts to new numbers, all at once. Throws `SiteError.changedOnSite` if any
    /// changed since it was last read.
    func renumber(_ changes: [SiteRenumber]) async throws -> [SitePostState]
}

public struct SiteUpload: Equatable, Sendable {
    public let url: URL
    public let key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }
}

public struct SiteEntry: Encodable, Equatable, Sendable {
    public struct Track: Encodable, Equatable, Sendable {
        public let title: String
        public let audioSha256: String
        public let audioFilename: String
        public let downloadSha256: String
        public let downloadFilename: String
        public let duration: Double
        public let description: String?
    }

    public struct Image: Encodable, Equatable, Sendable {
        public let sha256: String
        public let filename: String
        public let caption: String?
    }

    public let tapeUuid: String
    public let title: String
    public let medium: String
    public let description: String?
    public let estimatedRecordingDate: String?
    public var whereFound: String? = nil
    public var dateFound: String? = nil
    public let tracks: [Track]
    public var images: [Image] = []
    public let transcriptSha256: String?
    public let metadata: [String: String]
    /// The number the tape was given here. The site keeps it, or refuses if it's taken.
    public var catalogNumber: String? = nil
}

public enum SiteError: LocalizedError, Equatable {
    case rejectedKey
    case notConfigured
    case changedOnSite
    case server(status: Int, message: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .rejectedKey: "The site didn’t accept the API key."
        case .notConfigured: "The site has no SYNC_API_KEY set, so it can’t accept pushes yet."
        case .changedOnSite: "This post changed on the site since the app last read it. Refresh from the site, then make the change again."
        case .server(let status, let message): "The site answered \(status): \(message)"
        case .unexpectedResponse: "The site sent back something unexpected."
        }
    }

    /// Whether trying again could help.
    var isTemporary: Bool {
        if case .server(let status, _) = self { return status >= 500 && status != 501 }
        return false
    }
}

/// Talks to the site's sync API. Audio goes straight to storage through presigned URLs.
public struct SiteClient: SiteAPI {
    public static let defaultURL = URL(string: "https://www.remanencearchive.com")!

    let baseURL: URL
    let apiKey: String
    let session: URLSession

    public init(baseURL: URL = SiteClient.defaultURL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func existingFiles(_ hashes: [String]) async throws -> Set<String> {
        struct Body: Encodable { let hashes: [String] }
        struct Reply: Decodable {
            struct File: Decodable {}
            let files: [String: File]
        }
        let reply: Reply = try await post("api/sync/check", Body(hashes: hashes))
        return Set(reply.files.keys)
    }

    public func requestUpload(_ file: PushFile) async throws -> SiteUpload {
        struct Item: Encodable {
            let sha256: String
            let filename: String
            let contentType: String
            let type: String
        }
        struct Body: Encodable { let files: [Item] }
        struct Reply: Decodable {
            struct File: Decodable {
                let uploadUrl: URL
                let key: String
            }
            let files: [File]
        }
        let item = Item(sha256: file.sha256, filename: file.filename, contentType: file.contentType, type: file.kind.rawValue)
        let reply: Reply = try await post("api/sync/upload", Body(files: [item]))
        guard let first = reply.files.first else { throw SiteError.unexpectedResponse }
        return SiteUpload(url: first.uploadUrl, key: first.key)
    }

    public func upload(_ file: PushFile, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        // The presigned URL was signed with this type, so it has to match exactly.
        request.setValue(file.contentType, forHTTPHeaderField: "Content-Type")
        // The API key stays out of this request, because it goes to storage.
        let (data, response) = try await session.upload(
            for: request,
            fromFile: file.url,
            delegate: UploadProgress(report: progress)
        )
        try Self.check(response, data: data)
    }

    public func recordFile(_ file: PushFile, key: String) async throws {
        struct Body: Encodable {
            let sha256: String
            let key: String
            let bytes: Int64
        }
        struct Reply: Decodable {}
        let _: Reply = try await post("api/sync/files", Body(sha256: file.sha256, key: key, bytes: file.bytes))
    }

    public func createEntry(_ entry: SiteEntry) async throws -> SitePostState {
        try await post("api/sync", entry)
    }

    public func fetchEntry(tapeUUID: String, catalogNumber: String?) async throws -> SitePostState {
        var components = URLComponents(url: baseURL.appending(path: "api/sync/entry"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "tapeUuid", value: tapeUUID)]
            + (catalogNumber.map { [URLQueryItem(name: "catalogNumber", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        do {
            return try JSONDecoder().decode(SitePostState.self, from: data)
        } catch {
            throw SiteError.unexpectedResponse
        }
    }

    public func updateEntry(_ update: SiteUpdate) async throws -> SitePostState {
        do {
            return try await post("api/sync/update", update)
        } catch SiteError.server(409, let message) where message.contains("changed on the site") {
            throw SiteError.changedOnSite
        }
    }

    public func listEntries() async throws -> [SiteEntrySummary] {
        struct Reply: Decodable { let entries: [SiteEntrySummary] }
        var request = URLRequest(url: baseURL.appending(path: "api/sync/entries"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        do {
            return try JSONDecoder().decode(Reply.self, from: data).entries
        } catch {
            throw SiteError.unexpectedResponse
        }
    }

    public func deleteEntry(tapeUUID: String, catalogNumber: String?, expectedUpdatedAt: String) async throws {
        struct Body: Encodable {
            let tapeUuid: String
            let catalogNumber: String?
            let expectedUpdatedAt: String
        }
        struct Reply: Decodable { let deleted: String }
        do {
            let _: Reply = try await post("api/sync/delete", Body(tapeUuid: tapeUUID, catalogNumber: catalogNumber, expectedUpdatedAt: expectedUpdatedAt))
        } catch SiteError.server(409, let message) where message.contains("changed on the site") {
            throw SiteError.changedOnSite
        }
    }

    public func fetchCollection(uuid: String) async throws -> SiteCollectionState {
        var components = URLComponents(url: baseURL.appending(path: "api/sync/collection"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uuid", value: uuid)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        do {
            return try JSONDecoder().decode(SiteCollectionState.self, from: data)
        } catch {
            throw SiteError.unexpectedResponse
        }
    }

    public func saveCollection(_ push: SiteCollectionPush) async throws -> SiteCollectionState {
        do {
            return try await post("api/sync/collection", push)
        } catch SiteError.server(409, let message) where message.contains("changed on the site") {
            throw SiteError.changedOnSite
        }
    }

    public func renumber(_ changes: [SiteRenumber]) async throws -> [SitePostState] {
        struct Body: Encodable { let changes: [SiteRenumber] }
        struct Reply: Decodable { let entries: [SitePostState] }
        do {
            let reply: Reply = try await post("api/sync/renumber", Body(changes: changes))
            return reply.entries
        } catch SiteError.server(409, let message) where message.contains("changed on the site") {
            throw SiteError.changedOnSite
        }
    }

    public func deleteCollection(uuid: String, expectedUpdatedAt: String) async throws {
        struct Body: Encodable {
            let uuid: String
            let expectedUpdatedAt: String
        }
        struct Reply: Decodable { let deleted: String }
        do {
            let _: Reply = try await post("api/sync/collection/delete", Body(uuid: uuid, expectedUpdatedAt: expectedUpdatedAt))
        } catch SiteError.server(409, let message) where message.contains("changed on the site") {
            throw SiteError.changedOnSite
        }
    }

    private func post<Body: Encodable, Reply: Decodable>(_ path: String, _ body: Body) async throws -> Reply {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw SiteError.unexpectedResponse
        }
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SiteError.unexpectedResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw SiteError.rejectedKey
        case 501: throw SiteError.notConfigured
        default:
            struct Failure: Decodable { let error: String }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw SiteError.server(status: http.statusCode, message: failure.error)
            }
            // A web page instead of an answer: the site doesn't have this route.
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            let isPage = text.range(of: "<!doctype html", options: .caseInsensitive) != nil || text.hasPrefix("<html")
            throw SiteError.server(
                status: http.statusCode,
                message: isPage
                    ? (http.statusCode == 404 ? "The site doesn’t know this request yet. It may need to be updated." : "The site sent back a web page instead of an answer.")
                    : text
            )
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// The site's API key, kept in the Keychain rather than in a file or the database.
public enum SiteCredentials {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.colton.remanence.site",
            kSecAttrAccount as String: "sync-api-key",
        ]
    }

    public static func load() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
