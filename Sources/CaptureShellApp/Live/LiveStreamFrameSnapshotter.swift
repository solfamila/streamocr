import AVFoundation
import CoreGraphics
import Foundation

struct LiveStreamFrameSnapshot {
    let cgImage: CGImage
    let width: Int
    let height: Int
    let sourceURL: URL
}

enum LiveStreamFrameSnapshotterError: Error, LocalizedError {
    case unsupportedSource(URL)
    case unableToRenderFrame(URL)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSource(url):
            return "This live source is not supported for ROI snapshot capture: \(url.absoluteString)"
        case let .unableToRenderFrame(url):
            return "Unable to decode a frame snapshot from \(url.absoluteString)"
        }
    }
}

final class LiveStreamFrameSnapshotter {
    private let chunkPuller = NanocosmosStreamingChunkPuller()

    func captureSnapshot(seedURL: URL) throws -> LiveStreamFrameSnapshot {
        let resolved = try NanocosmosStreamResolver.resolve(seedURL: seedURL)
        let sourceURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(
            seedURL: seedURL,
            resolved: resolved
        )

        guard NanocosmosStreamingChunkPuller.supports(sourceURL: sourceURL) else {
            throw LiveStreamFrameSnapshotterError.unsupportedSource(sourceURL)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureShellApp-live-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let chunkURL = temporaryDirectory.appendingPathComponent("snapshot.mp4")
        let capturedChunk = try chunkPuller.captureChunk(
            sourceURL: sourceURL,
            destinationURL: chunkURL,
            firstByteTimeoutSeconds: 8,
            captureWindowSeconds: 1.2
        )

        let asset = AVURLAsset(url: capturedChunk.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        let frameTime = CMTime(seconds: 0.0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: frameTime, actualTime: nil) else {
            throw LiveStreamFrameSnapshotterError.unableToRenderFrame(sourceURL)
        }

        return LiveStreamFrameSnapshot(
            cgImage: cgImage,
            width: cgImage.width,
            height: cgImage.height,
            sourceURL: capturedChunk.sourceURL
        )
    }
}
