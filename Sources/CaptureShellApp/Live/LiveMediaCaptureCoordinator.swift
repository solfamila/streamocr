import Foundation

final class LiveMediaCaptureCoordinator {
    private let outputURL: URL
    private let loggingEnabled: Bool
    private var recorder: LiveSourceStreamRecorder?
    private var hasStartedRecording = false

    init(outputURL: URL, loggingEnabled: Bool, runSeconds _: Double) {
        self.outputURL = outputURL
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
            print("[live] starting_source_recording url=\(sourceURL.absoluteString)")
        }

        let recorder = LiveSourceStreamRecorder(
            outputURL: outputURL,
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
        preferredDirectSourceURL(seedURL: seedURL) ?? resolved.streamURL
    }

    static func preferredRecordingSourceURL(seedURL: URL) -> URL {
        preferredDirectSourceURL(seedURL: seedURL) ?? seedURL
    }

    private static func preferredDirectSourceURL(seedURL: URL) -> URL? {
        let directCandidates = (try? NanocosmosStreamResolver.deriveDirectPlaybackCandidates(seedURL: seedURL)) ?? []
        if let originalStyleCandidate = directCandidates.first(where: { $0.absoluteString.contains("url=") }) {
            return originalStyleCandidate
        }
        return directCandidates.first
    }
}
