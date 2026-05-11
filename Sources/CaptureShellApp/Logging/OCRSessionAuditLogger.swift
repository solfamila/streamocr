import Foundation

final class OCRSessionAuditLogger: @unchecked Sendable {
    static let defaultLogDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/StreamOCR", isDirectory: true)

    let logURL: URL

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let timestampFormatter = ISO8601DateFormatter()
    private let fileHandle: FileHandle?

    init(
        logDirectory: URL = OCRSessionAuditLogger.defaultLogDirectory,
        deleteOldSessionLogs: Bool = true,
        fileManager: FileManager = .default
    ) {
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.outputFormatting = [.sortedKeys]

        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if deleteOldSessionLogs {
                Self.deleteOldSessionLogs(in: logDirectory, fileManager: fileManager)
            }
        } catch {
            print("[ocr-audit] failed_to_prepare_log_directory path=\(logDirectory.path) error=\(error.localizedDescription)")
        }

        logURL = logDirectory.appendingPathComponent("ocr-session-\(Self.fileTimestamp()).jsonl")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        recordLifecycle("session_started", message: "Started fresh OCR GUI audit session.")
    }

    deinit {
        recordLifecycle("session_closed", message: "OCR GUI audit session closed.")
        try? fileHandle?.close()
    }

    @discardableResult
    static func deleteOldSessionLogs(
        in directory: URL = OCRSessionAuditLogger.defaultLogDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var deletedCount = 0
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("ocr-session-"), name.hasSuffix(".jsonl") else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                deletedCount += 1
            } catch {
                print("[ocr-audit] failed_to_delete_old_log path=\(url.path) error=\(error.localizedDescription)")
            }
        }
        return deletedCount
    }

    func recordLifecycle(_ action: String, message: String? = nil) {
        write(AuditRecord(
            timestamp: timestamp(),
            source: "app",
            type: "lifecycle",
            action: action,
            message: message,
            logPath: logURL.path
        ))
    }

    func recordMessage(_ message: String, source: String) {
        write(AuditRecord(
            timestamp: timestamp(),
            source: source,
            type: "message",
            message: message
        ))
    }

    func recordPipelineEvent(_ event: OCRPipelineEvent, source: String) {
        write(AuditRecord(
            timestamp: timestamp(),
            source: source,
            type: "pipeline_event",
            pipelineEvent: PipelineEventRecord(event)
        ))
    }

    func recordFrameObservation(_ observation: OCRTradingFrameObservation, source: String) {
        write(AuditRecord(
            timestamp: timestamp(),
            source: source,
            type: "frame_observation",
            frameObservation: FrameObservationRecord(observation)
        ))
    }

    func recordLiveStatus(_ status: LiveOCRSessionStatusSnapshot, source: String) {
        write(AuditRecord(
            timestamp: timestamp(),
            source: source,
            type: "live_status",
            liveStatus: LiveStatusRecord(status)
        ))
    }

    private func timestamp() -> String {
        lock.lock()
        defer { lock.unlock() }
        return timestampFormatter.string(from: Date())
    }

    private func write(_ record: AuditRecord) {
        guard let fileHandle else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try encoder.encode(record)
            fileHandle.write(data)
            fileHandle.write(Data([0x0A]))
        } catch {
            print("[ocr-audit] failed_to_write_record error=\(error.localizedDescription)")
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct AuditRecord: Encodable {
    var timestamp: String
    var source: String
    var type: String
    var action: String?
    var message: String?
    var logPath: String?
    var pipelineEvent: PipelineEventRecord?
    var frameObservation: FrameObservationRecord?
    var liveStatus: LiveStatusRecord?
}

private struct PipelineEventRecord: Encodable {
    var kind: String
    var frameNumber: Int
    var region: String
    var action: String
    var rawText: String
    var normalizedText: String
    var confidence: Double
    var symbol: String?
    var parsedInteger: Int?
    var isDuplicate: Bool?
    var isZeroOrEmpty: Bool?
    var presentationTimeSeconds: Double?

    init(_ event: OCRPipelineEvent) {
        kind = event.kind.rawValue
        frameNumber = event.frameNumber
        region = event.region
        action = event.action
        rawText = event.rawText
        normalizedText = event.normalizedText
        confidence = event.confidence
        symbol = event.symbol
        parsedInteger = event.parsedInteger
        isDuplicate = event.isDuplicate
        isZeroOrEmpty = event.isZeroOrEmpty
        presentationTimeSeconds = event.presentationTimeSeconds
    }
}

private struct FrameObservationRecord: Encodable {
    var frameNumber: Int
    var mediaTime: Double?
    var symbol: SymbolObservationRecord?
    var manualCell: ManualCellObservationRecord?

    init(_ observation: OCRTradingFrameObservation) {
        frameNumber = observation.frameNumber
        mediaTime = observation.mediaTime
        symbol = observation.symbol.map(SymbolObservationRecord.init(_:))
        manualCell = observation.manualCell.map(ManualCellObservationRecord.init(_:))
    }
}

private struct SymbolObservationRecord: Encodable {
    var fingerprint: String?
    var recognitionState: String
    var recognition: TextObservationRecord?

    init(_ observation: OCRTradingSymbolObservation) {
        fingerprint = observation.fingerprint.map { String(format: "%016llx", $0) }
        recognitionState = observation.recognitionState.auditName
        recognition = observation.recognition.map(TextObservationRecord.init(_:))
    }
}

private struct ManualCellObservationRecord: Encodable {
    var recognition: TextObservationRecord

    init(_ observation: OCRTradingManualCellObservation) {
        recognition = TextObservationRecord(observation.recognition)
    }
}

private struct TextObservationRecord: Encodable {
    var rawText: String
    var normalizedText: String
    var confidence: Double

    init(_ observation: OCRTradingTextObservation) {
        rawText = observation.rawText
        normalizedText = observation.normalizedText
        confidence = observation.confidence
    }
}

private struct LiveStatusRecord: Encodable {
    var state: String
    var isRunning: Bool
    var seedURLText: String
    var headline: String
    var detail: String
    var fps: Double?
    var frameSize: String?
    var lastSubscribedSymbol: String?
    var hasPositionROI: Bool
    var hasSymbolROI: Bool

    init(_ status: LiveOCRSessionStatusSnapshot) {
        state = status.state.rawValue
        isRunning = status.isRunning
        seedURLText = status.seedURLText
        headline = status.headline
        detail = status.detail
        fps = status.fps
        frameSize = status.frameSize
        lastSubscribedSymbol = status.lastSubscribedSymbol
        hasPositionROI = status.hasPositionROI
        hasSymbolROI = status.hasSymbolROI
    }
}

private extension OCRTradingRecognitionState {
    var auditName: String {
        switch self {
        case .notConfigured:
            return "not_configured"
        case .unchanged:
            return "unchanged"
        case .changedFingerprintPendingOCR:
            return "changed_fingerprint_pending_ocr"
        case .ocrPending:
            return "ocr_pending"
        case .recognized:
            return "recognized"
        }
    }
}
