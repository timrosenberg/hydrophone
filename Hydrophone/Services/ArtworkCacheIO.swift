import AppKit
import CryptoKit
import Foundation

struct ArtworkLoadInput: Sendable {
    let coverArt: String
    let size: Int
    let fileURL: URL
    let useDisk: Bool
    let failureRetryDelay: Duration
}

struct ArtworkLoadResult: @unchecked Sendable {
    let image: NSImage
    let stagedFileURL: URL?
}

enum ArtworkCacheIO {
    private static let fetchLimiter = AsyncLimiter(limit: 6)

    static func load(_ input: ArtworkLoadInput, client: SubsonicClient,
                     session: URLSession) async -> ArtworkLoadResult? {
        if input.useDisk,
           let data = try? Data(contentsOf: input.fileURL),
           let image = NSImage(data: data) {
            return ArtworkLoadResult(image: image, stagedFileURL: nil)
        }
        guard let url = try? await client.coverArtURL(id: input.coverArt, size: input.size),
              let (data, image) = await fetchWithRetry(
                url, session: session, failureRetryDelay: input.failureRetryDelay
              ) else { return nil }
        let staged = input.fileURL.appendingPathExtension("pending-\(UUID().uuidString)")
        do {
            try data.write(to: staged, options: .atomic)
            return ArtworkLoadResult(image: image, stagedFileURL: staged)
        } catch {
            return ArtworkLoadResult(image: image, stagedFileURL: nil)
        }
    }

    static func discard(_ stagedFileURL: URL?) {
        guard let stagedFileURL else { return }
        try? FileManager.default.removeItem(at: stagedFileURL)
    }

    static func publish(_ stagedFileURL: URL?, to destination: URL) {
        guard let stagedFileURL else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try? FileManager.default.replaceItemAt(destination, withItemAt: stagedFileURL)
        } else {
            try? FileManager.default.moveItem(at: stagedFileURL, to: destination)
        }
        discard(stagedFileURL)
    }

    static func retryDelay(from response: HTTPURLResponse) -> TimeInterval {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else { return 2 }
        return min(seconds, 30)
    }

    static func cost(of image: NSImage) -> Int {
        let rep = image.representations.first
        let repWidth = rep?.pixelsWide ?? 0
        let repHeight = rep?.pixelsHigh ?? 0
        let width = repWidth > 0 ? repWidth : Int(image.size.width)
        let height = repHeight > 0 ? repHeight : Int(image.size.height)
        return max(width, 0) * max(height, 0) * 4
    }

    static func filename(identity: String, size: Int) -> String {
        sha(of: "\(identity)@\(size)") + ".img"
    }

    static func scope(for url: URL) -> String {
        String(sha(of: url.absoluteString).prefix(16))
    }

    static func fetchWithRetry(
        _ url: URL,
        session: URLSession,
        failureRetryDelay: Duration
    ) async -> (Data, NSImage)? {
        var result = await fetchLimiter.run { await fetch(url, session: session) }
        switch result {
        case let .rateLimited(delay):
            try? await Task.sleep(for: .seconds(delay))
            result = await fetchLimiter.run { await fetch(url, session: session) }
        case .failed:
            try? await Task.sleep(for: failureRetryDelay)
            result = await fetchLimiter.run { await fetch(url, session: session) }
        case .image:
            break
        }
        guard case let .image(data, image) = result else { return nil }
        return (data, image)
    }

    private enum FetchResult {
        case image(Data, NSImage)
        case rateLimited(TimeInterval)
        case failed
    }

    private static func fetch(_ url: URL, session: URLSession) async -> FetchResult {
        guard let (data, response) = try? await session.data(from: url) else {
            return .failed
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            return .rateLimited(retryDelay(from: http))
        }
        guard let image = NSImage(data: data) else { return .failed }
        return .image(data, image)
    }

    private static func sha(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
