import Foundation

enum NanocosmosStreamingChunkPullerError: Error, LocalizedError {
    case emptyChunk(URL)
    case requestFailed(String)
    case timedOutWaitingForFirstByte(URL)
    case failedToCreateDestination(String)

    var errorDescription: String? {
        switch self {
        case let .emptyChunk(url):
            return "Streaming MP4 source returned an empty chunk: \(url.absoluteString)"
        case let .requestFailed(message):
            return "Streaming MP4 request failed: \(message)"
        case let .timedOutWaitingForFirstByte(url):
            return "Timed out waiting for first streaming MP4 byte: \(url.absoluteString)"
        case let .failedToCreateDestination(message):
            return "Failed to prepare streaming MP4 chunk destination: \(message)"
        }
    }
}

struct NanocosmosCapturedChunk: Sendable {
    let fileURL: URL
    let sourceURL: URL
    let byteCount: Int
    let elapsedSeconds: Double
    let firstByteElapsedSeconds: Double?
    let activeCaptureSeconds: Double?
    let finishReason: NanocosmosChunkCaptureFinishReason
}

enum NanocosmosChunkCaptureFinishReason: String, Sendable {
    case responseCompleted = "response_completed"
    case playableProbe = "playable_probe"
    case captureWindow = "capture_window"
}

final class NanocosmosStreamingChunkPuller {
    func captureChunk(
        sourceURL: URL,
        destinationURL: URL,
        firstByteTimeoutSeconds: TimeInterval,
        captureWindowSeconds: TimeInterval,
        minimumPlayableProbeWindowSeconds: TimeInterval? = nil,
        playableProbeIntervalSeconds: TimeInterval = 0.05,
        playableProbe: ((URL) -> Bool)? = nil
    ) throws -> NanocosmosCapturedChunk {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            fileManager.createFile(atPath: destinationURL.path, contents: nil)
        } catch {
            throw NanocosmosStreamingChunkPullerError.failedToCreateDestination(error.localizedDescription)
        }

        guard let fileHandle = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw NanocosmosStreamingChunkPullerError.failedToCreateDestination(destinationURL.path)
        }

        let delegate = StreamingChunkCaptureDelegate(fileHandle: fileHandle)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(5, firstByteTimeoutSeconds + captureWindowSeconds + 2)
        configuration.timeoutIntervalForResource = max(5, firstByteTimeoutSeconds + captureWindowSeconds + 2)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: sourceURL, timeoutInterval: configuration.timeoutIntervalForRequest)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let start = Date()
        let task = session.dataTask(with: request)
        task.resume()
        var nextPlayableProbeTime = start.addingTimeInterval(
            max(0.01, playableProbeIntervalSeconds)
        )
        var lastPlayableProbeByteCount = 0

        defer {
            task.cancel()
            session.invalidateAndCancel()
            try? fileHandle.close()
        }

        while true {
            let snapshot = delegate.snapshot()
            let elapsedSeconds = Date().timeIntervalSince(start)

            if snapshot.didComplete {
                if let error = snapshot.error {
                    throw NanocosmosStreamingChunkPullerError.requestFailed(error.localizedDescription)
                }

                if snapshot.byteCount > 0 {
                    return NanocosmosCapturedChunk(
                        fileURL: destinationURL,
                        sourceURL: snapshot.responseURL ?? sourceURL,
                        byteCount: snapshot.byteCount,
                        elapsedSeconds: elapsedSeconds,
                        firstByteElapsedSeconds: snapshot.firstByteElapsedSeconds,
                        activeCaptureSeconds: Self.activeCaptureSeconds(
                            elapsedSeconds: elapsedSeconds,
                            firstByteElapsedSeconds: snapshot.firstByteElapsedSeconds
                        ),
                        finishReason: .responseCompleted
                    )
                }

                throw NanocosmosStreamingChunkPullerError.emptyChunk(sourceURL)
            }

            if snapshot.firstByteElapsedSeconds == nil,
               elapsedSeconds >= firstByteTimeoutSeconds {
                delegate.markCancelledByPolicy()
                task.cancel()
                _ = delegate.waitForCompletion(timeoutSeconds: 2)
                throw NanocosmosStreamingChunkPullerError.timedOutWaitingForFirstByte(sourceURL)
            }

            if let firstByteElapsedSeconds = snapshot.firstByteElapsedSeconds,
               let playableProbe,
               elapsedSeconds - firstByteElapsedSeconds >= (minimumPlayableProbeWindowSeconds ?? 0),
               snapshot.byteCount > lastPlayableProbeByteCount,
               Date() >= nextPlayableProbeTime {
                lastPlayableProbeByteCount = snapshot.byteCount
                nextPlayableProbeTime = Date().addingTimeInterval(
                    max(0.01, playableProbeIntervalSeconds)
                )

                if delegate.markCancelledByPolicyIfPlayable({ playableProbe(destinationURL) }) {
                    task.cancel()
                    _ = delegate.waitForCompletion(timeoutSeconds: 2)
                    let finalSnapshot = delegate.snapshot()
                    guard finalSnapshot.byteCount > 0 else {
                        throw NanocosmosStreamingChunkPullerError.emptyChunk(sourceURL)
                    }
                    let finishElapsedSeconds = Date().timeIntervalSince(start)
                    return NanocosmosCapturedChunk(
                        fileURL: destinationURL,
                        sourceURL: finalSnapshot.responseURL ?? sourceURL,
                        byteCount: finalSnapshot.byteCount,
                        elapsedSeconds: finishElapsedSeconds,
                        firstByteElapsedSeconds: finalSnapshot.firstByteElapsedSeconds,
                        activeCaptureSeconds: Self.activeCaptureSeconds(
                            elapsedSeconds: finishElapsedSeconds,
                            firstByteElapsedSeconds: finalSnapshot.firstByteElapsedSeconds
                        ),
                        finishReason: .playableProbe
                    )
                }
            }

            if let firstByteElapsedSeconds = snapshot.firstByteElapsedSeconds,
               elapsedSeconds - firstByteElapsedSeconds >= captureWindowSeconds {
                delegate.markCancelledByPolicy()
                task.cancel()
                _ = delegate.waitForCompletion(timeoutSeconds: 2)
                let finalSnapshot = delegate.snapshot()
                guard finalSnapshot.byteCount > 0 else {
                    throw NanocosmosStreamingChunkPullerError.emptyChunk(sourceURL)
                }
                let finishElapsedSeconds = Date().timeIntervalSince(start)
                return NanocosmosCapturedChunk(
                    fileURL: destinationURL,
                    sourceURL: finalSnapshot.responseURL ?? sourceURL,
                    byteCount: finalSnapshot.byteCount,
                    elapsedSeconds: finishElapsedSeconds,
                    firstByteElapsedSeconds: finalSnapshot.firstByteElapsedSeconds,
                    activeCaptureSeconds: Self.activeCaptureSeconds(
                        elapsedSeconds: finishElapsedSeconds,
                        firstByteElapsedSeconds: finalSnapshot.firstByteElapsedSeconds
                    ),
                    finishReason: .captureWindow
                )
            }

            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func supports(sourceURL: URL) -> Bool {
        let path = sourceURL.path.lowercased()
        return path.hasSuffix("/stream.mp4") || path.contains("/stream.mp4")
    }

    private static func activeCaptureSeconds(
        elapsedSeconds: Double,
        firstByteElapsedSeconds: Double?
    ) -> Double? {
        guard let firstByteElapsedSeconds else {
            return nil
        }
        return max(0, elapsedSeconds - firstByteElapsedSeconds)
    }
}

private final class StreamingChunkCaptureDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let completionSemaphore = DispatchSemaphore(value: 0)
    private let start = Date()

    private var byteCount = 0
    private var firstByteElapsedSeconds: Double?
    private var didComplete = false
    private var responseURL: URL?
    private var error: Error?
    private var cancelledByPolicy = false
    private var acceptsData = true

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        responseURL = response.url
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard !didComplete, acceptsData else {
            return
        }
        if firstByteElapsedSeconds == nil {
            firstByteElapsedSeconds = Date().timeIntervalSince(start)
        }

        do {
            try fileHandle.write(contentsOf: data)
            byteCount += data.count
        } catch {
            self.error = error
            didComplete = true
            completionSemaphore.signal()
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        didComplete = true
        if let error, !cancelledByPolicy {
            self.error = error
        }
        completionSemaphore.signal()
    }

    func markCancelledByPolicy() {
        lock.lock()
        cancelledByPolicy = true
        acceptsData = false
        lock.unlock()
    }

    func waitForCompletion(timeoutSeconds: TimeInterval) -> Bool {
        completionSemaphore.wait(timeout: .now() + timeoutSeconds) == .success
    }

    func markCancelledByPolicyIfPlayable(_ probe: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle.synchronize()
        let isPlayable = probe()
        if isPlayable {
            cancelledByPolicy = true
            acceptsData = false
        }
        return isPlayable
    }

    func snapshot() -> StreamingChunkCaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return StreamingChunkCaptureSnapshot(
            byteCount: byteCount,
            firstByteElapsedSeconds: firstByteElapsedSeconds,
            didComplete: didComplete,
            responseURL: responseURL,
            error: error
        )
    }
}

private struct StreamingChunkCaptureSnapshot {
    let byteCount: Int
    let firstByteElapsedSeconds: Double?
    let didComplete: Bool
    let responseURL: URL?
    let error: Error?
}
