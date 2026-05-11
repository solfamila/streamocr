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

        let text = try String(contentsOf: logger.logURL, encoding: .utf8)
        #expect(text.contains(#""type":"pipeline_event""#))
        #expect(text.contains(#""symbol":"ODYS""#))
        #expect(text.contains(#""type":"frame_observation""#))
        #expect(text.contains(#""normalizedText":"LINK""#))
        #expect(text.contains(#""fingerprint":"0000000000001234""#))
    }
}
