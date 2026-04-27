import AVFoundation
import Foundation

enum LiveSourceStreamRecorderError: Error, LocalizedError {
    case recordingTimedOut(String)
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .recordingTimedOut(message):
            return "Timed out waiting for native source recorder: \(message)"
        case let .recordingFailed(message):
            return "Native source recorder failed: \(message)"
        }
    }
}

final class LiveSourceStreamRecorder: @unchecked Sendable {
    private let outputURL: URL
    private let loggingEnabled: Bool

    private let lock = NSLock()
    private let completionSemaphore = DispatchSemaphore(value: 0)
    private var result: Result<NanocosmosCapturedChunk, Error>?
    private var didStart = false
    private var stopRequested = false

    init(outputURL: URL, loggingEnabled: Bool) {
        self.outputURL = outputURL
        self.loggingEnabled = loggingEnabled
    }

    func start(sourceURL: URL, runSeconds: Double) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        lock.lock()
        didStart = true
        result = nil
        stopRequested = false
        lock.unlock()

        let captureWindowSeconds = max(0.05, runSeconds)
        let firstByteTimeoutSeconds = min(max(captureWindowSeconds, 4), 12)
        let outputURL = self.outputURL

        DispatchQueue.global(qos: .userInitiated).async {
            let captureResult: Result<NanocosmosCapturedChunk, Error>
            do {
                let capturedChunk = try NanocosmosStreamingChunkPuller().captureChunk(
                    sourceURL: sourceURL,
                    destinationURL: outputURL,
                    firstByteTimeoutSeconds: firstByteTimeoutSeconds,
                    captureWindowSeconds: captureWindowSeconds,
                    shouldContinue: { [weak self] in
                        guard let self else {
                            return false
                        }
                        self.lock.lock()
                        let shouldContinue = !self.stopRequested
                        self.lock.unlock()
                        return shouldContinue
                    }
                )
                captureResult = .success(capturedChunk)
            } catch {
                captureResult = .failure(error)
            }

            self.lock.lock()
            self.result = captureResult
            self.lock.unlock()
            self.completionSemaphore.signal()
        }
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    func finish(timeout: TimeInterval) throws -> LiveRecordingSummary? {
        lock.lock()
        let started = didStart
        let currentResult = result
        lock.unlock()

        guard started else {
            return nil
        }

        if currentResult == nil,
           completionSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw LiveSourceStreamRecorderError.recordingTimedOut(outputURL.path)
        }

        lock.lock()
        let finalResult = result
        didStart = false
        result = nil
        stopRequested = false
        lock.unlock()

        guard let finalResult else {
            throw LiveSourceStreamRecorderError.recordingFailed("missing_result")
        }

        switch finalResult {
        case .failure(let error):
            throw LiveSourceStreamRecorderError.recordingFailed(error.localizedDescription)
        case .success:
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                return nil
            }
            return Self.probeSummary(outputURL: outputURL, loggingEnabled: loggingEnabled)
        }
    }

    static func estimatedFrameCount(
        nominalFrameRate: Double?,
        durationSeconds: Double?
    ) -> Int {
        guard
            let durationSeconds,
            durationSeconds > 0,
            let nominalFrameRate,
            nominalFrameRate > 0
        else {
            return 0
        }

        return max(0, Int((durationSeconds * nominalFrameRate).rounded()))
    }

    private static func probeSummary(outputURL: URL, loggingEnabled: Bool) -> LiveRecordingSummary {
        let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value
        let fallback = LiveRecordingSummary(
            outputPath: outputURL.path,
            frameCount: 0,
            droppedFrameCount: 0,
            width: 0,
            height: 0,
            firstPresentationTimeSeconds: nil,
            lastPresentationTimeSeconds: nil,
            durationSeconds: nil,
            fileSizeBytes: fileSizeBytes
        )

        let asset = AVURLAsset(url: outputURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            if loggingEnabled {
                print("[live] native_recording_summary_failed missing_video_track=\"\(outputURL.path)\"")
            }
            return fallback
        }

        let durationSeconds = {
            let seconds = CMTimeGetSeconds(asset.duration)
            return seconds.isFinite ? max(0, seconds) : nil
        }()
        let naturalSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let nominalFrameRate = videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : nil
        let frameCount = estimatedFrameCount(
            nominalFrameRate: nominalFrameRate,
            durationSeconds: durationSeconds
        )

        return LiveRecordingSummary(
            outputPath: outputURL.path,
            frameCount: frameCount,
            droppedFrameCount: 0,
            width: Int(naturalSize.width.magnitude.rounded()),
            height: Int(naturalSize.height.magnitude.rounded()),
            firstPresentationTimeSeconds: durationSeconds.map { _ in 0 },
            lastPresentationTimeSeconds: durationSeconds,
            durationSeconds: durationSeconds,
            fileSizeBytes: fileSizeBytes
        )
    }
}
