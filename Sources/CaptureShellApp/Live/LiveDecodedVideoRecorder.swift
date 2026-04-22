import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct LiveDecodedRecordingSummary: Codable, Equatable, Sendable {
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
    let frameCount: Int
    let frameSize: String
    let recognitionEventCount: Int
    let triggerEventCount: Int
    let recording: LiveDecodedRecordingSummary?
}

enum LiveDecodedVideoRecorderError: Error, LocalizedError {
    case failedToCreateWriter(URL)
    case appendFailed(String)
    case finishFailed(String)

    var errorDescription: String? {
        switch self {
        case let .failedToCreateWriter(url):
            return "Unable to create an AVAssetWriter for \(url.path)."
        case let .appendFailed(message):
            return "Decoded live recording append failed: \(message)"
        case let .finishFailed(message):
            return "Decoded live recording finalize failed: \(message)"
        }
    }
}

final class LiveDecodedVideoRecorder {
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstSourceTime: CMTime?
    private var firstRecordedTime: CMTime?
    private var lastRecordedTime: CMTime?
    private var videoWidth = 0
    private var videoHeight = 0
    private var frameCount = 0
    private var droppedFrameCount = 0

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func append(_ frame: VideoFrame) throws {
        let recordedTime = recordingTime(for: frame)
        if writer == nil {
            try startWriter(for: frame)
        }

        guard
            let writer,
            let input,
            let pixelBufferAdaptor
        else {
            return
        }

        if let lastRecordedTime, CMTimeCompare(recordedTime, lastRecordedTime) <= 0 {
            droppedFrameCount += 1
            return
        }

        if writer.status == .failed {
            throw LiveDecodedVideoRecorderError.appendFailed(writer.error?.localizedDescription ?? "unknown writer error")
        }

        guard input.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            return
        }

        if writer.status == .unknown {
            guard writer.startWriting() else {
                throw LiveDecodedVideoRecorderError.appendFailed(writer.error?.localizedDescription ?? "startWriting returned false")
            }
            writer.startSession(atSourceTime: .zero)
        }

        guard pixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: recordedTime) else {
            throw LiveDecodedVideoRecorderError.appendFailed(writer.error?.localizedDescription ?? "pixel buffer append returned false")
        }

        frameCount += 1
        if firstRecordedTime == nil {
            firstRecordedTime = recordedTime
        }
        lastRecordedTime = recordedTime
    }

    func finish() throws -> LiveDecodedRecordingSummary? {
        guard let writer, let input else {
            return nil
        }

        if writer.status == .failed {
            throw LiveDecodedVideoRecorderError.finishFailed(writer.error?.localizedDescription ?? "writer failed before finish")
        }

        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 15)
        if writer.status == .failed {
            throw LiveDecodedVideoRecorderError.finishFailed(writer.error?.localizedDescription ?? "unknown writer error")
        }

        let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value
        let firstSeconds = firstRecordedTime.flatMap(seconds(for:))
        let lastSeconds = lastRecordedTime.flatMap(seconds(for:))
        let durationSeconds: Double?
        if let firstRecordedTime, let lastRecordedTime {
            let duration = CMTimeSubtract(lastRecordedTime, firstRecordedTime)
            durationSeconds = seconds(for: duration)
        } else {
            durationSeconds = nil
        }

        return LiveDecodedRecordingSummary(
            outputPath: outputURL.path,
            frameCount: frameCount,
            droppedFrameCount: droppedFrameCount,
            width: videoWidth,
            height: videoHeight,
            firstPresentationTimeSeconds: firstSeconds,
            lastPresentationTimeSeconds: lastSeconds,
            durationSeconds: durationSeconds,
            fileSizeBytes: fileSizeBytes
        )
    }

    private func startWriter(for frame: VideoFrame) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw LiveDecodedVideoRecorderError.failedToCreateWriter(outputURL)
        }

        videoWidth = frame.width
        videoHeight = frame.height

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: max(videoWidth * videoHeight * 6, 750_000),
            AVVideoExpectedSourceFrameRateKey: 60,
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw LiveDecodedVideoRecorderError.failedToCreateWriter(outputURL)
        }
        writer.add(input)

        self.writer = writer
        self.input = input
        self.pixelBufferAdaptor = pixelBufferAdaptor
    }

    private func recordingTime(for frame: VideoFrame) -> CMTime {
        if let sourceTime = frame.presentationTimeStamp, sourceTime.isNumeric {
            if firstSourceTime == nil {
                firstSourceTime = sourceTime
            }
            let relativeTime = CMTimeSubtract(sourceTime, firstSourceTime ?? sourceTime)
            if relativeTime.isNumeric, CMTimeCompare(relativeTime, .zero) >= 0 {
                return relativeTime
            }
        }

        let fallbackFrameIndex = max(frameCount + droppedFrameCount, 0)
        return CMTime(value: Int64(fallbackFrameIndex), timescale: 60)
    }

    private func seconds(for time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? max(0, seconds) : nil
    }
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
