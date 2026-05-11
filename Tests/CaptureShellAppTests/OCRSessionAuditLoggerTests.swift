import Foundation
import Testing
@testable import CaptureShellApp

struct OCRSessionAuditLoggerTests {
    @Test
    func loggerStartsFreshAndRecordsOCRHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldLog = directory.appendingPathComponent("ocr-session-old.jsonl")
        FileManager.default.createFile(atPath: oldLog.path, contents: Data("old\n".utf8))

        let logger = OCRSessionAuditLogger(logDirectory: directory, deleteOldSessionLogs: true)
        #expect(!FileManager.default.fileExists(atPath: oldLog.path))
        #expect(logger.logURL.lastPathComponent.contains("ocr-session-"))

        logger.recordPipelineEvent(
            OCRPipelineEvent(
                kind: .recognition,
                frameNumber: 42,
                region: OCRRegionKind.manualSymbolCell.rawValue,
                action: "ocr_changed",
                rawText: "ODYS",
                normalizedText: "ODYS",
                confidence: 0.97,
                symbol: "ODYS",
                parsedInteger: nil,
                isDuplicate: nil,
                isZeroOrEmpty: nil,
                presentationTimeSeconds: 12.5
            ),
            source: "live"
        )
        logger.recordFrameObservation(
            OCRTradingFrameObservation(
                frameNumber: 43,
                mediaTime: 12.533,
                symbol: OCRTradingSymbolObservation(
                    fingerprint: 0x1234,
                    recognition: OCRTradingTextObservation(rawText: "LINK", confidence: 0.93),
                    recognitionState: .recognized
                ),
                manualCell: OCRTradingManualCellObservation(rawText: "10000", confidence: 0.91)
            ),
            source: "live"
        )
        logger.recordCommandAuditEvent(
            OCRTradingCommandAuditEvent(
                phase: .completed,
                command: OCRTradingCommand(
                    id: 7,
                    kind: .buy(ocrQuantity: 10000, submittedQuantity: 5000),
                    symbol: "ODYS",
                    symbolGeneration: 3,
                    sessionGeneration: 2,
                    originatingFrame: 44,
                    originatingMediaTime: 12.566
                ),
                result: .submitted,
                coordinatorResult: .cancelled(reason: "Session stopped before completion.")
            ),
            source: "live"
        )

        #expect(logger.flush(timeout: 1))
        let text = try String(contentsOf: logger.logURL, encoding: .utf8)
        #expect(text.contains(#""type":"pipeline_event""#))
        #expect(text.contains(#""symbol":"ODYS""#))
        #expect(text.contains(#""type":"frame_observation""#))
        #expect(text.contains(#""normalizedText":"LINK""#))
        #expect(text.contains(#""fingerprint":"0000000000001234""#))
        #expect(text.contains(#""type":"command_event""#))
        #expect(text.contains(#""commandID":7"#))
        #expect(text.contains(#""symbolGeneration":3"#))
        #expect(text.contains(#""sessionGeneration":2"#))
        #expect(text.contains(#""result":"submitted""#))
        #expect(text.contains(#""coordinatorResult":"cancelled""#))
        #expect(text.contains(#""coordinatorReason":"Session stopped before completion.""#))
        #expect(text.contains(#""acceptedByCoordinator":false"#))
    }

    @Test
    func loggerUsesUniqueSessionFilenamesInsideTheSameSecond() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = OCRSessionAuditLogger(logDirectory: directory, deleteOldSessionLogs: false)
        let second = OCRSessionAuditLogger(logDirectory: directory, deleteOldSessionLogs: false)

        #expect(first.logURL != second.logURL)
        #expect(first.flush(timeout: 1))
        #expect(second.flush(timeout: 1))
    }
}
