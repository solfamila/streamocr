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

        let recognitionEvents = eventCollector.events.filter { $0.kind == .recognition }
        let triggerEvents = eventCollector.events.filter { $0.kind == .trigger }
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
        let maxCount = max(expected.count, actual.count)

        for index in 0..<maxCount {
            let expectedEvent = expected.indices.contains(index) ? expected[index] : nil
            let actualEvent = actual.indices.contains(index) ? actual[index] : nil

            guard let expectedEvent, let actualEvent else {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: expectedEvent == nil ? "unexpected_actual_event" : "missing_actual_event",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let kind = expectedEvent.kind, kind != actualEvent.kind {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "kind_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let frameNumber = expectedEvent.frameNumber, frameNumber != actualEvent.frameNumber {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "frame_number_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let region = expectedEvent.region, region != actualEvent.region {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "region_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let action = expectedEvent.action, action != actualEvent.action {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "action_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let rawText = expectedEvent.rawText, rawText != actualEvent.rawText {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "raw_text_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let normalizedText = expectedEvent.normalizedText, normalizedText != actualEvent.normalizedText {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "normalized_text_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let symbol = expectedEvent.symbol, symbol != actualEvent.symbol {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "symbol_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let parsedInteger = expectedEvent.parsedInteger, parsedInteger != actualEvent.parsedInteger {
                mismatches.append(
                    OfflineVerificationMismatch(
                        index: index,
                        reason: "parsed_integer_mismatch",
                        expected: expectedEvent,
                        actual: actualEvent
                    )
                )
                continue
            }

            if let expectedPTS = expectedEvent.presentationTimeSeconds {
                let tolerance = max(0, expectedEvent.presentationTimeToleranceSeconds ?? 0.05)

                guard let actualPTS = actualEvent.presentationTimeSeconds else {
                    mismatches.append(
                        OfflineVerificationMismatch(
                            index: index,
                            reason: "missing_presentation_time",
                            expected: expectedEvent,
                            actual: actualEvent
                        )
                    )
                    continue
                }

                if abs(expectedPTS - actualPTS) > tolerance {
                    mismatches.append(
                        OfflineVerificationMismatch(
                            index: index,
                            reason: "presentation_time_mismatch",
                            expected: expectedEvent,
                            actual: actualEvent
                        )
                    )
                }
            }
        }

        return OfflineVerificationSectionReport(
            matched: mismatches.isEmpty,
            expectedCount: expected.count,
            actualCount: actual.count,
            mismatches: mismatches
        )
    }
}
