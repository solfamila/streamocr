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
    let buySignalTimings: [BuySignalTiming]
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
        metadataURL: URL? = nil,
        resolverTimeoutSeconds: TimeInterval = 10
    ) throws -> LiveStreamAnalysisResult {
        let start = Date()
        let runDeadline = start.addingTimeInterval(max(0.1, runSeconds))
        let pollInterval = 1 / max(1, pollFPS)
        let runtimeConfig = try runtimeConfigURL.map { try RuntimeConfigFileIO.load(from: $0) }
        let eventCollector = PipelineEventCollector()
        let tradingRuntime = OCRTradingCoordinatorRuntime(
            coordinator: .liveTradingDefaults(),
            executor: OCRTradingDryRunCommandExecutor(),
            eventHandler: eventCollector.handle(_:)
        )
        tradingRuntime.beginSession(1)
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: loggingEnabled,
            recognizer: FontTemplateTextRecognizer(),
            asyncSymbolRecognitionEnabled: false,
            beep: {},
            eventHandler: eventCollector.handle(_:),
            frameObservationHandler: tradingRuntime.handle(_:),
            triggerHandlingMode: .frameObservationsOnly
        )

        var frameCount = 0
        var frameSize = "unknown"
        var firstFrameLatencySeconds: Double?
        var activeDecodeSeconds: Double?
        var adjustedConfigByFrameSize: [String: CaptureRuntimeConfig] = [:]
        var lastResolved: ResolvedLiveStream?
        var lastPlaybackURL: URL?
        var lastStartupError: Error?
        let captureCoordinator = recordVideoURL.map {
            LiveMediaCaptureCoordinator(
                outputURL: $0,
                loggingEnabled: loggingEnabled,
                runSeconds: runSeconds
            )
        }

        while Date() < runDeadline, lastResolved == nil {
            do {
                lastResolved = try NanocosmosStreamResolver.resolve(
                    seedURL: seedURL,
                    timeoutSeconds: resolverTimeoutSeconds
                )
            } catch {
                lastStartupError = error
                if loggingEnabled {
                    print("[live] resolve_failed retrying due_to=\"\(error.localizedDescription)\"")
                }
                if Date() < runDeadline {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }

        guard let resolved = lastResolved else {
            throw lastStartupError ?? LiveStreamAnalyzerError.noFramesDecoded(seedURL)
        }

        if let webSocketURL = preferredWebSocketURL(seedURL: seedURL, resolved: resolved) {
            do {
                return try analyzeViaWebSocket(
                    seedURL: seedURL,
                    webSocketURL: webSocketURL,
                    resolved: resolved,
                    runtimeConfigURL: runtimeConfigURL,
                    runtimeConfig: runtimeConfig,
                    runSeconds: runSeconds,
                    runDeadline: runDeadline,
                    analysisStart: start,
                    loggingEnabled: loggingEnabled,
                    eventCollector: eventCollector,
                    tradingRuntime: tradingRuntime,
                    pipeline: pipeline,
                    captureCoordinator: captureCoordinator,
                    metadataURL: metadataURL
                )
            } catch {
                lastStartupError = error
                if loggingEnabled {
                    print("[live] websocket_path_failed falling_back_to_source_chunks due_to=\"\(error.localizedDescription)\"")
                }
            }
        }

        if let sourceChunkURL = preferredSourceChunkURL(seedURL: seedURL, resolved: resolved) {
            do {
                return try analyzeViaSourceChunks(
                    seedURL: seedURL,
                    sourceURL: sourceChunkURL,
                    resolved: resolved,
                    runtimeConfigURL: runtimeConfigURL,
                    runtimeConfig: runtimeConfig,
                    runSeconds: runSeconds,
                    runDeadline: runDeadline,
                    analysisStart: start,
                    loggingEnabled: loggingEnabled,
                    eventCollector: eventCollector,
                    tradingRuntime: tradingRuntime,
                    pipeline: pipeline,
                    captureCoordinator: captureCoordinator,
                    metadataURL: metadataURL
                )
            } catch {
                lastStartupError = error
                if loggingEnabled {
                    print("[live] source_chunk_path_failed falling_back_to_avfoundation due_to=\"\(error.localizedDescription)\"")
                }
            }
        }

        while Date() < runDeadline {
            do {
                try captureCoordinator?.ensureRecordingStarted(
                    seedURL: seedURL,
                    remainingSeconds: runDeadline.timeIntervalSinceNow,
                    resolved: resolved
                )

                let playbackCandidates = frameCount == 0
                    ? [resolved.playbackURL]
                    : [resolved.playbackURL] + resolved.alternatePlaybackURLs
                let sessionResult = try decodePlaybackCandidates(
                    playbackCandidates,
                    runtimeConfig: runtimeConfig,
                    pipeline: pipeline,
                    captureCoordinator: captureCoordinator,
                    runDeadline: runDeadline,
                    pollInterval: pollInterval,
                    analysisStart: start,
                    loggingEnabled: loggingEnabled,
                    startupMode: frameCount == 0,
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
                lastStartupError = error
                if loggingEnabled {
                    print("[live] startup_attach_failed retrying due_to=\"\(error.localizedDescription)\"")
                }
                if Date() < runDeadline {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                continue
            }

            if Date() < runDeadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        guard frameCount > 0 else {
            if let lastStartupError {
                throw lastStartupError
            }
            throw LiveStreamAnalyzerError.noFramesDecoded(lastPlaybackURL ?? resolved.playbackURL)
        }

        return try buildResult(
            seedURL: seedURL,
            resolvedForResult: resolved,
            playbackURL: lastPlaybackURL,
            runtimeConfigURL: runtimeConfigURL,
            metadataURL: metadataURL,
            runSeconds: runSeconds,
            analysisStart: start,
            firstFrameLatencySeconds: firstFrameLatencySeconds,
            activeDecodeSeconds: activeDecodeSeconds,
            frameCount: frameCount,
            frameSize: frameSize,
            eventCollector: eventCollector,
            tradingRuntime: tradingRuntime,
            captureCoordinator: captureCoordinator,
            loggingEnabled: loggingEnabled
        )
    }

    private func preferredWebSocketURL(seedURL: URL, resolved: ResolvedLiveStream) -> URL? {
        let candidates = [seedURL, resolved.playbackURL, resolved.streamURL, resolved.playlistURL] +
            resolved.alternatePlaybackURLs
        for candidate in candidates {
            if let webSocketURL = NanocosmosWebSocketFrameSource.normalizedWebSocketURL(from: candidate),
               NanocosmosWebSocketFrameSource.supports(webSocketURL: webSocketURL) {
                return webSocketURL
            }
        }
        return nil
    }

    private func preferredSourceChunkURL(seedURL: URL, resolved: ResolvedLiveStream) -> URL? {
        let sourceURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(
            seedURL: seedURL,
            resolved: resolved
        )
        return NanocosmosStreamingChunkPuller.supports(sourceURL: sourceURL) ? sourceURL : nil
    }

    private func analyzeViaWebSocket(
        seedURL: URL,
        webSocketURL: URL,
        resolved: ResolvedLiveStream,
        runtimeConfigURL: URL?,
        runtimeConfig: CaptureRuntimeConfig?,
        runSeconds: Double,
        runDeadline: Date,
        analysisStart: Date,
        loggingEnabled: Bool,
        eventCollector: PipelineEventCollector,
        tradingRuntime: OCRTradingCoordinatorRuntime,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        metadataURL: URL?
    ) throws -> LiveStreamAnalysisResult {
        let frameState = LockedBox(LiveStreamDecodedFrameState())

        try captureCoordinator?.ensureRecordingStarted(
            seedURL: seedURL,
            remainingSeconds: runDeadline.timeIntervalSinceNow,
            resolved: resolved
        )

        let summary = try NanocosmosWebSocketFrameSource().decode(
            webSocketURL: webSocketURL,
            runSeconds: max(0.1, runDeadline.timeIntervalSinceNow),
            loggingEnabled: loggingEnabled
        ) { frame in
            try frameState.withValue { state in
                try state.processDecodedFrame(
                    frame,
                    runtimeConfig: runtimeConfig,
                    pipeline: pipeline,
                    analysisStart: analysisStart,
                    loggingEnabled: loggingEnabled
                )
            }
        }

        let snapshot = frameState.snapshot()

        if loggingEnabled {
            print(
                "[live] websocket_decoded frames=\(summary.decodedFrameCount) " +
                "first_binary_seconds=\(formatOptionalSeconds(summary.firstBinaryElapsedSeconds)) " +
                "first_media_seconds=\(formatOptionalSeconds(summary.firstMediaElapsedSeconds)) " +
                "first_frame_seconds=\(formatOptionalSeconds(summary.firstFrameElapsedSeconds)) " +
                "bytes=\(summary.binaryByteCount) source_url=\(webSocketURL.absoluteString)"
            )
        }

        guard snapshot.frameCount > 0 else {
            throw LiveStreamAnalyzerError.noFramesDecoded(webSocketURL)
        }

        return try buildResult(
            seedURL: seedURL,
            resolvedForResult: resolved,
            playbackURL: webSocketURL,
            runtimeConfigURL: runtimeConfigURL,
            metadataURL: metadataURL,
            runSeconds: runSeconds,
            analysisStart: analysisStart,
            firstFrameLatencySeconds: snapshot.firstFrameLatencySeconds,
            activeDecodeSeconds: snapshot.activeDecodeSeconds,
            frameCount: snapshot.frameCount,
            frameSize: snapshot.frameSize,
            eventCollector: eventCollector,
            tradingRuntime: tradingRuntime,
            captureCoordinator: captureCoordinator,
            loggingEnabled: loggingEnabled
        )
    }

    private func analyzeViaSourceChunks(
        seedURL: URL,
        sourceURL: URL,
        resolved: ResolvedLiveStream,
        runtimeConfigURL: URL?,
        runtimeConfig: CaptureRuntimeConfig?,
        runSeconds: Double,
        runDeadline: Date,
        analysisStart: Date,
        loggingEnabled: Bool,
        eventCollector: PipelineEventCollector,
        tradingRuntime: OCRTradingCoordinatorRuntime,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        metadataURL: URL?
    ) throws -> LiveStreamAnalysisResult {
        let decoder = LocalVideoFrameDecoder()
        let chunkPuller = NanocosmosStreamingChunkPuller()
        let chunkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureShellApp-live-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chunkDirectory) }

        var frameCount = 0
        var frameSize = "unknown"
        var firstFrameLatencySeconds: Double?
        var activeDecodeSeconds: Double?
        var adjustedConfigByFrameSize: [String: CaptureRuntimeConfig] = [:]
        var chunkIndex = 0
        var presentationTimeOffsetSeconds = 0.0
        var lastChunkError: Error?

        while Date() < runDeadline {
            do {
                try captureCoordinator?.ensureRecordingStarted(
                    seedURL: seedURL,
                    remainingSeconds: runDeadline.timeIntervalSinceNow,
                    resolved: resolved
                )

                let chunkBaseName = String(format: "chunk_%06d", chunkIndex)
                let lowLatencyChunkURL = chunkDirectory.appendingPathComponent(
                    "\(chunkBaseName)_low_latency.mp4"
                )
                let fallbackChunkURL = chunkDirectory.appendingPathComponent(
                    "\(chunkBaseName)_fallback.mp4"
                )
                defer {
                    try? FileManager.default.removeItem(at: lowLatencyChunkURL)
                    try? FileManager.default.removeItem(at: fallbackChunkURL)
                }

                var capturedChunk = try chunkPuller.captureChunk(
                    sourceURL: sourceURL,
                    destinationURL: lowLatencyChunkURL,
                    firstByteTimeoutSeconds: min(max(runDeadline.timeIntervalSinceNow, 4), 12),
                    captureWindowSeconds: LiveSourceChunkCapturePolicy.lowLatencyCaptureWindowSeconds,
                    minimumPlayableProbeWindowSeconds: LiveSourceChunkCapturePolicy.minimumPlayableProbeWindowSeconds,
                    playableProbeIntervalSeconds: LiveSourceChunkCapturePolicy.playableProbeIntervalSeconds,
                    playableProbe: { [decoder] partialChunkURL in
                        let summary = try? decoder.decode(
                            videoURL: partialChunkURL,
                            maximumFrameCount: 1
                        ) { _ in }
                        return (summary?.frameCount ?? 0) > 0
                    }
                )
                var captureWindowSeconds = LiveSourceChunkCapturePolicy.lowLatencyCaptureWindowSeconds

                var decodedFramesInAttempt = 0
                func decodeCapturedChunk(_ capturedChunk: NanocosmosCapturedChunk) throws -> LocalVideoDecodingSummary {
                    try decoder.decode(
                        videoURL: capturedChunk.fileURL,
                        presentationTimeOffsetSeconds: presentationTimeOffsetSeconds,
                        allowsPartialDecode: true
                    ) { frame in
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
                        decodedFramesInAttempt += 1
                    }
                }

                let decodeSummary: LocalVideoDecodingSummary
                do {
                    decodedFramesInAttempt = 0
                    let lowLatencySummary = try decodeCapturedChunk(capturedChunk)
                    if lowLatencySummary.frameCount == 0 {
                        throw LocalVideoFrameDecoderError.assetReaderFailed(
                            "No frames decoded from low-latency streaming chunk."
                        )
                    }
                    decodeSummary = lowLatencySummary
                } catch {
                    guard decodedFramesInAttempt == 0 else {
                        throw error
                    }

                    if loggingEnabled {
                        print(
                            "[live] low_latency_source_chunk_decode_failed index=\(chunkIndex) " +
                            "fallback_capture_window_seconds=" +
                            "\(String(format: "%.3f", LiveSourceChunkCapturePolicy.analyzerFallbackCaptureWindowSeconds)) " +
                            "due_to=\"\(error.localizedDescription)\""
                        )
                    }

                    capturedChunk = try chunkPuller.captureChunk(
                        sourceURL: sourceURL,
                        destinationURL: fallbackChunkURL,
                        firstByteTimeoutSeconds: min(max(runDeadline.timeIntervalSinceNow, 4), 12),
                        captureWindowSeconds: LiveSourceChunkCapturePolicy.analyzerFallbackCaptureWindowSeconds
                    )
                    captureWindowSeconds = LiveSourceChunkCapturePolicy.analyzerFallbackCaptureWindowSeconds

                    decodedFramesInAttempt = 0
                    decodeSummary = try decodeCapturedChunk(capturedChunk)
                }

                if let lastPresentationTimeSeconds = decodeSummary.lastPresentationTimeSeconds {
                    presentationTimeOffsetSeconds = max(presentationTimeOffsetSeconds, lastPresentationTimeSeconds)
                }
                lastChunkError = nil

                if loggingEnabled {
                    print(
                        "[live] source_chunk_captured index=\(chunkIndex) bytes=\(capturedChunk.byteCount) " +
                        "capture_seconds=\(String(format: "%.3f", capturedChunk.elapsedSeconds)) " +
                        "first_byte_seconds=\(formatOptionalSeconds(capturedChunk.firstByteElapsedSeconds)) " +
                        "active_capture_seconds=\(formatOptionalSeconds(capturedChunk.activeCaptureSeconds)) " +
                        "max_capture_window_seconds=\(String(format: "%.3f", captureWindowSeconds)) " +
                        "finish_reason=\(capturedChunk.finishReason.rawValue) " +
                        "frames=\(decodeSummary.frameCount) source_url=\(capturedChunk.sourceURL.absoluteString)"
                    )
                }

                chunkIndex += 1
            } catch {
                lastChunkError = error
                if loggingEnabled {
                    print("[live] source_chunk_failed index=\(chunkIndex) due_to=\"\(error.localizedDescription)\"")
                }
                if Date() < runDeadline {
                    Thread.sleep(forTimeInterval: frameCount > 0 ? 0.25 : 0.5)
                }
            }
        }

        guard frameCount > 0 else {
            throw lastChunkError ?? LiveStreamAnalyzerError.noFramesDecoded(sourceURL)
        }

        return try buildResult(
            seedURL: seedURL,
            resolvedForResult: resolved,
            playbackURL: sourceURL,
            runtimeConfigURL: runtimeConfigURL,
            metadataURL: metadataURL,
            runSeconds: runSeconds,
            analysisStart: analysisStart,
            firstFrameLatencySeconds: firstFrameLatencySeconds,
            activeDecodeSeconds: activeDecodeSeconds,
            frameCount: frameCount,
            frameSize: frameSize,
            eventCollector: eventCollector,
            tradingRuntime: tradingRuntime,
            captureCoordinator: captureCoordinator,
            loggingEnabled: loggingEnabled
        )
    }

    private func buildResult(
        seedURL: URL,
        resolvedForResult: ResolvedLiveStream?,
        playbackURL: URL?,
        runtimeConfigURL: URL?,
        metadataURL: URL?,
        runSeconds: Double,
        analysisStart: Date,
        firstFrameLatencySeconds: Double?,
        activeDecodeSeconds: Double?,
        frameCount: Int,
        frameSize: String,
        eventCollector: PipelineEventCollector,
        tradingRuntime: OCRTradingCoordinatorRuntime,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        loggingEnabled: Bool
    ) throws -> LiveStreamAnalysisResult {
        let didFlushPendingMessages = tradingRuntime.waitForPendingCommands(timeout: 2)
        if loggingEnabled, !didFlushPendingMessages {
            print("[live] timed_out_waiting_for_transport_callbacks timeout_seconds=2.00")
        }

        let collectedEvents = eventCollector.snapshotWithAnalysisTime()
        let allEvents = collectedEvents.map(\.event)
        let recognitionEvents = allEvents.filter { $0.kind == .recognition }
        let triggerEvents = allEvents.filter { $0.kind == .trigger }
        let buySignalTimings = PipelineTimingMetrics.buySignalTimings(from: collectedEvents)
        let recording = try captureCoordinator?.finish()
        let playbackURLString = (playbackURL ?? resolvedForResult?.playbackURL)?.absoluteString ?? ""
        let metadataPath = metadataURL?.path
        let elapsedSeconds = Date().timeIntervalSince(analysisStart)
        let effectiveFrameRate = Self.effectiveFrameRate(frameCount: frameCount, activeDecodeSeconds: activeDecodeSeconds)
        let metadata = LiveRunMetadata(
            seedURL: (resolvedForResult?.seedURL ?? seedURL).absoluteString,
            playlistURL: resolvedForResult?.playlistURL.absoluteString ?? "",
            playbackURL: playbackURLString,
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
            playbackURL: playbackURLString,
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
            buySignalTimings: buySignalTimings,
            recognitionEvents: recognitionEvents,
            triggerEvents: triggerEvents
        )
    }

    private func decodePlaybackCandidates(
        _ playbackCandidates: [URL],
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        runDeadline: Date,
        pollInterval: TimeInterval,
        analysisStart: Date,
        loggingEnabled: Bool,
        startupMode: Bool,
        frameCount: inout Int,
        frameSize: inout String,
        firstFrameLatencySeconds: inout Double?,
        activeDecodeSeconds: inout Double?,
        adjustedConfigByFrameSize: inout [String: CaptureRuntimeConfig]
    ) throws -> DecodeSessionResult {
        var failures: [String] = []
        for playbackURL in playbackCandidates {
            do {
                let decodedFrameCount = try decodeAVPlayerPlaybackSession(
                    playbackURL: playbackURL,
                    runtimeConfig: runtimeConfig,
                    pipeline: pipeline,
                    captureCoordinator: captureCoordinator,
                    runDeadline: runDeadline,
                    pollInterval: pollInterval,
                    readyTimeoutSeconds: startupMode ? 6 : 12,
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
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        captureCoordinator: LiveMediaCaptureCoordinator?,
        runDeadline: Date,
        pollInterval: TimeInterval,
        readyTimeoutSeconds: TimeInterval,
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
        let readyDeadline = sessionStart.addingTimeInterval(readyTimeoutSeconds)
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

    private func formatOptionalSeconds(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "nil"
    }
}

private struct DecodeSessionResult {
    let decodedFrameCount: Int
    let playbackURL: URL
}

private struct LiveStreamDecodedFrameState {
    var frameCount = 0
    var frameSize = "unknown"
    var firstFrameLatencySeconds: Double?
    var activeDecodeSeconds: Double?
    private var adjustedConfigByFrameSize: [String: CaptureRuntimeConfig] = [:]

    mutating func processDecodedFrame(
        _ frame: VideoFrame,
        runtimeConfig: CaptureRuntimeConfig?,
        pipeline: LowLatencyOCRFramePipeline,
        analysisStart: Date,
        loggingEnabled: Bool
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
            loggingEnabled: loggingEnabled
        )
        pipeline.process(frame, runtimeConfig: adjustedRuntimeConfig)
    }

    private mutating func adjustedConfig(
        for frame: VideoFrame,
        runtimeConfig: CaptureRuntimeConfig?,
        loggingEnabled: Bool
    ) -> CaptureRuntimeConfig? {
        runtimeConfig.map { config in
            let cacheKey = frame.sizeSummary
            if let cached = adjustedConfigByFrameSize[cacheKey] {
                return cached
            }
            let adjusted = config.adjustedForFrameSize(width: frame.width, height: frame.height)
            adjustedConfigByFrameSize[cacheKey] = adjusted
            if loggingEnabled {
                print("[live] adjusted_runtime_config frame_size=\(cacheKey) \(adjusted.runtimeSummary)")
            }
            return adjusted
        }
    }
}
