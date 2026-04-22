import Foundation

struct ResolvedLiveStream: Sendable {
    let seedURL: URL
    let playlistURL: URL
    let playbackURL: URL
    let alternatePlaybackURLs: [URL]
    let streamURL: URL
    let playlistText: String
}

enum NanocosmosStreamResolverError: Error, LocalizedError {
    case invalidSeedURL(URL)
    case playlistFetchFailed(String)
    case playlistHasNoMediaSegment(URL)
    case invalidMediaSegment(String, URL)

    var errorDescription: String? {
        switch self {
        case let .invalidSeedURL(url):
            return "Seed URL is not a nanocosmos h5live URL: \(url.absoluteString)"
        case let .playlistFetchFailed(message):
            return "Failed to fetch a playable nanocosmos playlist: \(message)"
        case let .playlistHasNoMediaSegment(url):
            return "Playlist did not contain a media segment: \(url.absoluteString)"
        case let .invalidMediaSegment(segment, playlistURL):
            return "Could not resolve media segment '\(segment)' from playlist \(playlistURL.absoluteString)"
        }
    }
}

enum NanocosmosStreamResolver {
    static func resolve(seedURL: URL, timeoutSeconds: TimeInterval = 10) throws -> ResolvedLiveStream {
        let candidates = try derivePlaylistCandidates(seedURL: seedURL)
        let directPlaybackCandidates = try deriveDirectPlaybackCandidates(seedURL: seedURL)
        var failures: [String] = []

        for playlistURL in candidates {
            do {
                let playlistText = try fetchPlaylist(url: playlistURL, timeoutSeconds: timeoutSeconds)
                let streamURL = try streamURL(fromPlaylist: playlistText, playlistURL: playlistURL)
                let alternatePlaybackURLs = deduplicatedPlaybackURLs(
                    [streamURL] + directPlaybackCandidates,
                    excluding: [playlistURL]
                )
                return ResolvedLiveStream(
                    seedURL: seedURL,
                    playlistURL: playlistURL,
                    playbackURL: playlistURL,
                    alternatePlaybackURLs: alternatePlaybackURLs,
                    streamURL: streamURL,
                    playlistText: playlistText
                )
            } catch {
                failures.append("\(playlistURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw NanocosmosStreamResolverError.playlistFetchFailed(failures.joined(separator: " | "))
    }

    static func derivePlaylistCandidates(seedURL: URL) throws -> [URL] {
        let (components, originalItems, minimalItems, withoutURLItems) = try playbackComponents(seedURL: seedURL)

        let queryVariants: [[URLQueryItem]] = [
            [],
            minimalItems,
            originalItems,
            withoutURLItems
        ]

        var result: [URL] = []
        var seen = Set<String>()
        for queryItems in queryVariants {
            var playlistComponents = components
            playlistComponents.scheme = "https"
            playlistComponents.path = playlistTargetPath(from: components.path)
            setPercentEncodedQueryItems(queryItems, on: &playlistComponents)
            playlistComponents.fragment = nil

            guard let url = playlistComponents.url else {
                continue
            }
            if seen.insert(url.absoluteString).inserted {
                result.append(url)
            }
        }

        guard !result.isEmpty else {
            throw NanocosmosStreamResolverError.invalidSeedURL(seedURL)
        }
        return result
    }

    static func deriveDirectPlaybackCandidates(seedURL: URL) throws -> [URL] {
        let (components, originalItems, minimalItems, withoutURLItems) = try playbackComponents(seedURL: seedURL)
        let queryVariants: [[URLQueryItem]] = [
            minimalItems,
            originalItems,
            withoutURLItems,
            [],
        ]

        var result: [URL] = []
        var seen = Set<String>()
        for queryItems in queryVariants {
            var playbackComponents = components
            playbackComponents.scheme = "https"
            playbackComponents.path = playbackTargetPath(from: components.path)
            setPercentEncodedQueryItems(queryItems, on: &playbackComponents)
            playbackComponents.fragment = nil

            guard let url = playbackComponents.url else {
                continue
            }
            if seen.insert(url.absoluteString).inserted {
                result.append(url)
            }
        }

        guard !result.isEmpty else {
            throw NanocosmosStreamResolverError.invalidSeedURL(seedURL)
        }
        return result
    }

    static func streamURL(fromPlaylist playlistText: String, playlistURL: URL) throws -> URL {
        guard
            let segmentLine = playlistText
                .split(whereSeparator: \.isNewline)
                .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else {
            throw NanocosmosStreamResolverError.playlistHasNoMediaSegment(playlistURL)
        }

        guard let streamURL = resolveSegmentLine(segmentLine, playlistURL: playlistURL) else {
            throw NanocosmosStreamResolverError.invalidMediaSegment(segmentLine, playlistURL)
        }

        return streamURL
    }

    private static func fetchPlaylist(url: URL, timeoutSeconds: TimeInterval) throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.setValue("application/vnd.apple.mpegurl,*/*", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        let box = HTTPFetchResultBox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                box.store(.failure(error))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                box.store(.failure(NanocosmosStreamResolverError.playlistFetchFailed("HTTP \(statusCode) for \(url.absoluteString)")))
                return
            }

            guard
                let data,
                let text = String(data: data, encoding: .utf8),
                text.contains("#EXTM3U")
            else {
                box.store(.failure(NanocosmosStreamResolverError.playlistFetchFailed("non-HLS response from \(url.absoluteString)")))
                return
            }

            box.store(.success(text))
        }

        task.resume()
        if semaphore.wait(timeout: .now() + timeoutSeconds + 1) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw NanocosmosStreamResolverError.playlistFetchFailed("timeout for \(url.absoluteString)")
        }
        session.invalidateAndCancel()
        return try box.load().get()
    }

    private static func playbackComponents(seedURL: URL) throws -> (URLComponents, [URLQueryItem], [URLQueryItem], [URLQueryItem]) {
        guard
            let components = URLComponents(url: seedURL, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased(),
            host.contains("nanocosmos") || host.contains("nanostream") || host.contains("bintu"),
            components.path.lowercased().contains("/h5live/")
        else {
            throw NanocosmosStreamResolverError.invalidSeedURL(seedURL)
        }

        let originalItems = components.queryItems ?? []
        let withoutURLItems = originalItems.filter { $0.name.lowercased() != "url" }
        let preferredKeys: Set<String> = ["stream", "cid", "pid", "token", "expires", "options", "tag", "jwtoken"]
        let minimalItems = withoutURLItems.filter { preferredKeys.contains($0.name.lowercased()) }

        return (components, originalItems, minimalItems, withoutURLItems)
    }

    private static func playlistTargetPath(from path: String) -> String {
        let lowercasedPath = path.lowercased()
        guard let h5liveRange = lowercasedPath.range(of: "/h5live/") else {
            return path
        }
        let h5liveOffset = lowercasedPath.distance(from: lowercasedPath.startIndex, to: h5liveRange.lowerBound)
        let h5liveIndex = path.index(path.startIndex, offsetBy: h5liveOffset)
        let prefix = String(path[..<h5liveIndex])
        return prefix + "/h5live/http/playlist.m3u8"
    }

    private static func playbackTargetPath(from path: String) -> String {
        let lowercasedPath = path.lowercased()
        guard let h5liveRange = lowercasedPath.range(of: "/h5live/") else {
            return path
        }
        let h5liveOffset = lowercasedPath.distance(from: lowercasedPath.startIndex, to: h5liveRange.lowerBound)
        let h5liveIndex = path.index(path.startIndex, offsetBy: h5liveOffset)
        let prefix = String(path[..<h5liveIndex])
        return prefix + "/h5live/http/stream.mp4"
    }

    private static func deduplicatedPlaybackURLs(_ urls: [URL], excluding excluded: [URL]) -> [URL] {
        let excludedStrings = Set(excluded.map(\.absoluteString))
        var seen = Set<String>()
        var deduplicated: [URL] = []

        for url in urls {
            let absoluteString = url.absoluteString
            guard !excludedStrings.contains(absoluteString) else {
                continue
            }
            if seen.insert(absoluteString).inserted {
                deduplicated.append(url)
            }
        }

        return deduplicated
    }

    private static func resolveSegmentLine(_ segmentLine: String, playlistURL: URL) -> URL? {
        let parts = segmentLine.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard
            let baseURL = URL(string: String(parts[0]), relativeTo: playlistURL)?.absoluteURL,
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        if parts.count == 2 {
            components.percentEncodedQuery = percentEncodedQuery(fromRawQuery: String(parts[1]))
        }

        return components.url
    }

    private static func setPercentEncodedQueryItems(_ queryItems: [URLQueryItem], on components: inout URLComponents) {
        guard !queryItems.isEmpty else {
            components.query = nil
            components.percentEncodedQuery = nil
            return
        }

        components.percentEncodedQuery = queryItems
            .map { item in
                let name = encodeQueryComponent(item.name)
                guard let value = item.value else { return name }
                return "\(name)=\(encodeQueryComponent(value))"
            }
            .joined(separator: "&")
    }

    private static func percentEncodedQuery(fromRawQuery rawQuery: String) -> String {
        rawQuery
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawName = String(parts.first ?? "")
                let rawValue = parts.count > 1 ? String(parts[1]) : ""
                let name = encodeQueryComponent(rawName.removingPercentEncoding ?? rawName)
                let value = encodeQueryComponent(rawValue.removingPercentEncoding ?? rawValue)
                return "\(name)=\(value)"
            }
            .joined(separator: "&")
    }

    private static func encodeQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private final class HTTPFetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, any Error>?

    func store(_ result: Result<String, any Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() throws -> Result<String, any Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            throw NanocosmosStreamResolverError.playlistFetchFailed("URLSession completed without a result")
        }
        return result
    }
}
