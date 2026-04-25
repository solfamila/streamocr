import Foundation

enum LiveSourceChunkCapturePolicy {
    static let lowLatencyCaptureWindowSeconds: TimeInterval = 0.5
    static let minimumPlayableProbeWindowSeconds: TimeInterval = 0.08
    static let playableProbeIntervalSeconds: TimeInterval = 0.04
    static let guiFallbackCaptureWindowSeconds: TimeInterval = 1.5
    static let analyzerFallbackCaptureWindowSeconds: TimeInterval = 2.0
}
