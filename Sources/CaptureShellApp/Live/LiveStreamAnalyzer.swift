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
    let requestedRunSeconds: Double
    let elapsedSeconds: Double
    let frameCount: Int
    let frameSize: String
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
        sendTradingMessages: Bool = false,
        resolverTimeoutSeconds: TimeInterval = 10
    ) throws -> LiveStreamAnalysisResult {
        let start = Date()
        let runDeadline = start.addingTimeInterval(max(0.1, runSeconds))
        let pollInterval = 1 / max(1, pollFPS)
        let runtimeConfig = try runtimeConfigURL.map { try RuntimeConfigFileIO.load(from: $0) }
        let eventCollector = PipelineEventCollector()
        let messageSender: any TradingMessageSending = sendTradingMessages
            ? LocalTradingWebSocketClient()
            : DiscardingTradingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: loggingEnabled,
            recognizer: FontTemplateTextRecognizer(),
            messageSender: messageSender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        var frameCount = 0
        var frameSize = "unknown"
        var adjustedConfigByFrameSize: [String: CaptureRuntimeConfig] = [:]
        var lastResolved: ResolvedLiveStream?

        while Date() < runDeadline {
            do {
                let resolved = try NanocosmosStreamResolver.resolve(
                    seedURL: seedURL,
                    timeoutSeconds: resolverTimeoutSeconds
                )
                lastResolved = resolved

                let decoded = try decodeSession(
                    resolved: resolved,
                    runtimeConfig: runtimeConfig,
                    pipeline: pipeline,
                    runDeadline: runDeadline,
                    pollInterval: pollInterval,
                    loggingEnabled: loggingEnabled,
                    frameCount: &frameCount,
                    frameSize: &frameSize,
                    adjustedConfigByFrameSize: &adjustedConfigByFrameSize
                )

                if loggingEnabled, decoded > 0, Date() < runDeadline {
                    print("[live] reconnecting after decoded_frames=\(decoded)")
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

            if Date() < runDeadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        let resolvedForResult = lastResolved
        guard frameCount > 0 else {
            throw LiveStreamAnalyzerError.noFramesDecoded(resolvedForResult?.playlistURL ?? seedURL)
        }

        _ = messageSender.waitForPendingMessages(timeout: 2)

        let recognitionEvents = eventCollector.events.filter { $0.kind == .recognition }
        let triggerEvents = eventCollector.events.filter { $0.kind == .trigger }
        let playbackURL = resolvedForResult?.playlistURL.absoluteString ?? ""

        return LiveStreamAnalysisResult(
            seedURL: (resolvedForResult?.seedURL ?? seedURL).absoluteString,
            playlistURL: resolvedForResult?.playlistURL.absoluteString ?? "",
            playbackURL: playbackURL,
            streamURL: resolvedForResult?.streamURL.absoluteString ?? "",
            runtimeConfigPath: runtimeConfigURL?.path,
            requestedRunSeconds: runSeconds,
            elapsedSeconds: Date().timeIntervalSince(start),
            frameCount: frameCount,
            frameSize: frameSize,
            recognitionEvents: recognitionEvents,
            triggerEvents: triggerEvents
        )
    }

    private func decodeSession(
        resolved: ResolvedLiveStream,
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        runDeadline: Date,
        pollInterval: TimeInterval,
        loggingEnabled: Bool,
        frameCount: inout Int,
        frameSize: inout String,
        adjustedConfigByFrameSize: inout [String: CaptureRuntimeConfig]
    ) throws -> Int {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = true

        let playbackURL = resolved.playlistURL
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
                frameCount += 1
                sessionFrameCount += 1
                lastFrameDate = Date()

                let frame = VideoFrame(pixelBuffer: pixelBuffer, presentationTimeStamp: itemTime, nominalFrameRate: nil)
                frameSize = frame.sizeSummary
                let adjustedRuntimeConfig = adjustedConfig(
                    for: frame,
                    runtimeConfig: runtimeConfig,
                    loggingEnabled: loggingEnabled,
                    cache: &adjustedConfigByFrameSize
                )
                pipeline.process(frame, runtimeConfig: adjustedRuntimeConfig)
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
}
