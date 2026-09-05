import CryptoKit
import Foundation
import SwiftData

/// Disposable server metadata, isolated by account. Every context and model
/// stays on this actor; only value snapshots cross its boundary.
actor LibraryMetadataStore: MetadataPersistence {
    private let rootDirectory: URL
    private var container: ModelContainer?
    private var context: ModelContext?
    private var session: MetadataSession?
    private var syncToken: MetadataSyncToken?
    private var pendingWrites: [MetadataWrite] = []

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory,
                                                                       in: .userDomainMask)[0]
            .appendingPathComponent("app.hydrophone/Metadata", isDirectory: true)
    }

    func open(for credentials: ServerCredentials) async -> MetadataSession? {
        close()
        guard let scope = Self.scope(for: credentials) else { return nil }
        do {
            let directory = rootDirectory.appendingPathComponent(scope, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = Schema(versionedSchema: MetadataSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema,
                                                   url: directory.appendingPathComponent("metadata.store"),
                                                   cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: MetadataMigrationPlan.self,
                                               configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            self.container = container
            self.context = context
            let session = MetadataSession(scope: scope, generation: UUID())
            self.session = session
            return session
        } catch {
            close()
            return nil
        }
    }

    func close() {
        pendingWrites = []
        syncToken = nil
        session = nil
        context = nil
        container = nil
    }

    func read(for session: MetadataSession) async -> LibraryMetadataSnapshot? {
        guard self.session == session, let context else { return nil }
        do {
            let batch = try LibraryMetadataStoreBatch(context: context)
            let songs = try batch.songs.values.sorted { $0.id < $1.id }.map { try $0.value() }
            let albums = try batch.albums.values.sorted { $0.id < $1.id }.map { try $0.value() }
            let states = try context.fetch(FetchDescriptor<LibrarySyncState>())
            return LibraryMetadataSnapshot(
                artists: try batch.artists.values.sorted { $0.id < $1.id }.map { try $0.value() },
                albums: albums, songs: songs,
                genres: batch.genres.values.sorted { $0.name < $1.name }.map { $0.value() },
                playlists: try batch.playlists.values.sorted { $0.id < $1.id }.map { try $0.value() },
                favorites: states.contains { $0.collection == "favorites" }
                    ? MetadataFavorites(songs: songs.filter { $0.starred != nil },
                                        albums: albums.filter { $0.starred != nil }) : nil,
                lastSyncedAt: states.first { $0.collection == "library" }?.lastSyncedAt)
        } catch { return nil }
    }

    func write(_ change: MetadataWrite, for session: MetadataSession) async {
        guard self.session == session, let context else { return }
        do {
            try context.transaction {
                let batch = try LibraryMetadataStoreBatch(context: context)
                try batch.apply(change)
                batch.finalizeDeletions()
                try context.save()
            }
            if syncToken != nil { pendingWrites.append(change) }
        } catch { context.rollback() }
    }

    func beginSync(for session: MetadataSession) async -> MetadataSyncToken? {
        guard self.session == session, context != nil, syncToken == nil else { return nil }
        let token = MetadataSyncToken(session: session, generation: UUID())
        syncToken = token
        pendingWrites = []
        return token
    }

    func finishSync(_ snapshot: LibraryMetadataSnapshot, token: MetadataSyncToken) async -> Bool {
        guard session == token.session, syncToken == token, let context else { return false }
        defer {
            syncToken = nil
            pendingWrites = []
        }
        guard LibraryMetadataStoreBatch.hasCompleteGraph(snapshot) else { return false }
        do {
            try context.transaction {
                let batch = try LibraryMetadataStoreBatch(context: context)
                try batch.reconcile(snapshot)
                for change in pendingWrites { try batch.apply(change) }
                batch.finalizeDeletions()
                let states = try context.fetch(FetchDescriptor<LibrarySyncState>())
                let generation = (states.first { $0.collection == "library" }?.generation ?? 0) + 1
                try MetadataRecords.upsert(LibrarySyncSnapshot(collection: "library", generation: generation,
                                                               lastSyncedAt: Date()), in: context)
                try context.save()
            }
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    func cancelSync(_ token: MetadataSyncToken) async {
        guard syncToken == token else { return }
        syncToken = nil
        pendingWrites = []
    }

    private static func scope(for credentials: ServerCredentials) -> String? {
        guard var url = URLComponents(url: credentials.baseURL, resolvingAgainstBaseURL: true),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        url.scheme = scheme
        url.host = host
        url.user = nil
        url.password = nil
        url.query = nil
        url.fragment = nil
        if (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80) { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        guard let normalized = url.string else { return nil }
        let account = credentials.authMethod.rawValue + "\n" + credentials.username
            + (credentials.authMethod == .apiKey ? "\n" + hash(credentials.secret) : "")
        return hash(normalized) + "-" + hash(account)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
