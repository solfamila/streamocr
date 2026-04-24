import AVFoundation
import CoreGraphics
import CoreImage
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

private enum LiveStreamFrameSnapshotterDecodeStop: Error {
    case firstFrameCaptured
}

final class LiveStreamFrameSnapshotter {
    private let chunkPuller = NanocosmosStreamingChunkPuller()
    private let decoder = LocalVideoFrameDecoder()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

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

        var firstFrameImage: CGImage?
        do {
            _ = try decoder.decode(videoURL: capturedChunk.fileURL) { [ciContext] frame in
                let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
                guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
                    return
                }
                firstFrameImage = cgImage
                throw LiveStreamFrameSnapshotterDecodeStop.firstFrameCaptured
            }
        } catch LiveStreamFrameSnapshotterDecodeStop.firstFrameCaptured {
            // Expected early exit once we have the first decoded frame.
        }

        guard let cgImage = firstFrameImage else {
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
