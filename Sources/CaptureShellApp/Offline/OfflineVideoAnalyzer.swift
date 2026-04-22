import AVFoundation
import Foundation

enum OfflineVideoAnalyzerError: Error, LocalizedError {
    case missingVideoTrack(URL)
    case assetReaderUnavailable(URL)
    case assetReaderStartFailed(String)
    case assetReaderFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingVideoTrack(url):
            return "No video track found in \(url.path)."
        case let .assetReaderUnavailable(url):
            return "Unable to create an AVAssetReader for \(url.path)."
        case let .assetReaderStartFailed(message):
            return "Offline analyzer failed to start reading video frames: \(message)"
        case let .assetReaderFailed(message):
            return "Offline analyzer failed while decoding video frames: \(message)"
        }
    }
}

struct OfflineExpectedOCRPipelineEvent: Codable, Equatable, Sendable {
    var kind: OCRPipelineEventKind?
    var frameNumber: Int?
    var region: String?
    var action: String?
    var rawText: String?
    var normalizedText: String?
    var symbol: String?
    var parsedInteger: Int?
    var presentationTimeSeconds: Double?
    var presentationTimeToleranceSeconds: Double?
}

struct OfflineExpectedOutput: Codable, Equatable, Sendable {
    var recognitionEvents: [OfflineExpectedOCRPipelineEvent]?
    var triggerEvents: [OfflineExpectedOCRPipelineEvent]?
}

struct OfflineVerificationMismatch: Codable, Equatable, Sendable {
    let index: Int
    let reason: String
    let expected: OfflineExpectedOCRPipelineEvent?
    let actual: OCRPipelineEvent?
}

struct OfflineVerificationSectionReport: Codable, Equatable, Sendable {
    let matched: Bool
    let expectedCount: Int
    let actualCount: Int
    let mismatches: [OfflineVerificationMismatch]
}

struct OfflineVerificationReport: Codable, Equatable, Sendable {
    let matched: Bool
    let recognition: OfflineVerificationSectionReport?
    let trigger: OfflineVerificationSectionReport?
}

struct OfflineAnalysisResult: Codable, Equatable, Sendable {
    let videoPath: String
    let runtimeConfigPath: String
    let frameCount: Int
    let nominalFrameRate: Double?
    let frameSize: String
    let recognitionEvents: [OCRPipelineEvent]
    let triggerEvents: [OCRPipelineEvent]
    let verification: OfflineVerificationReport?
}

final class OfflineVideoAnalyzer {
    func analyze(
        videoURL: URL,
        runtimeConfigURL: URL,
        expectedOutputURL: URL? = nil,
        recognizer: any OCRTextRecognizing = FontTemplateTextRecognizer()
    ) throws -> OfflineAnalysisResult {
        let runtimeConfig = try RuntimeConfigFileIO.load(from: runtimeConfigURL)
        let asset = AVURLAsset(url: videoURL)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw OfflineVideoAnalyzerError.missingVideoTrack(videoURL)
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw OfflineVideoAnalyzerError.assetReaderUnavailable(videoURL)
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw OfflineVideoAnalyzerError.assetReaderUnavailable(videoURL)
        }

        reader.add(output)
        guard reader.startReading() else {
            let message = reader.error?.localizedDescription ?? "unknown error"
            throw OfflineVideoAnalyzerError.assetReaderStartFailed(message)
        }

        let eventCollector = PipelineEventCollector()
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            recognizer: recognizer,
            messageSender: DiscardingTradingMessageSender(),
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        let nominalFrameRate = videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : nil
        let adjustedRuntimeConfig = runtimeConfig.adjustedForFrameSize(
            width: Int(videoTrack.naturalSize.applying(videoTrack.preferredTransform).width.magnitude.rounded()),
            height: Int(videoTrack.naturalSize.applying(videoTrack.preferredTransform).height.magnitude.rounded())
        )

        var frameCount = 0
        var lastFrameSize = "unknown"

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let frame = VideoFrame(sampleBuffer: sampleBuffer, nominalFrameRate: nominalFrameRate) else {
                continue
            }

            frameCount += 1
            lastFrameSize = frame.sizeSummary
            pipeline.process(frame, runtimeConfig: adjustedRuntimeConfig)
        }

        if reader.status == .failed {
            let message = reader.error?.localizedDescription ?? "unknown decode error"
            throw OfflineVideoAnalyzerError.assetReaderFailed(message)
        }

        let allEvents = eventCollector.snapshot()
        let recognitionEvents = allEvents.filter { $0.kind == .recognition }
        let triggerEvents = allEvents.filter { $0.kind == .trigger }
        let verification = try expectedOutputURL.map {
            let expectedOutput = try OfflineExpectedOutputIO.load(from: $0)
            return OfflineVerificationEngine.verify(
                expected: expectedOutput,
                actualRecognitionEvents: recognitionEvents,
                actualTriggerEvents: triggerEvents
            )
        }

        return OfflineAnalysisResult(
            videoPath: videoURL.path,
            runtimeConfigPath: runtimeConfigURL.path,
            frameCount: frameCount,
            nominalFrameRate: nominalFrameRate,
            frameSize: lastFrameSize,
            recognitionEvents: recognitionEvents,
            triggerEvents: triggerEvents,
            verification: verification
        )
    }
}

final class PipelineEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [OCRPipelineEvent] = []

    func handle(_ event: OCRPipelineEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [OCRPipelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class DiscardingTradingMessageSender: TradingMessageSending, @unchecked Sendable {
    func send(
        _ payload: String,
        event _: String,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        _ = payload
        completion(.success(()))
    }
}

enum RuntimeConfigFileIO {
    static func load(from url: URL) throws -> CaptureRuntimeConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CaptureRuntimeConfig.self, from: data)
    }
}

private enum OfflineExpectedOutputIO {
    static func load(from url: URL) throws -> OfflineExpectedOutput {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OfflineExpectedOutput.self, from: data)
    }
}

enum OfflineVerificationEngine {
    static func verify(
        expected: OfflineExpectedOutput,
        actualRecognitionEvents: [OCRPipelineEvent],
        actualTriggerEvents: [OCRPipelineEvent]
    ) -> OfflineVerificationReport {
        let recognition = expected.recognitionEvents.map {
            verifySection(expected: $0, actual: actualRecognitionEvents)
        }
        let trigger = expected.triggerEvents.map {
            verifySection(expected: $0, actual: actualTriggerEvents)
        }

        return OfflineVerificationReport(
            matched: (recognition?.matched ?? true) && (trigger?.matched ?? true),
            recognition: recognition,
            trigger: trigger
        )
    }

    private static func verifySection(
        expected: [OfflineExpectedOCRPipelineEvent],
        actual: [OCRPipelineEvent]
    ) -> OfflineVerificationSectionReport {
        var mismatches: [OfflineVerificationMismatch] = []
        var searchStartIndex = 0

        for (expectedIndex, expectedEvent) in expected.enumerated() {
            var matchedActualIndex: Int?
            var firstMismatchActual: OCRPipelineEvent?
            var firstMismatchReason: String?

            for actualIndex in searchStartIndex..<actual.count {
                let actualEvent = actual[actualIndex]
                if let mismatchReason = mismatchReason(expected: expectedEvent, actual: actualEvent) {
                    if firstMismatchReason == nil {
                        firstMismatchReason = mismatchReason
                        firstMismatchActual = actualEvent
                    }
                    continue
                }

                matchedActualIndex = actualIndex
                break
            }

            guard let matchedActualIndex else {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: expectedIndex,
                        reason: firstMismatchReason ?? "missing_actual_event",
                        expected: expectedEvent,
                        actual: firstMismatchActual
                    )
                )
                continue
            }

            searchStartIndex = matchedActualIndex + 1
        }

        return OfflineVerificationSectionReport(
            matched: mismatches.isEmpty,
            expectedCount: expected.count,
            actualCount: actual.count,
            mismatches: mismatches
        )
    }

    private static func mismatchReason(
        expected: OfflineExpectedOCRPipelineEvent,
        actual: OCRPipelineEvent
    ) -> String? {
        if let kind = expected.kind, kind != actual.kind {
            return "kind_mismatch"
        }

        if let frameNumber = expected.frameNumber, frameNumber != actual.frameNumber {
            return "frame_number_mismatch"
        }

        if let region = expected.region, region != actual.region {
            return "region_mismatch"
        }

        if let action = expected.action, action != actual.action {
            return "action_mismatch"
        }

        if let rawText = expected.rawText, rawText != actual.rawText {
            return "raw_text_mismatch"
        }

        if let normalizedText = expected.normalizedText, normalizedText != actual.normalizedText {
            return "normalized_text_mismatch"
        }

        if let symbol = expected.symbol, symbol != actual.symbol {
            return "symbol_mismatch"
        }

        if let parsedInteger = expected.parsedInteger, parsedInteger != actual.parsedInteger {
            return "parsed_integer_mismatch"
        }

        if let expectedPTS = expected.presentationTimeSeconds {
            let tolerance = max(0, expected.presentationTimeToleranceSeconds ?? 0.05)
            guard let actualPTS = actual.presentationTimeSeconds else {
                return "missing_presentation_time"
            }
            if abs(expectedPTS - actualPTS) > tolerance {
                return "presentation_time_mismatch"
            }
        }

        return nil
    }
}
