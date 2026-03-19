import Foundation

enum OCRPipelineEventKind: String, Codable, Equatable, Sendable {
    case recognition
    case trigger
}

struct OCRPipelineEvent: Codable, Equatable, Sendable {
    let kind: OCRPipelineEventKind
    let frameNumber: Int
    let region: String
    let action: String
    let rawText: String
    let normalizedText: String
    let confidence: Double
    let symbol: String?
    let parsedInteger: Int?
    let isDuplicate: Bool?
    let isZeroOrEmpty: Bool?
    let presentationTimeSeconds: Double?
}

typealias OCRPipelineEventHandler = @Sendable (OCRPipelineEvent) -> Void
