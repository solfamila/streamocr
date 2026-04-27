import Foundation

struct LiveRecordingStatusSnapshot: Equatable, Sendable {
    enum State: String, Sendable {
        case off
        case recording
        case stopping
        case error
    }

    let state: State
    let isRecording: Bool
    let headline: String
    let detail: String
    let outputPath: String?

    static let off = LiveRecordingStatusSnapshot(
        state: .off,
        isRecording: false,
        headline: "Recording: Off",
        detail: "Recordings are saved to ~/Movies/StreamOCR Recordings.",
        outputPath: nil
    )
}

enum LiveRecordingSessionControllerError: Error, LocalizedError {
    case invalidSeedURL(String)
    case alreadyRecording
    case unsupportedSource(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidSeedURL(text):
            return "Invalid live stream URL for recording: \(text)"
        case .alreadyRecording:
            return "A live stream recording is already running."
        case let .unsupportedSource(url):
            return "This live source is not supported by the native source recorder: \(url.absoluteString)"
        }
    }
}

struct LiveManualRecordingMetadata: Codable, Equatable, Sendable {
    let seedURL: String
    let sourceURL: String
    let startedAt: String
    let finishedAt: String
    let recording: LiveRecordingSummary
}

final class LiveRecordingSessionController: @unchecked Sendable {
    var onStatusChanged: ((LiveRecordingStatusSnapshot) -> Void)?

    private let stateLock = NSLock()
    private var activeSession: LiveManualRecordingSession?
    private var latestStatus = LiveRecordingStatusSnapshot.off

    func currentStatusSnapshot() -> LiveRecordingStatusSnapshot {
        stateLock.lock()
        let status = latestStatus
        stateLock.unlock()
        return status
    }

    func start(seedURLText: String, loggingEnabled: Bool = false) throws {
        let trimmed = seedURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seedURL = URL(string: trimmed), !trimmed.isEmpty else {
            throw LiveRecordingSessionControllerError.invalidSeedURL(seedURLText)
        }

        stateLock.lock()
        let isAlreadyRecording = activeSession != nil
        stateLock.unlock()
        guard !isAlreadyRecording else {
            throw LiveRecordingSessionControllerError.alreadyRecording
        }

        let sourceURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(seedURL: seedURL)
        guard NanocosmosStreamingChunkPuller.supports(sourceURL: sourceURL) else {
            throw LiveRecordingSessionControllerError.unsupportedSource(sourceURL)
        }

        let outputURL = try Self.makeRecordingOutputURL()
        let recorder = LiveSourceStreamRecorder(outputURL: outputURL, loggingEnabled: loggingEnabled)
        let startedAt = Date()
        try recorder.start(
            sourceURL: sourceURL,
            runSeconds: 24 * 60 * 60
        )

        let session = LiveManualRecordingSession(
            id: UUID(),
            seedURL: seedURL,
            sourceURL: sourceURL,
            outputURL: outputURL,
            recorder: recorder,
            startedAt: startedAt
        )

        stateLock.lock()
        activeSession = session
        stateLock.unlock()

        publishStatus(
            LiveRecordingStatusSnapshot(
                state: .recording,
                isRecording: true,
                headline: "Recording: On",
                detail: "Saving source MP4 to \(outputURL.path)",
                outputPath: outputURL.path
            )
        )
    }

    func stop() {
        stateLock.lock()
        guard let session = activeSession else {
            stateLock.unlock()
            publishStatus(.off)
            return
        }
        stateLock.unlock()

        publishStatus(
            LiveRecordingStatusSnapshot(
                state: .stopping,
                isRecording: false,
                headline: "Recording: Stopping",
                detail: "Finalizing \(session.outputURL.lastPathComponent)...",
                outputPath: session.outputURL.path
            )
        )

        session.recorder.stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.finishStop(session: session)
        }
    }

    private func finishStop(session: LiveManualRecordingSession) {
        do {
            guard let summary = try session.recorder.finish(timeout: 20) else {
                throw LiveSourceStreamRecorderError.recordingFailed("missing_recording_file")
            }

            try Self.writeMetadata(
                summary: summary,
                session: session,
                finishedAt: Date()
            )

            stateLock.lock()
            if activeSession?.id == session.id {
                activeSession = nil
            }
            stateLock.unlock()

            publishStatus(
                LiveRecordingStatusSnapshot(
                    state: .off,
                    isRecording: false,
                    headline: "Recording: Off",
                    detail: "Saved \(summary.outputPath)",
                    outputPath: summary.outputPath
                )
            )
        } catch {
            stateLock.lock()
            if activeSession?.id == session.id {
                activeSession = nil
            }
            stateLock.unlock()

            publishStatus(
                LiveRecordingStatusSnapshot(
                    state: .error,
                    isRecording: false,
                    headline: "Recording: Error",
                    detail: error.localizedDescription,
                    outputPath: session.outputURL.path
                )
            )
        }
    }

    private func publishStatus(_ status: LiveRecordingStatusSnapshot) {
        stateLock.lock()
        latestStatus = status
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(status)
        }
    }

    private static func makeRecordingOutputURL() throws -> URL {
        let directory = recordingsDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let timestamp = recordingTimestampFormatter.string(from: Date())
        return directory.appendingPathComponent("live-recording-\(timestamp).mp4")
    }

    private static func recordingsDirectory() -> URL {
        let moviesDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        let baseDirectory = moviesDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return baseDirectory.appendingPathComponent("StreamOCR Recordings", isDirectory: true)
    }

    private static func writeMetadata(
        summary: LiveRecordingSummary,
        session: LiveManualRecordingSession,
        finishedAt: Date
    ) throws {
        let metadata = LiveManualRecordingMetadata(
            seedURL: session.seedURL.absoluteString,
            sourceURL: session.sourceURL.absoluteString,
            startedAt: isoTimestampFormatter.string(from: session.startedAt),
            finishedAt: isoTimestampFormatter.string(from: finishedAt),
            recording: summary
        )
        let metadataURL = session.outputURL
            .deletingPathExtension()
            .appendingPathExtension("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private static var recordingTimestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    private static var isoTimestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private struct LiveManualRecordingSession {
    let id: UUID
    let seedURL: URL
    let sourceURL: URL
    let outputURL: URL
    let recorder: LiveSourceStreamRecorder
    let startedAt: Date
}
