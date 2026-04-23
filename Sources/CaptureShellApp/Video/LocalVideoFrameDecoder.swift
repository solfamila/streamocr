import AVFoundation
import CoreMedia
import Foundation

enum LocalVideoFrameDecoderError: Error, LocalizedError {
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
            return "Failed to start reading video frames: \(message)"
        case let .assetReaderFailed(message):
            return "Failed while decoding video frames: \(message)"
        }
    }
}

struct LocalVideoDecodingSummary: Sendable {
    let frameCount: Int
    let nominalFrameRate: Double?
    let width: Int
    let height: Int
    let firstPresentationTimeSeconds: Double?
    let lastPresentationTimeSeconds: Double?

    var frameSizeSummary: String {
        "\(width)x\(height)"
    }
}

final class LocalVideoFrameDecoder {
    func decode(
        videoURL: URL,
        presentationTimeOffsetSeconds: Double = 0,
        onFrame: (VideoFrame) throws -> Void
    ) throws -> LocalVideoDecodingSummary {
        let asset = AVURLAsset(url: videoURL)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw LocalVideoFrameDecoderError.missingVideoTrack(videoURL)
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw LocalVideoFrameDecoderError.assetReaderUnavailable(videoURL)
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw LocalVideoFrameDecoderError.assetReaderUnavailable(videoURL)
        }

        reader.add(output)
        guard reader.startReading() else {
            let message = reader.error?.localizedDescription ?? "unknown error"
            throw LocalVideoFrameDecoderError.assetReaderStartFailed(message)
        }

        let nominalFrameRate = videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : nil
        let naturalSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let width = Int(naturalSize.width.magnitude.rounded())
        let height = Int(naturalSize.height.magnitude.rounded())

        var frameCount = 0
        var firstPresentationTimeSeconds: Double?
        var lastPresentationTimeSeconds: Double?

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let samplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let samplePresentationSeconds = CMTimeGetSeconds(samplePresentationTime)
            let adjustedPresentationTimeStamp: CMTime? = if samplePresentationSeconds.isFinite {
                CMTime(
                    seconds: max(0, samplePresentationSeconds) + presentationTimeOffsetSeconds,
                    preferredTimescale: 60_000
                )
            } else {
                nil
            }

            let frame = VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: adjustedPresentationTimeStamp,
                nominalFrameRate: nominalFrameRate
            )

            try onFrame(frame)
            frameCount += 1

            if let presentationTimeSeconds = frame.presentationTimeSeconds {
                firstPresentationTimeSeconds = firstPresentationTimeSeconds ?? presentationTimeSeconds
                lastPresentationTimeSeconds = presentationTimeSeconds
            }
        }

        if reader.status == .failed {
            let message = reader.error?.localizedDescription ?? "unknown decode error"
            throw LocalVideoFrameDecoderError.assetReaderFailed(message)
        }

        return LocalVideoDecodingSummary(
            frameCount: frameCount,
            nominalFrameRate: nominalFrameRate,
            width: width,
            height: height,
            firstPresentationTimeSeconds: firstPresentationTimeSeconds,
            lastPresentationTimeSeconds: lastPresentationTimeSeconds
        )
    }
}
