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

protocol LiveSourceRecording: AnyObject, Sendable {
    func start(sourceURL: URL, runSeconds: Double) throws
    func stop()
    func finish(timeout: TimeInterval) throws -> LiveRecordingSummary?
}

extension LiveSourceStreamRecorder: LiveSourceRecording {}

final class LiveRecordingSessionController: @unchecked Sendable {
    var onStatusChanged: ((LiveRecordingStatusSnapshot) -> Void)?

    private let sourceURLResolver: @Sendable (URL) -> URL
    private let outputURLProvider: @Sendable () throws -> URL
    private let recorderFactory: @Sendable (URL, Bool) -> any LiveSourceRecording
    private let stateLock = NSLock()
    private var controllerState: RecordingControllerState = .idle
    private var latestStatus = LiveRecordingStatusSnapshot.off

    init(
        sourceURLResolver: @escaping @Sendable (URL) -> URL = {
            LiveMediaCaptureCoordinator.preferredRecordingSourceURL(seedURL: $0)
        },
        outputURLProvider: @escaping @Sendable () throws -> URL = {
            try LiveRecordingSessionController.makeRecordingOutputURL()
        },
        recorderFactory: @escaping @Sendable (URL, Bool) -> any LiveSourceRecording = { outputURL, loggingEnabled in
            LiveSourceStreamRecorder(outputURL: outputURL, loggingEnabled: loggingEnabled)
        }
    ) {
        self.sourceURLResolver = sourceURLResolver
        self.outputURLProvider = outputURLProvider
        self.recorderFactory = recorderFactory
    }

    func currentStatusSnapshot() -> LiveRecordingStatusSnapshot {
        stateLock.lock()
        let status = latestStatus
        stateLock.unlock()
        return status
    }

    func start(seedURLText: String, loggingEnabled: Bool = false) throws {
        let trimmed = seedURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seedURL = URL(string: trimmed), !trimmed.isEmpty else {
            let error = LiveRecordingSessionControllerError.invalidSeedURL(seedURLText)
            publishError(error, outputPath: nil)
            throw error
        }

        let sessionID = UUID()
        stateLock.lock()
        let canStart: Bool
        if case .idle = controllerState {
            controllerState = .starting(sessionID, stopRequested: false)
            canStart = true
        } else {
            canStart = false
        }
        stateLock.unlock()
        guard canStart else {
            throw LiveRecordingSessionControllerError.alreadyRecording
        }

        do {
            let sourceURL = sourceURLResolver(seedURL)
            guard NanocosmosStreamingChunkPuller.supports(sourceURL: sourceURL) else {
                throw LiveRecordingSessionControllerError.unsupportedSource(sourceURL)
            }

            let outputURL = try outputURLProvider()
            let recorder = recorderFactory(outputURL, loggingEnabled)
            let startedAt = Date()
            try recorder.start(
                sourceURL: sourceURL,
                runSeconds: 24 * 60 * 60
            )

            let session = LiveManualRecordingSession(
                id: sessionID,
                seedURL: seedURL,
                sourceURL: sourceURL,
                outputURL: outputURL,
                recorder: recorder,
                startedAt: startedAt
            )

            stateLock.lock()
            let shouldPublishRecording: Bool
            let shouldFinishImmediately: Bool
            if case let .starting(activeSessionID, stopRequested) = controllerState,
               activeSessionID == sessionID {
                if stopRequested {
                    controllerState = .stopping(session)
                    shouldPublishRecording = false
                    shouldFinishImmediately = true
                } else {
                    controllerState = .recording(session)
                    shouldPublishRecording = true
                    shouldFinishImmediately = false
                }
            } else {
                shouldPublishRecording = false
                shouldFinishImmediately = true
            }
            stateLock.unlock()

            if shouldFinishImmediately {
                if session.beginFinishing() {
                    publishStatus(stoppingStatus(for: session))
                    session.recorder.stop()
                    DispatchQueue.global(qos: .userInitiated).async { [weak self, session] in
                        _ = self?.finishStop(session: session, timeout: 20, shouldPublish: true)
                    }
                }
                return
            }

            guard shouldPublishRecording else {
                return
            }

            publishStatus(
                LiveRecordingStatusSnapshot(
                    state: .recording,
                    isRecording: true,
                    headline: "Recording: On",
                    detail: "Saving source MP4 to \(outputURL.path)",
                    outputPath: outputURL.path
                )
            )
        } catch {
            stateLock.lock()
            if case let .starting(activeSessionID, _) = controllerState,
               activeSessionID == sessionID {
                controllerState = .idle
            }
            stateLock.unlock()

            publishError(error, outputPath: nil)
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let sessionToStop: LiveManualRecordingSession?
        switch controllerState {
        case .recording(let session):
            controllerState = .stopping(session)
            sessionToStop = session
        case .stopping(let session):
            sessionToStop = nil
            let status = stoppingStatus(for: session)
            stateLock.unlock()
            publishStatus(status)
            return
        case .starting(let sessionID, _):
            controllerState = .starting(sessionID, stopRequested: true)
            sessionToStop = nil
            let status = LiveRecordingStatusSnapshot(
                state: .stopping,
                isRecording: false,
                headline: "Recording: Stopping",
                detail: "Waiting for the recording session to finish starting...",
                outputPath: nil
            )
            stateLock.unlock()
            publishStatus(status)
            return
        case .idle:
            sessionToStop = nil
            stateLock.unlock()
            publishStatus(.off)
            return
        }
        stateLock.unlock()

        guard let session = sessionToStop else {
            return
        }
        guard session.beginFinishing() else {
            return
        }
        publishStatus(stoppingStatus(for: session))
        session.recorder.stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, session] in
            _ = self?.finishStop(session: session, timeout: 20, shouldPublish: true)
        }
    }

    @discardableResult
    func stopAndFinishSynchronously(timeout: TimeInterval = 20) -> LiveRecordingStatusSnapshot {
        stateLock.lock()
        let sessionToFinish: LiveManualRecordingSession?
        let sessionToWait: LiveManualRecordingSession?
        switch controllerState {
        case .recording(let session):
            controllerState = .stopping(session)
            sessionToFinish = session
            sessionToWait = nil
        case .stopping(let session):
            sessionToFinish = nil
            sessionToWait = session
        case .starting(let sessionID, _):
            controllerState = .starting(sessionID, stopRequested: true)
            let status = LiveRecordingStatusSnapshot(
                state: .stopping,
                isRecording: false,
                headline: "Recording: Stopping",
                detail: "Waiting for the recording session to finish starting...",
                outputPath: latestStatus.outputPath
            )
            stateLock.unlock()
            publishStatus(status)
            return waitForStartingSessionToStop(sessionID: sessionID, timeout: timeout)
        case .idle:
            let status = latestStatus
            stateLock.unlock()
            return status
        }
        stateLock.unlock()

        if let session = sessionToFinish {
            return stopAndFinish(session: session, timeout: timeout)
        }

        if let session = sessionToWait {
            return stopAndFinish(session: session, timeout: timeout)
        }

        return currentStatusSnapshot()
    }

    private func waitForStartingSessionToStop(
        sessionID: UUID,
        timeout: TimeInterval
    ) -> LiveRecordingStatusSnapshot {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            stateLock.lock()
            let state = controllerState
            let currentStatus = latestStatus
            stateLock.unlock()

            switch state {
            case .starting(let activeSessionID, _) where activeSessionID == sessionID:
                let remainingSeconds = deadline.timeIntervalSinceNow
                guard remainingSeconds > 0 else {
                    let status = LiveRecordingStatusSnapshot(
                        state: .stopping,
                        isRecording: false,
                        headline: "Recording: Stopping",
                        detail: "Still waiting for recording startup to finish after \(timeout)s.",
                        outputPath: currentStatus.outputPath
                    )
                    publishStatus(status)
                    return status
                }
                Thread.sleep(forTimeInterval: min(0.01, remainingSeconds))

            case .recording(let session) where session.id == sessionID:
                stateLock.lock()
                if case .recording(let activeSession) = controllerState,
                   activeSession.id == sessionID {
                    controllerState = .stopping(activeSession)
                }
                stateLock.unlock()
                return stopAndFinish(session: session, timeout: max(0.01, deadline.timeIntervalSinceNow))

            case .stopping(let session) where session.id == sessionID:
                return stopAndFinish(session: session, timeout: max(0.01, deadline.timeIntervalSinceNow))

            default:
                return currentStatus
            }
        }
    }

    private func stopAndFinish(
        session: LiveManualRecordingSession,
        timeout: TimeInterval
    ) -> LiveRecordingStatusSnapshot {
        if session.beginFinishing() {
            publishStatus(stoppingStatus(for: session))
            session.recorder.stop()
            return finishStop(session: session, timeout: timeout, shouldPublish: true)
        }
        return waitForFinish(session: session, timeout: timeout)
    }

    @discardableResult
    private func finishStop(
        session: LiveManualRecordingSession,
        timeout: TimeInterval,
        shouldPublish: Bool
    ) -> LiveRecordingStatusSnapshot {
        let status: LiveRecordingStatusSnapshot
        do {
            guard let summary = try session.recorder.finish(timeout: timeout) else {
                throw LiveSourceStreamRecorderError.recordingFailed("missing_recording_file")
            }

            try Self.writeMetadata(
                summary: summary,
                session: session,
                finishedAt: Date()
            )

            status = LiveRecordingStatusSnapshot(
                state: .off,
                isRecording: false,
                headline: "Recording: Off",
                detail: "Saved \(summary.outputPath)",
                outputPath: summary.outputPath
            )
        } catch {
            status = LiveRecordingStatusSnapshot(
                state: .error,
                isRecording: false,
                headline: "Recording: Error",
                detail: error.localizedDescription,
                outputPath: session.outputURL.path
            )
        }

        stateLock.lock()
        if case .stopping(let activeSession) = controllerState,
           activeSession.id == session.id {
            controllerState = .idle
        }
        stateLock.unlock()

        session.completeFinish(status)
        if shouldPublish {
            publishStatus(status)
        }
        return status
    }

    private func waitForFinish(
        session: LiveManualRecordingSession,
        timeout: TimeInterval
    ) -> LiveRecordingStatusSnapshot {
        if let status = session.waitForFinish(timeout: timeout) {
            return status
        }

        let status = LiveRecordingStatusSnapshot(
            state: .stopping,
            isRecording: false,
            headline: "Recording: Stopping",
            detail: "Still finalizing \(session.outputURL.lastPathComponent) after \(timeout)s.",
            outputPath: session.outputURL.path
        )
        publishStatus(status)
        return status
    }

    private func publishStatus(_ status: LiveRecordingStatusSnapshot) {
        stateLock.lock()
        latestStatus = status
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(status)
        }
    }

    private func publishError(_ error: Error, outputPath: String?) {
        publishStatus(
            LiveRecordingStatusSnapshot(
                state: .error,
                isRecording: false,
                headline: "Recording: Error",
                detail: error.localizedDescription,
                outputPath: outputPath
            )
        )
    }

    private func stoppingStatus(for session: LiveManualRecordingSession) -> LiveRecordingStatusSnapshot {
        LiveRecordingStatusSnapshot(
            state: .stopping,
            isRecording: false,
            headline: "Recording: Stopping",
            detail: "Finalizing \(session.outputURL.lastPathComponent)...",
            outputPath: session.outputURL.path
        )
    }

    static func makeRecordingOutputURL(
        directory: URL = recordingsDirectory(),
        date: Date = Date(),
        uniqueID: UUID = UUID()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let timestamp = recordingTimestampFormatter.string(from: date)
        let suffix = String(uniqueID.uuidString.prefix(8)).lowercased()
        return directory.appendingPathComponent("live-recording-\(timestamp)-\(suffix).mp4")
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

private enum RecordingControllerState {
    case idle
    case starting(UUID, stopRequested: Bool)
    case recording(LiveManualRecordingSession)
    case stopping(LiveManualRecordingSession)
}

private final class LiveManualRecordingSession: @unchecked Sendable {
    let id: UUID
    let seedURL: URL
    let sourceURL: URL
    let outputURL: URL
    let recorder: any LiveSourceRecording
    let startedAt: Date

    private let finishCondition = NSCondition()
    private var isFinishing = false
    private var finishStatus: LiveRecordingStatusSnapshot?

    init(
        id: UUID,
        seedURL: URL,
        sourceURL: URL,
        outputURL: URL,
        recorder: any LiveSourceRecording,
        startedAt: Date
    ) {
        self.id = id
        self.seedURL = seedURL
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.recorder = recorder
        self.startedAt = startedAt
    }

    @discardableResult
    func beginFinishing() -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }

        guard !isFinishing else {
            return false
        }

        isFinishing = true
        return true
    }

    func completeFinish(_ status: LiveRecordingStatusSnapshot) {
        finishCondition.lock()
        finishStatus = status
        finishCondition.broadcast()
        finishCondition.unlock()
    }

    func waitForFinish(timeout: TimeInterval) -> LiveRecordingStatusSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        finishCondition.lock()
        defer { finishCondition.unlock() }

        while finishStatus == nil {
            guard finishCondition.wait(until: deadline) else {
                break
            }
        }

        return finishStatus
    }
}
