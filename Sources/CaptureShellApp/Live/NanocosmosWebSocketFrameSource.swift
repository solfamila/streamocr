import Foundation

enum NanocosmosWebSocketFrameSourceError: Error, LocalizedError {
    case invalidWebSocketURL(URL)
    case openTimedOut(URL)
    case receiveFailed(String)
    case noFramesDecoded(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidWebSocketURL(url):
            return "URL is not a supported Nanocosmos WebSocket playback URL: \(url.absoluteString)"
        case let .openTimedOut(url):
            return "Timed out opening Nanocosmos WebSocket playback URL: \(url.absoluteString)"
        case let .receiveFailed(message):
            return "Nanocosmos WebSocket receive failed: \(message)"
        case let .noFramesDecoded(url):
            return "Nanocosmos WebSocket playback produced no decoded frames: \(url.absoluteString)"
        }
    }
}

struct NanocosmosWebSocketDecodeSummary: Sendable {
    let webSocketURL: URL
    let elapsedSeconds: Double
    let textMessageCount: Int
    let binaryMessageCount: Int
    let binaryByteCount: Int
    let decodedFrameCount: Int
    let firstBinaryElapsedSeconds: Double?
    let firstMediaElapsedSeconds: Double?
    let firstFrameElapsedSeconds: Double?
}

final class NanocosmosWebSocketFrameSource {
    func decode(
        webSocketURL: URL,
        runSeconds: TimeInterval,
        maximumFrames: Int? = nil,
        loggingEnabled: Bool = false,
        shouldContinue: @escaping () -> Bool = { true },
        onFrame: @escaping (VideoFrame) throws -> Void
    ) throws -> NanocosmosWebSocketDecodeSummary {
        guard Self.supports(webSocketURL: webSocketURL) else {
            throw NanocosmosWebSocketFrameSourceError.invalidWebSocketURL(webSocketURL)
        }

        let start = Date()
        let state = NanocosmosWebSocketDecodeState()
        let done = DispatchSemaphore(value: 0)
        let delegate = NanocosmosWebSocketFrameSourceDelegate(start: start)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(8, runSeconds + 6)
        configuration.timeoutIntervalForResource = max(8, runSeconds + 6)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: webSocketURL)

        let decoder = FragmentedMP4VideoToolboxDecoder { frame in
            guard shouldContinue() else {
                state.finish()
                done.signal()
                return
            }

            do {
                try onFrame(frame)
            } catch {
                state.fail(error)
                done.signal()
                return
            }

            state.recordDecodedFrame()
            if let maximumFrames, state.decodedFrameCount >= maximumFrames {
                state.finish()
                done.signal()
            }
        }

        task.resume()
        guard delegate.waitForOpen(timeoutSeconds: min(8, max(2, runSeconds + 2))) else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw NanocosmosWebSocketFrameSourceError.openTimedOut(webSocketURL)
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + runSeconds) {
            state.finish()
            task.cancel(with: .normalClosure, reason: nil)
            done.signal()
        }

        func receiveNext() {
            task.receive { result in
                if state.isFinished {
                    return
                }
                guard shouldContinue() else {
                    state.finish()
                    done.signal()
                    return
                }

                switch result {
                case let .failure(error):
                    if state.isFinished {
                        return
                    }
                    state.fail(error)
                    done.signal()
                case let .success(message):
                    switch message {
                    case let .data(data):
                        let binaryIndex = state.recordBinaryMessage(byteCount: data.count)
                        if loggingEnabled, binaryIndex <= 5 || binaryIndex.isMultiple(of: 60) {
                            print(
                                "[live-wss] binary_message index=\(binaryIndex) " +
                                "bytes=\(data.count) elapsed_seconds=\(String(format: "%.3f", Date().timeIntervalSince(start)))"
                            )
                        }
                        do {
                            try decoder.append(data)
                        } catch {
                            state.fail(error)
                            done.signal()
                            return
                        }
                    case let .string(text):
                        let textIndex = state.recordTextMessage()
                        if loggingEnabled, textIndex <= 6 {
                            print("[live-wss] text_message index=\(textIndex) \(text.prefix(220))")
                        }
                    @unknown default:
                        break
                    }

                    if state.isFinished {
                        done.signal()
                    } else {
                        receiveNext()
                    }
                }
            }
        }

        receiveNext()
        _ = done.wait(timeout: .now() + runSeconds + 12)
        state.finish()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        decoder.finish()

        if let error = state.error {
            throw error
        }

        let decoderSummary = decoder.summary()
        let snapshot = state.snapshot()
        guard decoderSummary.frameCount > 0 else {
            throw NanocosmosWebSocketFrameSourceError.noFramesDecoded(webSocketURL)
        }

        return NanocosmosWebSocketDecodeSummary(
            webSocketURL: webSocketURL,
            elapsedSeconds: Date().timeIntervalSince(start),
            textMessageCount: snapshot.textMessageCount,
            binaryMessageCount: snapshot.binaryMessageCount,
            binaryByteCount: snapshot.binaryByteCount,
            decodedFrameCount: decoderSummary.frameCount,
            firstBinaryElapsedSeconds: snapshot.firstBinaryElapsedSeconds,
            firstMediaElapsedSeconds: decoderSummary.firstMediaElapsedSeconds,
            firstFrameElapsedSeconds: decoderSummary.firstFrameElapsedSeconds
        )
    }

    static func normalizedWebSocketURL(from seedURL: URL) -> URL? {
        guard var components = URLComponents(url: seedURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let lowercasedPath = components.path.lowercased()
        guard lowercasedPath.contains("/h5live/") else {
            return nil
        }

        components.scheme = "wss"
        if lowercasedPath.contains("/h5live/http/") {
            components.path = replaceH5LiveSuffix(in: components.path, suffix: "/h5live/stream/stream.mp4")
        } else if lowercasedPath.contains("/h5live/stream/") {
            components.path = replaceH5LiveSuffix(in: components.path, suffix: "/h5live/stream/stream.mp4")
        }

        components.queryItems = (components.queryItems ?? []).filter { item in
            !(item.name.lowercased() == "flags" && item.value?.lowercased() == "checkandclose")
        }

        return components.url
    }

    static func supports(webSocketURL: URL) -> Bool {
        guard webSocketURL.scheme?.lowercased() == "wss" else {
            return false
        }
        return webSocketURL.path.lowercased().contains("/h5live/stream/stream.mp4")
    }

    private static func replaceH5LiveSuffix(in path: String, suffix: String) -> String {
        let lowercasedPath = path.lowercased()
        guard let h5liveRange = lowercasedPath.range(of: "/h5live/") else {
            return path
        }
        let offset = lowercasedPath.distance(from: lowercasedPath.startIndex, to: h5liveRange.lowerBound)
        let index = path.index(path.startIndex, offsetBy: offset)
        return String(path[..<index]) + suffix
    }
}

private final class NanocosmosWebSocketFrameSourceDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let start: Date
    private let openSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didOpen = false

    init(start: Date) {
        self.start = start
    }

    func waitForOpen(timeoutSeconds: TimeInterval) -> Bool {
        if openSemaphore.wait(timeout: .now() + timeoutSeconds) == .success {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        return didOpen
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        didOpen = true
        lock.unlock()
        print(
            "[live-wss] opened elapsed_seconds=" +
            "\(String(format: "%.3f", Date().timeIntervalSince(start))) protocol=\(`protocol` ?? "nil")"
        )
        openSemaphore.signal()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        print(
            "[live-wss] closed elapsed_seconds=" +
            "\(String(format: "%.3f", Date().timeIntervalSince(start))) " +
            "code=\(closeCode.rawValue) reason=\(reasonText)"
        )
    }
}

private final class NanocosmosWebSocketDecodeState: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinishedStorage = false
    private var textMessageCountStorage = 0
    private var binaryMessageCountStorage = 0
    private var binaryByteCountStorage = 0
    private var decodedFrameCountStorage = 0
    private var firstBinaryElapsedSecondsStorage: Double?
    private var errorStorage: Error?
    private let start = Date()

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinishedStorage
    }

    var decodedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodedFrameCountStorage
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }

    func finish() {
        lock.lock()
        isFinishedStorage = true
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if errorStorage == nil {
            errorStorage = error
        }
        isFinishedStorage = true
        lock.unlock()
    }

    func recordTextMessage() -> Int {
        lock.lock()
        textMessageCountStorage += 1
        let count = textMessageCountStorage
        lock.unlock()
        return count
    }

    func recordBinaryMessage(byteCount: Int) -> Int {
        lock.lock()
        binaryMessageCountStorage += 1
        binaryByteCountStorage += byteCount
        firstBinaryElapsedSecondsStorage = firstBinaryElapsedSecondsStorage ?? Date().timeIntervalSince(start)
        let count = binaryMessageCountStorage
        lock.unlock()
        return count
    }

    func recordDecodedFrame() {
        lock.lock()
        decodedFrameCountStorage += 1
        lock.unlock()
    }

    func snapshot() -> NanocosmosWebSocketDecodeStateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return NanocosmosWebSocketDecodeStateSnapshot(
            textMessageCount: textMessageCountStorage,
            binaryMessageCount: binaryMessageCountStorage,
            binaryByteCount: binaryByteCountStorage,
            firstBinaryElapsedSeconds: firstBinaryElapsedSecondsStorage
        )
    }
}

private struct NanocosmosWebSocketDecodeStateSnapshot {
    let textMessageCount: Int
    let binaryMessageCount: Int
    let binaryByteCount: Int
    let firstBinaryElapsedSeconds: Double?
}
