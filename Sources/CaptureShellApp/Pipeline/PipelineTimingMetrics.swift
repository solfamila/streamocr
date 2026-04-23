import Foundation

struct CollectedOCRPipelineEvent: Equatable, Sendable {
    let event: OCRPipelineEvent
    let analysisTimeSeconds: Double
}

struct BuySignalTiming: Codable, Equatable, Sendable {
    let frameNumber: Int
    let analysisTimeSeconds: Double
    let presentationTimeSeconds: Double?
    let rawText: String
    let normalizedText: String
    let parsedInteger: Int?
}

struct TriggerPathTimingSample: Equatable, Sendable {
    let frameIngressToRegionMilliseconds: Double
    let preprocessMilliseconds: Double
    let cropMilliseconds: Double
    let metalMilliseconds: Double
    let fingerprintMilliseconds: Double
    let gatingMilliseconds: Double
    let ocrMilliseconds: Double
    let triggerEvaluationMilliseconds: Double
    let decisionMilliseconds: Double
    let transportCompletionMilliseconds: Double
    let ocrToCompletionMilliseconds: Double
    let totalEndToEndMilliseconds: Double
    let succeeded: Bool
}

struct TriggerPathTimingSummary: Equatable, Sendable {
    let sampleCount: Int
    let successCount: Int
    let failureCount: Int
    let averageFrameIngressToRegionMilliseconds: Double
    let averagePreprocessMilliseconds: Double
    let averageOCRMilliseconds: Double
    let averageTriggerEvaluationMilliseconds: Double
    let averageDecisionMilliseconds: Double
    let averageTransportCompletionMilliseconds: Double
    let averageOCRToCompletionMilliseconds: Double
    let averageTotalEndToEndMilliseconds: Double
    let maximumTotalEndToEndMilliseconds: Double
}

enum PipelineTimingMetrics {
    static func buySignalTimings(from collectedEvents: [CollectedOCRPipelineEvent]) -> [BuySignalTiming] {
        collectedEvents.compactMap { collectedEvent in
            let event = collectedEvent.event
            guard event.kind == .trigger, event.action == "buy_triggered" else {
                return nil
            }

            return BuySignalTiming(
                frameNumber: event.frameNumber,
                analysisTimeSeconds: collectedEvent.analysisTimeSeconds,
                presentationTimeSeconds: event.presentationTimeSeconds,
                rawText: event.rawText,
                normalizedText: event.normalizedText,
                parsedInteger: event.parsedInteger
            )
        }
    }

    static func summarizeTriggerPathSamples(_ samples: [TriggerPathTimingSample]) -> TriggerPathTimingSummary? {
        guard !samples.isEmpty else {
            return nil
        }

        func average(_ keyPath: KeyPath<TriggerPathTimingSample, Double>) -> Double {
            samples.reduce(0) { $0 + $1[keyPath: keyPath] } / Double(samples.count)
        }

        let successCount = samples.reduce(0) { $0 + ($1.succeeded ? 1 : 0) }
        let failureCount = samples.count - successCount
        let maxTotalEndToEndMilliseconds = samples.reduce(0) {
            max($0, $1.totalEndToEndMilliseconds)
        }

        return TriggerPathTimingSummary(
            sampleCount: samples.count,
            successCount: successCount,
            failureCount: failureCount,
            averageFrameIngressToRegionMilliseconds: average(\.frameIngressToRegionMilliseconds),
            averagePreprocessMilliseconds: average(\.preprocessMilliseconds),
            averageOCRMilliseconds: average(\.ocrMilliseconds),
            averageTriggerEvaluationMilliseconds: average(\.triggerEvaluationMilliseconds),
            averageDecisionMilliseconds: average(\.decisionMilliseconds),
            averageTransportCompletionMilliseconds: average(\.transportCompletionMilliseconds),
            averageOCRToCompletionMilliseconds: average(\.ocrToCompletionMilliseconds),
            averageTotalEndToEndMilliseconds: average(\.totalEndToEndMilliseconds),
            maximumTotalEndToEndMilliseconds: maxTotalEndToEndMilliseconds
        )
    }
}
