import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

enum LiveStreamAnalyzerError: Error, LocalizedError {
    case playerFailed(String)
    case timedOutWaitingForPlayback(URL)
    case noFramesDecoded(URL)

    var errorDescription: String? {
        switch self {
        case let .playerFailed(message):
            return "Live stream player failed: \(message)"
        case let .timedOutWaitingForPlayback(url):
            return "Timed out waiting for live stream playback to become ready: \(url.absoluteString)"
        case let .noFramesDecoded(url):
            return "Live stream connected but no video frames were decoded: \(url.absoluteString)"
        }
    }
}

struct LiveStreamAnalysisResult: Codable, Equatable, Sendable {
    let seedURL: String
    let playlistURL: String
    let playbackURL: String
    let streamURL: String
    let runtimeConfigPath: String?
    let metadataPath: String?
    let requestedRunSeconds: Double
    let elapsedSeconds: Double
    let firstFrameLatencySeconds: Double?
    let activeDecodeSeconds: Double?
    let effectiveFrameRate: Double?
    let frameCount: Int
    let frameSize: String
    let recording: LiveRecordingSummary?
    let recognitionEvents: [OCRPipelineEvent]
    let triggerEvents: [OCRPipelineEvent]
}

final class LiveStreamAnalyzer {
    func analyze(
        seedURL: URL,
        runtimeConfigURL: URL?,
        runSeconds: Double,
        pollFPS: Double = 60,
        loggingEnabled: Bool = false,
        recordVideoURL: URL? = nil,
        recordAudio: Bool = false,
        metadataURL: URL? = nil,
        resolverTimeoutSeconds: TimeInterval = 10
    ) throws -> LiveStreamAnalysisResult {
        let start = Date()
        let runDeadline = start.addingTimeInterval(max(0.1, runSeconds))
        let pollInterval = 1 / max(1, pollFPS)
        let runtimeConfig = try runtimeConfigURL.map { try RuntimeConfigFileIO.load(from: $0) }
        let eventCollector = PipelineEventCollector()
        let messageSender: any TradingMessageSending = DiscardingTradingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: loggingEnabled,
            recognizer: FontTemplateTextRecognizer(),
            messageSender: messageSender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        var frameCount = 0
        var frameSize = "unknown"
        var firstFrameLatencySeconds: Double?
        var activeDecodeSeconds: Double?
        var adjustedConfigByFrameSize: [String: CaptureRuntimeConfig] = [:]
        var lastResolved: ResolvedLiveStream?
        var lastPlaybackURL: URL?
        let directPlaybackCandidates = LiveFFmpegVideoDecoder.preferredDirectSourceURLs(seedURL: seedURL)
        let captureCoordinator = recordVideoURL.map {
            LiveMediaCaptureCoordinator(
                outputURL: $0,
                includeAudio: recordAudio,
                loggingEnabled: loggingEnabled,
                runSeconds: runSeconds
            )
        }

        while Date() < runDeadline {
            do {
                try captureCoordinator?.ensureRecordingStarted(
                    seedURL: seedURL,
                    remainingSeconds: runDeadline.timeIntervalSinceNow
                )

                let sessionResult = try decodeFFmpegCandidates(
                    directPlaybackCandidates,
                    runtimeConfig: runtimeConfig,
                    pipeline: pipeline,
                    captureCoordinator: captureCoordinator,
                    runDeadline: runDeadline,
                    analysisStart: start,
                    loggingEnabled: loggingEnabled,
                    frameCount: &frameCount,
                    frameSize: &frameSize,
                    firstFrameLatencySeconds: &firstFrameLatencySeconds,
                    activeDecodeSeconds: &activeDecodeSeconds,
                    adjustedConfigByFrameSize: &adjustedConfigByFrameSize
                )
                lastPlaybackURL = sessionResult.playbackURL

                if loggingEnabled, sessionResult.decodedFrameCount > 0, Date() < runDeadline {
                    print("[live] reconnecting after decoded_frames=\(sessionResult.decodedFrameCount)")
                }
            } catch {
                do {
                    let resolved = try NanocosmosStreamResolver.resolve(
                        seedURL: seedURL,
                        timeoutSeconds: resolverTimeoutSeconds
                    )
                    lastResolved = resolved
                    try captureCoordinator?.ensureRecordingStarted(
                        seedURL: seedURL,
                        remainingSeconds: runDeadline.timeIntervalSinceNow,
                        resolved: resolved
                    )

                    let sessionResult = try decodeSession(
                        resolved: resolved,
                        runtimeConfig: runtimeConfig,
                        pipeline: pipeline,
                        captureCoordinator: captureCoordinator,
                        runDeadline: runDeadline,
                        pollInterval: pollInterval,
                        analysisStart: start,
                        loggingEnabled: loggingEnabled,
                        frameCount: &frameCount,
                        frameSize: &frameSize,
                        firstFrameLatencySeconds: &firstFrameLatencySeconds,
                        activeDecodeSeconds: &activeDecodeSeconds,
                        adjustedConfigByFrameSize: &adjustedConfigByFrameSize
                    )
                    lastPlaybackURL = sessionResult.playbackURL

                    if loggingEnabled, sessionResult.decodedFrameCount > 0, Date() < runDeadline {
                        print("[live] reconnecting after decoded_frames=\(sessionResult.decodedFrameCount)")
                    }
                } catch {
                    if frameCount > 0 {
                        if loggingEnabled {
                            print("[live] stopping after partial decode due_to=\"\(error.localizedDescription)\"")
                        }
                        break
                    }
                    throw error
                }
            }

            if Date() < runDeadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        if lastResolved == nil {
            lastResolved = try? NanocosmosStreamResolver.resolve(
                seedURL: seedURL,
                timeoutSeconds: min(resolverTimeoutSeconds, 3)
            )
        }

        let resolvedForResult = lastResolved
        guard frameCount > 0 else {
            throw LiveStreamAnalyzerError.noFramesDecoded(lastPlaybackURL ?? resolvedForResult?.playbackURL ?? seedURL)
        }

        let didFlushPendingMessages = messageSender.waitForPendingMessages(timeout: 2)
        if loggingEnabled, !didFlushPendingMessages {
            print("[live] timed_out_waiting_for_transport_callbacks timeout_seconds=2.00")
        }

        let allEvents = eventCollector.snapshot()
        let recognitionEvents = allEvents.filter { $0.kind == .recognition }
        let triggerEvents = allEvents.filter { $0.kind == .trigger }
        let recording = try captureCoordinator?.finish()
        let playbackURL = (lastPlaybackURL ?? resolvedForResult?.playbackURL)?.absoluteString ?? ""
        let metadataPath = metadataURL?.path
        let elapsedSeconds = Date().timeIntervalSince(start)
        let effectiveFrameRate = Self.effectiveFrameRate(frameCount: frameCount, activeDecodeSeconds: activeDecodeSeconds)
        let metadata = LiveRunMetadata(
            seedURL: (resolvedForResult?.seedURL ?? seedURL).absoluteString,
            playlistURL: resolvedForResult?.playlistURL.absoluteString ?? "",
            playbackURL: playbackURL,
            streamURL: resolvedForResult?.streamURL.absoluteString ?? "",
            runtimeConfigPath: runtimeConfigURL?.path,
            requestedRunSeconds: runSeconds,
            elapsedSeconds: elapsedSeconds,
            firstFrameLatencySeconds: firstFrameLatencySeconds,
            activeDecodeSeconds: activeDecodeSeconds,
            effectiveFrameRate: effectiveFrameRate,
            frameCount: frameCount,
            frameSize: frameSize,
            recognitionEventCount: recognitionEvents.count,
            triggerEventCount: triggerEvents.count,
            recording: recording
        )
        if let metadataURL {
            try LiveMetadataFileIO.save(metadata, to: metadataURL)
        }

        return LiveStreamAnalysisResult(
            seedURL: (resolvedForResult?.seedURL ?? seedURL).absoluteString,
            playlistURL: resolvedForResult?.playlistURL.absoluteString ?? "",
            playbackURL: playbackURL,
            streamURL: resolvedForResult?.streamURL.absoluteString ?? "",
            runtimeConfigPath: runtimeConfigURL?.path,
            metadataPath: metadataPath,
            requestedRunSeconds: runSeconds,
            elapsedSeconds: elapsedSeconds,
            firstFrameLatencySeconds: firstFrameLatencySeconds,
            activeDecodeSeconds: activeDecodeSeconds,
            effectiveFrameRate: effectiveFrameRate,
            frameCount: frameCount,
            frameSize: frameSize,
            recording: recording,
            recognitionEvents: recognitionEvents,
            triggerEvents: triggerEvents
        )
    }

    private func decodeFFmpegCandidates(
        _ playbackCandidates: [URL],
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        runDeadline: Date,
        analysisStart: Date,
        loggingEnabled: Bool,
        frameCount: inout Int,
        frameSize: inout String,
        firstFrameLatencySeconds: inout Double?,
        activeDecodeSeconds: inout Double?,
        adjustedConfigByFrameSize: inout [String: CaptureRuntimeConfig]
    ) throws -> DecodeSessionResult {
        var failures: [String] = []

        for sourceURL in playbackCandidates {
            do {
                let decoder = LiveFFmpegVideoDecoder(
                    sourceURL: sourceURL,
                    loggingEnabled: loggingEnabled
                )
                let stats = try decoder.decode(until: runDeadline) { frame in
                    try processDecodedFrame(
                        frame,
                        runtimeConfig: runtimeConfig,
                        pipeline: pipeline,
                        captureCoordinator: captureCoordinator,
                        analysisStart: analysisStart,
                        loggingEnabled: loggingEnabled,
                        frameCount: &frameCount,
                        frameSize: &frameSize,
                        firstFrameLatencySeconds: &firstFrameLatencySeconds,
                        activeDecodeSeconds: &activeDecodeSeconds,
                        adjustedConfigByFrameSize: &adjustedConfigByFrameSize
                    )
                }
                if stats.frameCount > 0 {
                    return DecodeSessionResult(decodedFrameCount: stats.frameCount, playbackURL: sourceURL)
                }
                failures.append("\(sourceURL.absoluteString): no frames decoded")
            } catch {
                failures.append("\(sourceURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw LiveStreamAnalyzerError.playerFailed(failures.joined(separator: " | "))
    }

    private func decodeSession(
        resolved: ResolvedLiveStream,
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        runDeadline: Date,
        pollInterval: TimeInterval,
        analysisStart: Date,
        loggingEnabled: Bool,
        frameCount: inout Int,
        frameSize: inout String,
        firstFrameLatencySeconds: inout Double?,
        activeDecodeSeconds: inout Double?,
        adjustedConfigByFrameSize: inout [String: CaptureRuntimeConfig]
    ) throws -> DecodeSessionResult {
        var failures: [String] = []

        let ffmpegCandidates = LiveFFmpegVideoDecoder.preferredSourceURLs(
            seedURL: resolved.seedURL,
            resolved: resolved
        )
        for sourceURL in ffmpegCandidates {
            do {
                let decoder = LiveFFmpegVideoDecoder(
                    sourceURL: sourceURL,
                    loggingEnabled: loggingEnabled
                )
                let stats = try decoder.decode(until: runDeadline) { frame in
                    try processDecodedFrame(
                        frame,
                        runtimeConfig: runtimeConfig,
                        pipeline: pipeline,
                        captureCoordinator: captureCoordinator,
                        analysisStart: analysisStart,
                        loggingEnabled: loggingEnabled,
                        frameCount: &frameCount,
                        frameSize: &frameSize,
                        firstFrameLatencySeconds: &firstFrameLatencySeconds,
                        activeDecodeSeconds: &activeDecodeSeconds,
                        adjustedConfigByFrameSize: &adjustedConfigByFrameSize
                    )
                }
                if stats.frameCount > 0 {
                    return DecodeSessionResult(decodedFrameCount: stats.frameCount, playbackURL: sourceURL)
                }
                failures.append("\(sourceURL.absoluteString): no frames decoded")
            } catch {
                failures.append("\(sourceURL.absoluteString): \(error.localizedDescription)")
            }
        }

        let playbackCandidates = [resolved.playbackURL] + resolved.alternatePlaybackURLs
        for playbackURL in playbackCandidates {
            do {
                let decodedFrameCount = try decodeAVPlayerPlaybackSession(
                    playbackURL: playbackURL,
                    resolved: resolved,
                    runtimeConfig: runtimeConfig,
                    pipeline: pipeline,
                    captureCoordinator: captureCoordinator,
                    runDeadline: runDeadline,
                    pollInterval: pollInterval,
                    analysisStart: analysisStart,
                    loggingEnabled: loggingEnabled,
                    frameCount: &frameCount,
                    frameSize: &frameSize,
                    firstFrameLatencySeconds: &firstFrameLatencySeconds,
                    activeDecodeSeconds: &activeDecodeSeconds,
                    adjustedConfigByFrameSize: &adjustedConfigByFrameSize
                )
                if decodedFrameCount > 0 {
                    return DecodeSessionResult(decodedFrameCount: decodedFrameCount, playbackURL: playbackURL)
                }
                failures.append("\(playbackURL.absoluteString): no frames decoded")
            } catch {
                failures.append("\(playbackURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw LiveStreamAnalyzerError.playerFailed(failures.joined(separator: " | "))
    }

    private func decodeAVPlayerPlaybackSession(
        playbackURL: URL,
        resolved _: ResolvedLiveStream,
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        runDeadline: Date,
        pollInterval: TimeInterval,
        analysisStart: Date,
        loggingEnabled: Bool,
        frameCount: inout Int,
        frameSize: inout String,
        firstFrameLatencySeconds: inout Double?,
        activeDecodeSeconds: inout Double?,
        adjustedConfigByFrameSize: inout [String: CaptureRuntimeConfig]
    ) throws -> Int {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = true

        let asset = AVURLAsset(url: playbackURL)
        let item = AVPlayerItem(asset: asset)
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.playImmediately(atRate: 1)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)

        let sessionStart = Date()
        let readyDeadline = sessionStart.addingTimeInterval(12)
        let staleFrameReconnectSeconds: TimeInterval = 1.25
        var sessionFrameCount = 0
        var lastFrameDate: Date?

        defer {
            player.pause()
            item.remove(output)
        }

        while Date() < runDeadline {
            switch item.status {
            case .failed:
                if sessionFrameCount > 0 {
                    return sessionFrameCount
                }
                throw LiveStreamAnalyzerError.playerFailed(item.error?.localizedDescription ?? "unknown error")
            case .unknown where Date() > readyDeadline:
                if sessionFrameCount > 0 {
                    return sessionFrameCount
                }
                throw LiveStreamAnalyzerError.timedOutWaitingForPlayback(playbackURL)
            default:
                break
            }

            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                sessionFrameCount += 1
                lastFrameDate = Date()

                let frame = VideoFrame(pixelBuffer: pixelBuffer, presentationTimeStamp: itemTime, nominalFrameRate: nil)
                try processDecodedFrame(
                    frame,
                    runtimeConfig: runtimeConfig,
                    pipeline: pipeline,
                    captureCoordinator: captureCoordinator,
                    analysisStart: analysisStart,
                    loggingEnabled: loggingEnabled,
                    frameCount: &frameCount,
                    frameSize: &frameSize,
                    firstFrameLatencySeconds: &firstFrameLatencySeconds,
                    activeDecodeSeconds: &activeDecodeSeconds,
                    adjustedConfigByFrameSize: &adjustedConfigByFrameSize
                )
            }

            if let lastFrameDate,
               Date().timeIntervalSince(lastFrameDate) > staleFrameReconnectSeconds,
               Date() < runDeadline {
                return sessionFrameCount
            }

            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: pollInterval))
        }

        return sessionFrameCount
    }

    private func processDecodedFrame(
        _ frame: VideoFrame,
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        analysisStart: Date,
        loggingEnabled: Bool,
        frameCount: inout Int,
        frameSize: inout String,
        firstFrameLatencySeconds: inout Double?,
        activeDecodeSeconds: inout Double?,
        adjustedConfigByFrameSize: inout [String: CaptureRuntimeConfig]
    ) throws {
        if firstFrameLatencySeconds == nil {
            firstFrameLatencySeconds = Date().timeIntervalSince(analysisStart)
        }
        frameCount += 1
        if let presentationTimeSeconds = frame.presentationTimeSeconds {
            activeDecodeSeconds = max(activeDecodeSeconds ?? 0, presentationTimeSeconds)
        }
        frameSize = frame.sizeSummary
        let adjustedRuntimeConfig = adjustedConfig(
            for: frame,
            runtimeConfig: runtimeConfig,
            loggingEnabled: loggingEnabled,
            cache: &adjustedConfigByFrameSize
        )
        pipeline.process(frame, runtimeConfig: adjustedRuntimeConfig)
    }

    private func adjustedConfig(
        for frame: VideoFrame,
        runtimeConfig: CaptureRuntimeConfig?,
        loggingEnabled: Bool,
        cache: inout [String: CaptureRuntimeConfig]
    ) -> CaptureRuntimeConfig? {
        runtimeConfig.map { config in
            let cacheKey = frame.sizeSummary
            if let cached = cache[cacheKey] {
                return cached
            }
            let adjusted = config.adjustedForFrameSize(width: frame.width, height: frame.height)
            cache[cacheKey] = adjusted
            if loggingEnabled {
                print("[live] adjusted_runtime_config frame_size=\(cacheKey) \(adjusted.runtimeSummary)")
            }
            return adjusted
        }
    }

    private static func effectiveFrameRate(frameCount: Int, activeDecodeSeconds: Double?) -> Double? {
        guard
            frameCount > 1,
            let activeDecodeSeconds,
            activeDecodeSeconds > 0
        else {
            return nil
        }
        return Double(frameCount) / activeDecodeSeconds
    }
}

private struct DecodeSessionResult {
    let decodedFrameCount: Int
    let playbackURL: URL
}
