import Foundation

struct LiveRecordingSummary: Codable, Equatable, Sendable {
    let outputPath: String
    let frameCount: Int
    let droppedFrameCount: Int
    let width: Int
    let height: Int
    let firstPresentationTimeSeconds: Double?
    let lastPresentationTimeSeconds: Double?
    let durationSeconds: Double?
    let fileSizeBytes: Int64?
}

struct LiveRunMetadata: Codable, Equatable, Sendable {
    let seedURL: String
    let playlistURL: String
    let playbackURL: String
    let streamURL: String
    let runtimeConfigPath: String?
    let requestedRunSeconds: Double
    let elapsedSeconds: Double
    let firstFrameLatencySeconds: Double?
    let activeDecodeSeconds: Double?
    let effectiveFrameRate: Double?
    let frameCount: Int
    let frameSize: String
    let recognitionEventCount: Int
    let triggerEventCount: Int
    let recording: LiveRecordingSummary?
}

enum LiveMetadataFileIO {
    static func save(_ metadata: LiveRunMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

