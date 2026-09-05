import Foundation

/// Generic "cached value + credentials guard + generation counter + in-flight
/// task coalescing" primitive — the shape `SubsonicClient.cachedAllSongs` and
/// `NavidromeClient.cachedSongIndex` used to hand-roll independently. See
/// docs/05-data-and-caching.md's "Design decision (#140)" (140.2) for which
/// caches adopt this and which stay bespoke.
actor CredentialScopedCache<Value: Sendable> {
    private var cached: (value: Value, credentials: ServerCredentials)?
    private var inFlight: (task: Task<(Value, Bool), Error>, credentials: ServerCredentials)?
    private var generation = 0

    /// `build` returns `(value, cacheable)`: a build that reached a genuinely
    /// authoritative result caches it; a fallback/partial result can be
    /// returned to the caller without being cached, so a future call retries
    /// the real fetch instead of being stuck on the fallback (mirrors
    /// `SubsonicClient.AllSongsOutcome.isComplete`'s existing contract).
    func resolve(
        using creds: ServerCredentials,
        build: @Sendable @escaping () async throws -> (Value, Bool)
    ) async throws -> Value {
        if let cached, cached.credentials == creds { return cached.value }
        if let inFlight, inFlight.credentials == creds {
            return try await inFlight.task.value.0
        }

        generation += 1
        let generation = self.generation
        let task = Task<(Value, Bool), Error> { try await build() }
        inFlight = (task, creds)

        do {
            let (value, cacheable) = try await task.value
            if self.generation == generation {
                if cacheable { cached = (value, creds) }
                inFlight = nil
            }
            return value
        } catch {
            if self.generation == generation {
                inFlight = nil
            }
            throw error
        }
    }

    /// Convenience for the common case: every build that succeeds is cached.
    func resolve(
        using creds: ServerCredentials,
        build: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        try await resolve(using: creds) { (try await build(), true) }
    }

    /// Read-only lookup for callers that need a validity check beyond
    /// "credentials match" before deciding to reuse the cached value (e.g. a
    /// token's own expiry) — doesn't participate in in-flight coalescing.
    func peek(matching creds: ServerCredentials) -> Value? {
        guard let cached, cached.credentials == creds else { return nil }
        return cached.value
    }

    /// Directly seeds the cache with an already-fetched value, for callers
    /// that perform their own unconditional fetch (bypassing `resolve`'s
    /// reuse-if-cached behavior — e.g. a "force a fresh login" entry point)
    /// but still want the result available to later `resolve`/`peek` callers.
    func store(_ value: Value, for creds: ServerCredentials) {
        generation += 1
        cached = (value, creds)
        inFlight = nil
    }

    /// Retires both the cached value and any in-flight build. An
    /// already-awaiting caller may still receive its result, but a stale
    /// completion can't repopulate the cache because its generation no
    /// longer matches.
    func invalidate() {
        generation += 1
        cached = nil
        inFlight = nil
    }
}
