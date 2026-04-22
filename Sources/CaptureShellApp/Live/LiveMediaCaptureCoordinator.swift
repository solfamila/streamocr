import Foundation

final class LiveMediaCaptureCoordinator {
    private let outputURL: URL
    private let includeAudio: Bool
    private let loggingEnabled: Bool
    private var recorder: LiveSourceStreamRecorder?
    private var hasStartedRecording = false

    init(outputURL: URL, includeAudio: Bool, loggingEnabled: Bool, runSeconds _: Double) {
        self.outputURL = outputURL
        self.includeAudio = includeAudio
        self.loggingEnabled = loggingEnabled
    }

    func ensureRecordingStarted(
        seedURL: URL,
        remainingSeconds: Double,
        resolved: ResolvedLiveStream? = nil
    ) throws {
        guard !hasStartedRecording else {
            return
        }

        let remainingSeconds = max(0.05, remainingSeconds)
        let sourceURL = resolved.map {
            Self.preferredRecordingSourceURL(seedURL: seedURL, resolved: $0)
        } ?? Self.preferredRecordingSourceURL(seedURL: seedURL)

        if loggingEnabled {
            print("[live] starting_source_recording url=\(sourceURL.absoluteString) include_audio=\(includeAudio)")
        }

        let recorder = LiveSourceStreamRecorder(
            outputURL: outputURL,
            includeAudio: includeAudio,
            loggingEnabled: loggingEnabled
        )
        try recorder.start(sourceURL: sourceURL, runSeconds: remainingSeconds)
        self.recorder = recorder
        self.hasStartedRecording = true
    }

    func finish() throws -> LiveRecordingSummary? {
        guard let recorder else {
            return nil
        }

        return try recorder.finish(timeout: 20)
    }

    static func preferredRecordingSourceURL(seedURL: URL, resolved: ResolvedLiveStream) -> URL {
        let preferredCandidates = LiveFFmpegVideoDecoder.preferredSourceURLs(
            seedURL: seedURL,
            resolved: resolved
        )
        return preferredCandidates.first ?? resolved.playbackURL
    }

    static func preferredRecordingSourceURL(seedURL: URL) -> URL {
        let preferredCandidates = LiveFFmpegVideoDecoder.preferredDirectSourceURLs(seedURL: seedURL)
        return preferredCandidates.first ?? seedURL
    }
}
