import Foundation
import Testing
@testable import Hydrophone

/// Hermetic, endpoint-agnostic coverage for `CredentialScopedCache` itself
/// (#140/#141): the credentials-guard + generation-counter +
/// in-flight-coalescing + explicit-invalidate shape that `LibrarySongIndex`'s
/// two walks and `NavidromeClient`'s token cache both build on. A trivial
/// mock `build` closure stands in for any real fetch.
@Suite(.serialized)
struct CredentialScopedCacheTests {
    private func creds(host: String = "https://music.example.com") -> ServerCredentials {
        ServerCredentials(baseURL: URL(string: host)!, username: "tim", secret: "sesame", authMethod: .tokenSalt)
    }

    private actor CallCounter {
        private(set) var count = 0
        func increment() -> Int {
            count += 1
            return count
        }
    }

    @Test func repeatedCallsWithMatchingCredentialsReuseTheCachedValue() async throws {
        let cache = CredentialScopedCache<Int>()
        let counter = CallCounter()
        let creds = creds()

        let first = try await cache.resolve(using: creds) { await counter.increment() }
        let second = try await cache.resolve(using: creds) { await counter.increment() }

        #expect(first == 1)
        #expect(second == 1) // served from cache, build not called again
        #expect(await counter.count == 1)
    }

    @Test func mismatchedCredentialsRebuildRatherThanReuse() async throws {
        let cache = CredentialScopedCache<Int>()
        let counter = CallCounter()

        let first = try await cache.resolve(using: creds(host: "https://old.example.com")) {
            await counter.increment()
        }
        let second = try await cache.resolve(using: creds(host: "https://new.example.com")) {
            await counter.increment()
        }

        #expect(first == 1)
        #expect(second == 2)
        #expect(await counter.count == 2)
    }

    @Test func concurrentCallsWithMatchingCredentialsCoalesceOntoOneBuild() async throws {
        let cache = CredentialScopedCache<Int>()
        let counter = CallCounter()
        let gate = Gate()
        let creds = creds()

        async let first = cache.resolve(using: creds) {
            await gate.wait()
            return await counter.increment()
        }
        async let second = cache.resolve(using: creds) {
            await gate.wait()
            return await counter.increment()
        }
        // Only the caller that actually starts the build reaches the gate;
        // a coalescing second caller awaits that same task without ever
        // invoking its own closure. Wait for the one build to arrive, then
        // release it.
        while await gate.waiterCount < 1 { await Task.yield() }
        await gate.open()

        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult == secondResult)
        #expect(await counter.count == 1) // one build served both callers
    }

    @Test func invalidateForcesTheNextCallToRebuild() async throws {
        let cache = CredentialScopedCache<Int>()
        let counter = CallCounter()
        let creds = creds()

        _ = try await cache.resolve(using: creds) { await counter.increment() }
        await cache.invalidate()
        _ = try await cache.resolve(using: creds) { await counter.increment() }

        #expect(await counter.count == 2)
    }

    /// Mirrors `SubsonicAllSongsTests.invalidatedInFlightWalkCannotRepopulateTheCache`:
    /// actor reentrancy means `invalidate()` can run while a build is still
    /// awaiting its (gated, in this test) result. That build's eventual
    /// completion must not resurrect the cache it was told to drop.
    @Test func invalidationDuringInFlightBuildIsNotClobberedByItsCompletion() async throws {
        let cache = CredentialScopedCache<Int>()
        let counter = CallCounter()
        let gate = Gate()
        let creds = creds()

        let stale = Task {
            try await cache.resolve(using: creds) {
                await gate.wait()
                return await counter.increment()
            }
        }
        while (await gate.waiterCount) < 1 { await Task.yield() }
        await cache.invalidate() // runs while `stale`'s build is still awaiting the gate
        await gate.open()
        _ = try await stale.value

        let next = try await cache.resolve(using: creds) { await counter.increment() }
        #expect(next == 2) // a genuine rebuild, not the retired build's cached result
        #expect(await counter.count == 2)
    }

    /// A build that reaches completion after being superseded by *another*
    /// build for the same credentials (not just an explicit `invalidate()`)
    /// must not be allowed to overwrite the newer one's result — the same
    /// generation guard `credentialChangeDuringBuildCannotLetOldCompletionOverwriteNewCache`
    /// exercises for the real song-index cache.
    @Test func supersededBuildCannotOverwriteANewerCompletion() async throws {
        let cache = CredentialScopedCache<Int>()
        let oldGate = Gate()
        let newGate = Gate()
        let creds = creds()

        async let oldBuild: Int = cache.resolve(using: creds) {
            await oldGate.wait()
            return 1
        }
        while (await oldGate.waiterCount) < 1 { await Task.yield() }
        await cache.invalidate()

        async let newBuild: Int = cache.resolve(using: creds) {
            await newGate.wait()
            return 2
        }
        while (await newGate.waiterCount) < 1 { await Task.yield() }
        await newGate.open()
        #expect(try await newBuild == 2)
        await oldGate.open()
        #expect(try await oldBuild == 1) // the caller still gets its own result…

        let cached = try await cache.resolve(using: creds) { 3 }
        #expect(cached == 2) // …but the cache reflects the newer build, not the stale one
    }

    @Test func uncacheableResultIsReturnedButNotCached() async throws {
        let cache = CredentialScopedCache<Int>()
        let counter = CallCounter()
        let creds = creds()

        let fallback = try await cache.resolve(using: creds) { () async throws -> (Int, Bool) in
            (await counter.increment(), false)
        }
        #expect(fallback == 1)

        // Not cached, so the next call rebuilds rather than reusing it.
        let next = try await cache.resolve(using: creds) { () async throws -> (Int, Bool) in
            (await counter.increment(), true)
        }
        #expect(next == 2)
        #expect(await counter.count == 2)
    }
}

/// Lets a test hold a build closure open until it explicitly releases it —
/// same shape as `NavidromeClientNetworkTests`'s private `Gate`, duplicated
/// here since access control is file-scoped.
private actor Gate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { continuations.count }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}
