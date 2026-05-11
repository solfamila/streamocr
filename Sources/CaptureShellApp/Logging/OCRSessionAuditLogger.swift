import Foundation

final class OCRSessionAuditLogger: @unchecked Sendable {
    static let defaultLogDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/StreamOCR", isDirectory: true)

    let logURL: URL

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1
    private let encoder = JSONEncoder()
    private let timestampFormatter = ISO8601DateFormatter()
    private let fileHandle: FileHandle?
    private var sequence: UInt64 = 0

    init(
        logDirectory: URL = OCRSessionAuditLogger.defaultLogDirectory,
        deleteOldSessionLogs: Bool = true,
        fileManager: FileManager = .default,
        writerQueue: DispatchQueue? = nil
    ) {
        queue = writerQueue ?? DispatchQueue(label: "streamocr.ocr-audit-writer", qos: .utility)
        queue.setSpecific(key: queueKey, value: queueValue)
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

        logURL = logDirectory.appendingPathComponent("ocr-session-\(Self.fileTimestamp())-\(Self.shortUUID()).jsonl")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        recordLifecycle("session_started", message: "Started fresh OCR GUI audit session.")
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            writeSessionClosedRecord()
            try? fileHandle?.close()
        } else {
            queue.sync {
                writeSessionClosedRecord()
                try? fileHandle?.close()
            }
        }
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
        enqueue { timestamp, sequence in
            AuditRecord(
                sequence: sequence,
                timestamp: timestamp,
                source: "app",
                type: "lifecycle",
                action: action,
                message: message,
                logPath: self.logURL.path
            )
        }
    }

    func recordMessage(_ message: String, source: String) {
        enqueue { timestamp, sequence in
            AuditRecord(
                sequence: sequence,
                timestamp: timestamp,
                source: source,
                type: "message",
                message: message
            )
        }
    }

    func recordPipelineEvent(_ event: OCRPipelineEvent, source: String) {
        enqueue { timestamp, sequence in
            AuditRecord(
                sequence: sequence,
                timestamp: timestamp,
                source: source,
                type: "pipeline_event",
                pipelineEvent: PipelineEventRecord(event)
            )
        }
    }

    func recordFrameObservation(_ observation: OCRTradingFrameObservation, source: String) {
        enqueue { timestamp, sequence in
            AuditRecord(
                sequence: sequence,
                timestamp: timestamp,
                source: source,
                type: "frame_observation",
                frameObservation: FrameObservationRecord(observation)
            )
        }
    }

    func recordCommandAuditEvent(_ event: OCRTradingCommandAuditEvent, source: String) {
        enqueue { timestamp, sequence in
            AuditRecord(
                sequence: sequence,
                timestamp: timestamp,
                source: source,
                type: "command_event",
                commandEvent: CommandEventRecord(event)
            )
        }
    }

    func recordLiveStatus(_ status: LiveOCRSessionStatusSnapshot, source: String) {
        enqueue { timestamp, sequence in
            AuditRecord(
                sequence: sequence,
                timestamp: timestamp,
                source: source,
                type: "live_status",
                liveStatus: LiveStatusRecord(status)
            )
        }
    }

    @discardableResult
    func flush(timeout: TimeInterval) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    private func enqueue(_ makeRecord: @escaping @Sendable (_ timestamp: String, _ sequence: UInt64) -> AuditRecord) {
        guard let fileHandle else {
            return
        }

        queue.async { [self] in
            sequence &+= 1
            let record = makeRecord(timestampFormatter.string(from: Date()), sequence)
            write(record, to: fileHandle)
        }
    }

    private func write(_ record: AuditRecord, to fileHandle: FileHandle) {
        do {
            let data = try encoder.encode(record)
            fileHandle.write(data)
            fileHandle.write(Data([0x0A]))
        } catch {
            print("[ocr-audit] failed_to_write_record error=\(error.localizedDescription)")
        }
    }

    private func writeSessionClosedRecord() {
        guard let fileHandle else {
            return
        }

        sequence &+= 1
        write(
            AuditRecord(
                sequence: sequence,
                timestamp: timestampFormatter.string(from: Date()),
                source: "app",
                type: "lifecycle",
                action: "session_closed",
                message: "OCR GUI audit session closed.",
                logPath: logURL.path
            ),
            to: fileHandle
        )
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func shortUUID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

private struct AuditRecord: Encodable, Sendable {
    var sequence: UInt64
    var timestamp: String
    var source: String
    var type: String
    var action: String?
    var message: String?
    var logPath: String?
    var pipelineEvent: PipelineEventRecord?
    var frameObservation: FrameObservationRecord?
    var commandEvent: CommandEventRecord?
    var liveStatus: LiveStatusRecord?
}

private struct PipelineEventRecord: Encodable, Sendable {
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

private struct FrameObservationRecord: Encodable, Sendable {
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

private struct SymbolObservationRecord: Encodable, Sendable {
    var fingerprint: String?
    var recognitionState: String
    var recognition: TextObservationRecord?

    init(_ observation: OCRTradingSymbolObservation) {
        fingerprint = observation.fingerprint.map { String(format: "%016llx", $0) }
        recognitionState = observation.recognitionState.auditName
        recognition = observation.recognition.map(TextObservationRecord.init(_:))
    }
}

private struct ManualCellObservationRecord: Encodable, Sendable {
    var recognition: TextObservationRecord

    init(_ observation: OCRTradingManualCellObservation) {
        recognition = TextObservationRecord(observation.recognition)
    }
}

private struct TextObservationRecord: Encodable, Sendable {
    var rawText: String
    var normalizedText: String
    var confidence: Double

    init(_ observation: OCRTradingTextObservation) {
        rawText = observation.rawText
        normalizedText = observation.normalizedText
        confidence = observation.confidence
    }
}

private struct CommandEventRecord: Encodable, Sendable {
    var phase: String
    var commandID: UInt64
    var kind: String
    var symbol: String
    var symbolGeneration: UInt64
    var sessionGeneration: UInt64
    var originatingFrame: Int
    var originatingMediaTime: Double?
    var result: String?
    var reason: String?
    var ocrQuantity: Int?
    var submittedQuantity: Int?
    var previousOCRQuantity: Int?
    var currentOCRQuantity: Int?

    init(_ event: OCRTradingCommandAuditEvent) {
        phase = event.phase.rawValue
        commandID = event.command.id
        symbol = event.command.symbol
        symbolGeneration = event.command.symbolGeneration
        sessionGeneration = event.command.sessionGeneration
        originatingFrame = event.command.originatingFrame
        originatingMediaTime = event.command.originatingMediaTime
        result = event.result?.auditName
        reason = event.result?.resultDescription

        switch event.command.kind {
        case .subscribe:
            kind = "subscribe"
            ocrQuantity = nil
            submittedQuantity = nil
            previousOCRQuantity = nil
            currentOCRQuantity = nil
        case let .buy(ocrQuantity, submittedQuantity):
            kind = "buy"
            self.ocrQuantity = ocrQuantity
            self.submittedQuantity = submittedQuantity
            previousOCRQuantity = nil
            currentOCRQuantity = nil
        case let .sell(previousOCRQuantity, currentOCRQuantity):
            kind = "sell"
            ocrQuantity = nil
            submittedQuantity = nil
            self.previousOCRQuantity = previousOCRQuantity
            self.currentOCRQuantity = currentOCRQuantity
        }
    }
}

private struct LiveStatusRecord: Encodable, Sendable {
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

private extension OCRTradingCommandResult {
    var auditName: String {
        switch self {
        case .submitted:
            return "submitted"
        case .intentionallyIgnored:
            return "intentionally_ignored"
        case .retryableRejected:
            return "retryable_rejected"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        case .staleIgnored:
            return "stale_ignored"
        }
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
