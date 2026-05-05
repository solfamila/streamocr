import Foundation

struct OCRRecognitionResult: Sendable {
    let rawText: String
    let normalizedText: String
    let confidence: Double
}

struct OCRRegionTracker: Sendable {
    var lastFingerprint: UInt64?
    var lastRecognition: OCRRecognitionResult?
    var unchangedStreak = 0

    mutating func markChanged(fingerprint: UInt64) {
        lastFingerprint = fingerprint
        lastRecognition = nil
        unchangedStreak = 0
    }

    mutating func markUnchanged() -> Int {
        unchangedStreak += 1
        return unchangedStreak
    }
}
