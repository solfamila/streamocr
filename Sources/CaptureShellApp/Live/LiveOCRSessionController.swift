import CoreImage
import Foundation

struct LiveOCRSessionStatusSnapshot: Equatable, Sendable {
    enum State: String, Sendable {
        case off
        case connecting
        case live
        case stopping
        case error
    }

    let state: State
    let isRunning: Bool
    let seedURLText: String
    let headline: String
    let detail: String
    let fps: Double?
    let frameSize: String?
    let lastSubscribedSymbol: String?
    let hasPositionROI: Bool
    let hasSymbolROI: Bool

    static let off = LiveOCRSessionStatusSnapshot(
        state: .off,
        isRunning: false,
        seedURLText: "",
        headline: "Live stream: Off",
        detail: "Enter a live stream URL to start preview/OCR.",
        fps: nil,
        frameSize: nil,
        lastSubscribedSymbol: nil,
        hasPositionROI: false,
        hasSymbolROI: false
    )
}

enum LiveOCRSessionControllerError: Error, LocalizedError {
    case invalidSeedURL(String)
    case unsupportedSource(URL)
    case noActiveLiveFrame
    case timedOutWaitingForLiveFrame

    var errorDescription: String? {
        switch self {
        case let .invalidSeedURL(text):
            return "Invalid live stream URL: \(text)"
        case let .unsupportedSource(url):
            return "This live source is not supported by the native stream.mp4 OCR path: \(url.absoluteString)"
        case .noActiveLiveFrame:
            return "No active live OCR frame is available yet."
        case .timedOutWaitingForLiveFrame:
            return "Timed out waiting for the next live OCR frame."
        }
    }
}

private enum LiveOCRSessionCancellation: Error {
    case cancelled
}

final class LiveOCRSessionController: @unchecked Sendable {
    private static let maximumLiveOCRBacklogSeconds = 0.75

    var onStatusChanged: ((LiveOCRSessionStatusSnapshot) -> Void)?

    private let manager: TradingRuntimeManager
    private let temporaryDirectoryProvider: @Sendable (UUID) -> URL
    private let chunkPuller = NanocosmosStreamingChunkPuller()
    private let decoder = LocalVideoFrameDecoder()
    private let stateLock = NSLock()
    private let snapshotCIContext = CIContext(options: [.cacheIntermediates: false])

    private var latestStatus = LiveOCRSessionStatusSnapshot.off
    private var activeSessionID: UUID?
    private var stoppingSessionID: UUID?
    private var activeRuntimeConfig: CaptureRuntimeConfig?
    private var buyQuantityRatio = 0.5
    private var activeTradingRuntime: OCRTradingCoordinatorRuntime?
    private var nextTradingSessionGeneration: OCRTradingSessionGeneration = 0
    private var pendingFrameSnapshotRequest: PendingFrameSnapshotRequest?

    init(
        manager: TradingRuntimeManager,
        temporaryDirectoryProvider: @escaping @Sendable (UUID) -> URL = { sessionID in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("CaptureShellApp-live-session-\(sessionID.uuidString)", isDirectory: true)
        }
    ) {
        self.manager = manager
        self.temporaryDirectoryProvider = temporaryDirectoryProvider
    }

    func setRuntimeConfig(_ config: CaptureRuntimeConfig?) {
        stateLock.lock()
        activeRuntimeConfig = config
        let currentStatus = latestStatus
        stateLock.unlock()

        publishStatus(
            makeStatus(
                state: currentStatus.state,
                seedURLText: currentStatus.seedURLText,
                fps: currentStatus.fps,
                frameSize: currentStatus.frameSize,
                firstFrameLatencySeconds: nil,
                lastSubscribedSymbol: currentStatus.lastSubscribedSymbol,
                messageOverride: statusMessage(
                    state: currentStatus.state,
                    fps: currentStatus.fps,
                    frameSize: currentStatus.frameSize,
                    firstFrameLatencySeconds: nil,
                    lastSubscribedSymbol: currentStatus.lastSubscribedSymbol
                )
            )
        )
    }

    func setBuyQuantityRatio(_ ratio: Double) {
        stateLock.lock()
        buyQuantityRatio = ratio.isFinite && ratio > 0 ? ratio : 0.5
        stateLock.unlock()
    }

    func start(seedURLText: String, loggingEnabled: Bool = false) throws {
        let trimmed = seedURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seedURL = URL(string: trimmed), !trimmed.isEmpty else {
            throw LiveOCRSessionControllerError.invalidSeedURL(seedURLText)
        }

        let sessionID = UUID()
        let tradingSessionGeneration: OCRTradingSessionGeneration
        stateLock.lock()
        nextTradingSessionGeneration &+= 1
        tradingSessionGeneration = nextTradingSessionGeneration
        activeSessionID = sessionID
        stoppingSessionID = nil
        stateLock.unlock()

        publishStatus(
            makeStatus(
                state: .connecting,
                seedURLText: trimmed,
                fps: nil,
                frameSize: nil,
                firstFrameLatencySeconds: nil,
                lastSubscribedSymbol: nil,
                messageOverride: "Resolving live stream and waiting for first video chunk..."
            )
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runSession(
                sessionID: sessionID,
                tradingSessionGeneration: tradingSessionGeneration,
                seedURL: seedURL,
                loggingEnabled: loggingEnabled
            )
        }
    }

    func stop() {
        stateLock.lock()
        guard let sessionID = activeSessionID else {
            stateLock.unlock()
            return
        }
        let tradingRuntime = activeTradingRuntime
        let currentStatus = latestStatus
        activeSessionID = nil
        stoppingSessionID = sessionID
        stateLock.unlock()
        tradingRuntime?.stop(reason: "Live OCR stopped before pending trading actions completed.")
        publishStatus(
            makeStatus(
                state: .stopping,
                seedURLText: currentStatus.seedURLText,
                fps: currentStatus.fps,
                frameSize: currentStatus.frameSize,
                firstFrameLatencySeconds: nil,
                lastSubscribedSymbol: currentStatus.lastSubscribedSymbol,
                messageOverride: "Stopping live OCR and draining pending trading actions..."
            )
        )
    }

    @discardableResult
    func stopAndDrain(timeout: TimeInterval = 2) -> LiveOCRSessionStatusSnapshot {
        stop()

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            stateLock.lock()
            let status = latestStatus
            let didDrain = activeSessionID == nil && stoppingSessionID == nil
            stateLock.unlock()

            if didDrain || Date() >= deadline {
                return status
            }

            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func currentStatusSnapshot() -> LiveOCRSessionStatusSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestStatus
    }

    func captureCurrentFrameSnapshot(timeoutSeconds: TimeInterval = 3) throws -> LiveStreamFrameSnapshot {
        let request: PendingFrameSnapshotRequest

        stateLock.lock()
        guard let activeSessionID, latestStatus.isRunning else {
            stateLock.unlock()
            throw LiveOCRSessionControllerError.noActiveLiveFrame
        }
        request = PendingFrameSnapshotRequest(sessionID: activeSessionID)
        pendingFrameSnapshotRequest = request
        stateLock.unlock()

        if request.semaphore.wait(timeout: .now() + timeoutSeconds) != .success {
            stateLock.lock()
            if pendingFrameSnapshotRequest === request {
                pendingFrameSnapshotRequest = nil
            }
            stateLock.unlock()
            throw LiveOCRSessionControllerError.timedOutWaitingForLiveFrame
        }

        return try request.result?.get() ?? {
            throw LiveOCRSessionControllerError.noActiveLiveFrame
        }()
    }

    private func runSession(
        sessionID: UUID,
        tradingSessionGeneration: OCRTradingSessionGeneration,
        seedURL: URL,
        loggingEnabled: Bool
    ) {
        let sessionStart = Date()
        let temporaryDirectory = temporaryDirectoryProvider(sessionID)

        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            failSessionBeforeSender(
                sessionID: sessionID,
                status: makeStatus(
                    state: .error,
                    seedURLText: seedURL.absoluteString,
                    fps: nil,
                    frameSize: nil,
                    firstFrameLatencySeconds: nil,
                    lastSubscribedSymbol: nil,
                    messageOverride: "Failed to prepare live OCR workspace: \(error.localizedDescription)"
                )
            )
            return
        }

        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let messageSender = OCRAutomationTradingMessageSender(
            manager: manager,
            configurationProvider: { [weak self, weak manager] in
                let ratio = self?.buyQuantityRatioSnapshot() ?? 0.5
                let controllerArmed = manager?.dashboard.panel.status.controllerArmed ?? false
                return OCRAutomationTradingConfiguration(
                    buyQuantityRatio: ratio,
                    controllerArmed: controllerArmed
                )
            }
        )
        let tradingRuntime = OCRTradingCoordinatorRuntime(
            coordinator: .liveTradingDefaults(),
            executor: messageSender,
            eventHandler: { [weak self] event in
                self?.handlePipelineEvent(event, sessionID: sessionID)
            },
            emitsTransportOutcomes: true
        )
        stateLock.lock()
        if activeSessionID == sessionID {
            activeTradingRuntime = tradingRuntime
        }
        stateLock.unlock()
        tradingRuntime.beginSession(tradingSessionGeneration)

        defer {
            let flushed = tradingRuntime.waitForPendingCommands(timeout: 2)
            if loggingEnabled, !flushed {
                print("[live-session] pending_trading_actions_did_not_flush_before_exit")
            }

            finishSessionExit(sessionID: sessionID, tradingRuntime: tradingRuntime)
        }

        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: loggingEnabled,
            recognizer: FontTemplateTextRecognizer(),
            beep: {},
            frameObservationHandler: { observation in
                tradingRuntime.handle(observation)
            },
            triggerHandlingMode: .frameObservationsOnly
        )

        var totalFrameCount = 0
        var totalActiveDecodeSeconds = 0.0
        var firstFrameLatencySeconds: Double?
        var frameSize: String?
        var lastSubscribedSymbol: String?
        var presentationTimeOffsetSeconds = 0.0
        var resolvedStream: ResolvedLiveStream?
        var chunkIndex = 0

        if let webSocketURL = NanocosmosWebSocketFrameSource.normalizedWebSocketURL(from: seedURL),
           NanocosmosWebSocketFrameSource.supports(webSocketURL: webSocketURL) {
            do {
                try runWebSocketSession(
                    webSocketURL: webSocketURL,
                    seedURL: seedURL,
                    sessionID: sessionID,
                    sessionStart: sessionStart,
                    pipeline: pipeline,
                    totalFrameCount: &totalFrameCount,
                    totalActiveDecodeSeconds: &totalActiveDecodeSeconds,
                    firstFrameLatencySeconds: &firstFrameLatencySeconds,
                    frameSize: &frameSize,
                    lastSubscribedSymbol: &lastSubscribedSymbol,
                    loggingEnabled: loggingEnabled
                )
                if shouldContinue(sessionID: sessionID) {
                    publishStatus(.off)
                }
                return
            } catch LiveOCRSessionCancellation.cancelled {
                return
            } catch {
                if loggingEnabled {
                    print("[live-session] websocket_path_failed falling_back_to_source_chunks due_to=\"\(error.localizedDescription)\"")
                }
                publishStatus(
                    makeStatus(
                        state: .connecting,
                        seedURLText: seedURL.absoluteString,
                        fps: nil,
                        frameSize: frameSize,
                        firstFrameLatencySeconds: firstFrameLatencySeconds,
                        lastSubscribedSymbol: lastSubscribedSymbol,
                        messageOverride: "Native WSS attach failed, retrying with source chunks: \(error.localizedDescription)"
                    )
                )
            }
        }

        while shouldContinue(sessionID: sessionID) {
            do {
                try autoreleasepool {
                    if resolvedStream == nil {
                        resolvedStream = try NanocosmosStreamResolver.resolve(seedURL: seedURL)
                    }

                    guard let resolvedStream else {
                        throw LiveOCRSessionControllerError.invalidSeedURL(seedURL.absoluteString)
                    }

                    let sourceURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(
                        seedURL: seedURL,
                        resolved: resolvedStream
                    )

                    guard NanocosmosStreamingChunkPuller.supports(sourceURL: sourceURL) else {
                        throw LiveOCRSessionControllerError.unsupportedSource(sourceURL)
                    }

                    let chunkBaseName = "chunk-\(chunkIndex)"
                    chunkIndex += 1
                    let lowLatencyChunkURL = temporaryDirectory.appendingPathComponent(
                        "\(chunkBaseName)-low-latency.mp4"
                    )
                    let fallbackChunkURL = temporaryDirectory.appendingPathComponent(
                        "\(chunkBaseName)-fallback.mp4"
                    )
                    defer {
                        try? FileManager.default.removeItem(at: lowLatencyChunkURL)
                        try? FileManager.default.removeItem(at: fallbackChunkURL)
                    }

                    var capturedChunk = try chunkPuller.captureChunk(
                        sourceURL: sourceURL,
                        destinationURL: lowLatencyChunkURL,
                        firstByteTimeoutSeconds: 8,
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

                    if loggingEnabled {
                        print(
                            "[live-session] chunk_captured bytes=\(capturedChunk.byteCount) " +
                                "elapsed_seconds=\(String(format: "%.2f", capturedChunk.elapsedSeconds)) " +
                                "first_byte_seconds=\(formatOptionalSeconds(capturedChunk.firstByteElapsedSeconds)) " +
                                "active_capture_seconds=\(formatOptionalSeconds(capturedChunk.activeCaptureSeconds)) " +
                                "max_capture_window_seconds=\(String(format: "%.2f", captureWindowSeconds)) " +
                                "finish_reason=\(capturedChunk.finishReason.rawValue)"
                        )
                    }

                    var decodedFramesInAttempt = 0
                    func decodeCapturedChunk(_ capturedChunk: NanocosmosCapturedChunk) throws -> LocalVideoDecodingSummary {
                        try decoder.decode(
                            videoURL: capturedChunk.fileURL,
                            presentationTimeOffsetSeconds: presentationTimeOffsetSeconds,
                            allowsPartialDecode: true
                        ) { [weak self] frame in
                            guard let self else { return }
                            guard self.shouldContinue(sessionID: sessionID) else {
                                throw LiveOCRSessionCancellation.cancelled
                            }

                            if firstFrameLatencySeconds == nil {
                                firstFrameLatencySeconds = Date().timeIntervalSince(sessionStart)
                            }

                            self.fulfillPendingFrameSnapshotIfNeeded(
                                frame: frame,
                                seedURL: seedURL,
                                sessionID: sessionID
                            )

                            let adjustedRuntimeConfig = self.runtimeConfigSnapshot()?.adjustedForFrameSize(
                                width: frame.width,
                                height: frame.height,
                                displayID: 0
                            )
                            pipeline.process(frame, runtimeConfig: adjustedRuntimeConfig)
                            decodedFramesInAttempt += 1
                            totalFrameCount += 1
                            frameSize = frame.sizeSummary
                        }
                    }

                    let summary: LocalVideoDecodingSummary
                    do {
                        decodedFramesInAttempt = 0
                        let lowLatencySummary = try decodeCapturedChunk(capturedChunk)
                        if lowLatencySummary.frameCount == 0 {
                            throw LocalVideoFrameDecoderError.assetReaderFailed(
                                "No frames decoded from low-latency streaming chunk."
                            )
                        }
                        summary = lowLatencySummary
                    } catch {
                        guard decodedFramesInAttempt == 0 else {
                            throw error
                        }

                        if loggingEnabled {
                            print(
                                "[live-session] low_latency_chunk_decode_failed " +
                                    "fallback_capture_window_seconds=" +
                                    "\(String(format: "%.2f", LiveSourceChunkCapturePolicy.guiFallbackCaptureWindowSeconds)) " +
                                    "due_to=\"\(error.localizedDescription)\""
                            )
                        }

                        capturedChunk = try chunkPuller.captureChunk(
                            sourceURL: sourceURL,
                            destinationURL: fallbackChunkURL,
                            firstByteTimeoutSeconds: 8,
                            captureWindowSeconds: LiveSourceChunkCapturePolicy.guiFallbackCaptureWindowSeconds
                        )
                        captureWindowSeconds = LiveSourceChunkCapturePolicy.guiFallbackCaptureWindowSeconds

                        if loggingEnabled {
                            print(
                                "[live-session] chunk_captured bytes=\(capturedChunk.byteCount) " +
                                    "elapsed_seconds=\(String(format: "%.2f", capturedChunk.elapsedSeconds)) " +
                                    "first_byte_seconds=\(formatOptionalSeconds(capturedChunk.firstByteElapsedSeconds)) " +
                                    "active_capture_seconds=\(formatOptionalSeconds(capturedChunk.activeCaptureSeconds)) " +
                                    "max_capture_window_seconds=\(String(format: "%.2f", captureWindowSeconds)) " +
                                    "finish_reason=\(capturedChunk.finishReason.rawValue)"
                            )
                        }

                        decodedFramesInAttempt = 0
                        summary = try decodeCapturedChunk(capturedChunk)
                    }

                    let frameDurationSeconds = frameDuration(
                        nominalFrameRate: summary.nominalFrameRate,
                        frameCount: summary.frameCount
                    )
                    presentationTimeOffsetSeconds = max(
                        presentationTimeOffsetSeconds,
                        (summary.lastPresentationTimeSeconds ?? presentationTimeOffsetSeconds) + frameDurationSeconds
                    )
                    totalActiveDecodeSeconds += activeDecodeSeconds(for: summary)

                    if totalFrameCount > 0 {
                        let effectiveFPS = totalActiveDecodeSeconds > 0
                            ? Double(totalFrameCount) / totalActiveDecodeSeconds
                            : nil
                        let snapshot = makeStatus(
                            state: .live,
                            seedURLText: seedURL.absoluteString,
                            fps: effectiveFPS,
                            frameSize: frameSize,
                            firstFrameLatencySeconds: firstFrameLatencySeconds,
                            lastSubscribedSymbol: lastSubscribedSymbol,
                            messageOverride: nil
                        )
                        publishStatus(snapshot)
                    }
                }
            } catch LiveOCRSessionCancellation.cancelled {
                break
            } catch {
                if !shouldContinue(sessionID: sessionID) {
                    break
                }

                if error is LiveOCRSessionControllerError {
                    publishStatus(
                        makeStatus(
                            state: .error,
                            seedURLText: seedURL.absoluteString,
                            fps: totalActiveDecodeSeconds > 0 ? Double(totalFrameCount) / totalActiveDecodeSeconds : nil,
                            frameSize: frameSize,
                            firstFrameLatencySeconds: firstFrameLatencySeconds,
                            lastSubscribedSymbol: lastSubscribedSymbol,
                            messageOverride: error.localizedDescription
                        )
                    )
                    clearSessionIfCurrent(sessionID: sessionID)
                    break
                }

                let retrySnapshot = makeStatus(
                    state: .connecting,
                    seedURLText: seedURL.absoluteString,
                    fps: totalActiveDecodeSeconds > 0 ? Double(totalFrameCount) / totalActiveDecodeSeconds : nil,
                    frameSize: frameSize,
                    firstFrameLatencySeconds: firstFrameLatencySeconds,
                    lastSubscribedSymbol: lastSubscribedSymbol,
                    messageOverride: "Retrying live stream after error: \(error.localizedDescription)"
                )
                publishStatus(retrySnapshot)
                resolvedStream = nil
                Thread.sleep(forTimeInterval: 0.5)
            }

            if let status = latestStatusSnapshot(for: sessionID),
               let symbol = status.lastSubscribedSymbol {
                lastSubscribedSymbol = symbol
            }
        }

        if shouldContinue(sessionID: sessionID) {
            publishStatus(.off)
        }
    }

    private func runWebSocketSession(
        webSocketURL: URL,
        seedURL: URL,
        sessionID: UUID,
        sessionStart: Date,
        pipeline: LowLatencyOCRFramePipeline,
        totalFrameCount: inout Int,
        totalActiveDecodeSeconds: inout Double,
        firstFrameLatencySeconds: inout Double?,
        frameSize: inout String?,
        lastSubscribedSymbol: inout String?,
        loggingEnabled: Bool
    ) throws {
        let frameState = LockedBox(
            LiveOCRWebSocketFrameState(
                totalFrameCount: totalFrameCount,
                totalActiveDecodeSeconds: totalActiveDecodeSeconds,
                firstFrameLatencySeconds: firstFrameLatencySeconds,
                frameSize: frameSize,
                lastSubscribedSymbol: lastSubscribedSymbol
            )
        )

        defer {
            let snapshot = frameState.snapshot()
            totalFrameCount = snapshot.totalFrameCount
            totalActiveDecodeSeconds = snapshot.totalActiveDecodeSeconds
            firstFrameLatencySeconds = snapshot.firstFrameLatencySeconds
            frameSize = snapshot.frameSize
            lastSubscribedSymbol = snapshot.lastSubscribedSymbol
        }

        if loggingEnabled {
            print("[live-session] websocket_attach source_url=\(webSocketURL.absoluteString)")
        }

        let summary = try NanocosmosWebSocketFrameSource().decode(
            webSocketURL: webSocketURL,
            runSeconds: 24 * 60 * 60,
            loggingEnabled: loggingEnabled,
            shouldContinue: { [weak self] in
                self?.shouldContinue(sessionID: sessionID) ?? false
            }
        ) { [weak self] frame in
            guard let self else { return }
            guard self.shouldContinue(sessionID: sessionID) else {
                throw LiveOCRSessionCancellation.cancelled
            }

            let statusToPublish = frameState.withValue { state -> LiveOCRSessionStatusSnapshot? in
                state.recordFirstFrameLatencyIfNeeded(sessionStart: sessionStart)
                self.fulfillPendingFrameSnapshotIfNeeded(
                    frame: frame,
                    seedURL: seedURL,
                    sessionID: sessionID
                )

                let adjustedRuntimeConfig = self.runtimeConfigSnapshot()?.adjustedForFrameSize(
                    width: frame.width,
                    height: frame.height,
                    displayID: 0
                )
                if state.shouldProcessLiveOCRFrame(
                    frame: frame,
                    maximumBacklogSeconds: Self.maximumLiveOCRBacklogSeconds
                ) {
                    pipeline.process(frame, runtimeConfig: adjustedRuntimeConfig)
                } else if loggingEnabled, let skippedCount = state.recordSkippedStaleOCRFrameIfLoggable() {
                    print("[live-session] dropped_stale_ocr_frames count=\(skippedCount)")
                }

                state.recordDecodedFrame(frame)

                if let status = self.latestStatusSnapshot(for: sessionID),
                   let symbol = status.lastSubscribedSymbol {
                    state.lastSubscribedSymbol = symbol
                }

                guard state.shouldPublishStatus(now: Date()) else {
                    return nil
                }

                return self.makeStatus(
                    state: .live,
                    seedURLText: seedURL.absoluteString,
                    fps: state.effectiveFPS,
                    frameSize: state.frameSize,
                    firstFrameLatencySeconds: state.firstFrameLatencySeconds,
                    lastSubscribedSymbol: state.lastSubscribedSymbol,
                    messageOverride: nil
                )
            }
            if let statusToPublish {
                self.publishStatus(statusToPublish)
            }
        }

        if loggingEnabled {
            let firstBinarySeconds = formatOptionalSeconds(summary.firstBinaryElapsedSeconds)
            let firstMediaSeconds = formatOptionalSeconds(summary.firstMediaElapsedSeconds)
            let firstFrameSeconds = formatOptionalSeconds(summary.firstFrameElapsedSeconds)
            print(
                "[live-session] websocket_decoded frames=\(summary.decodedFrameCount) " +
                "first_binary_seconds=\(firstBinarySeconds) " +
                "first_media_seconds=\(firstMediaSeconds) " +
                "first_frame_seconds=\(firstFrameSeconds) " +
                "bytes=\(summary.binaryByteCount)"
            )
        }

    }

    private func handlePipelineEvent(_ event: OCRPipelineEvent, sessionID: UUID) {
        guard shouldContinue(sessionID: sessionID) else {
            return
        }

        guard event.action == "subscribe_triggered", let symbol = event.symbol else {
            return
        }

        let currentStatus = latestStatusSnapshot(for: sessionID)
        publishStatus(
            makeStatus(
                state: currentStatus?.state ?? .live,
                seedURLText: currentStatus?.seedURLText ?? "",
                fps: currentStatus?.fps,
                frameSize: currentStatus?.frameSize,
                firstFrameLatencySeconds: nil,
                lastSubscribedSymbol: symbol,
                messageOverride: nil
            )
        )
    }

    private func shouldContinue(sessionID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSessionID == sessionID
    }

    private func clearSessionIfCurrent(sessionID: UUID) {
        stateLock.lock()
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        stateLock.unlock()
    }

    private func failSessionBeforeSender(
        sessionID: UUID,
        status: LiveOCRSessionStatusSnapshot
    ) {
        stateLock.lock()
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        if stoppingSessionID == sessionID {
            stoppingSessionID = nil
        }
        stateLock.unlock()

        publishStatus(status)
    }

    private func finishSessionExit(sessionID: UUID, tradingRuntime: OCRTradingCoordinatorRuntime) {
        let shouldPublishOff: Bool

        stateLock.lock()
        if activeTradingRuntime === tradingRuntime {
            activeTradingRuntime = nil
        }
        if stoppingSessionID == sessionID {
            stoppingSessionID = nil
            shouldPublishOff = activeSessionID == nil
        } else if activeSessionID == sessionID {
            activeSessionID = nil
            shouldPublishOff = true
        } else {
            shouldPublishOff = false
        }
        stateLock.unlock()

        if shouldPublishOff {
            publishStatus(.off)
        }
    }

    private func runtimeConfigSnapshot() -> CaptureRuntimeConfig? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRuntimeConfig
    }

    private func buyQuantityRatioSnapshot() -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return buyQuantityRatio
    }

    private func latestStatusSnapshot(for sessionID: UUID) -> LiveOCRSessionStatusSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSessionID == sessionID else {
            return nil
        }
        return latestStatus
    }

    private func publishStatus(_ snapshot: LiveOCRSessionStatusSnapshot) {
        stateLock.lock()
        latestStatus = snapshot
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(snapshot)
        }
    }

    private func makeStatus(
        state: LiveOCRSessionStatusSnapshot.State,
        seedURLText: String,
        fps: Double?,
        frameSize: String?,
        firstFrameLatencySeconds: Double?,
        lastSubscribedSymbol: String?,
        messageOverride: String?
    ) -> LiveOCRSessionStatusSnapshot {
        let runtimeConfig = runtimeConfigSnapshot()
        let hasPositionROI = runtimeConfig?.baseROI != nil && runtimeConfig?.manualCellROI != nil
        let hasSymbolROI = runtimeConfig?.symbolROI != nil && runtimeConfig?.manualSymbolCellROI != nil

        let headline: String
        switch state {
        case .off:
            headline = "Live stream: Off"
        case .connecting:
            headline = "Live stream: Connecting"
        case .live:
            headline = "Live stream: On"
        case .stopping:
            headline = "Live stream: Stopping"
        case .error:
            headline = "Live stream: Error"
        }

        let detail = messageOverride ?? statusMessage(
            state: state,
            fps: fps,
            frameSize: frameSize,
            firstFrameLatencySeconds: firstFrameLatencySeconds,
            lastSubscribedSymbol: lastSubscribedSymbol
        )

        return LiveOCRSessionStatusSnapshot(
            state: state,
            isRunning: state == .connecting || state == .live,
            seedURLText: seedURLText,
            headline: headline,
            detail: detail + roiStatusSuffix(hasPositionROI: hasPositionROI, hasSymbolROI: hasSymbolROI),
            fps: fps,
            frameSize: frameSize,
            lastSubscribedSymbol: lastSubscribedSymbol,
            hasPositionROI: hasPositionROI,
            hasSymbolROI: hasSymbolROI
        )
    }

    private func statusMessage(
        state: LiveOCRSessionStatusSnapshot.State,
        fps: Double?,
        frameSize: String?,
        firstFrameLatencySeconds: Double?,
        lastSubscribedSymbol: String?
    ) -> String {
        switch state {
        case .off:
            return "Enter a live stream URL to start preview/OCR."
        case .connecting:
            return "Waiting for the source to deliver the first decodable frames..."
        case .live:
            var parts: [String] = []
            if let fps {
                parts.append(String(format: "%.2f fps", fps))
            }
            if let frameSize, !frameSize.isEmpty {
                parts.append(frameSize)
            }
            if let firstFrameLatencySeconds {
                parts.append(String(format: "first frame %.2fs", firstFrameLatencySeconds))
            }
            if let lastSubscribedSymbol, !lastSubscribedSymbol.isEmpty {
                parts.append("last symbol \(lastSubscribedSymbol)")
            }
            return parts.isEmpty ? "Live OCR is running." : parts.joined(separator: "  |  ")
        case .stopping:
            return "Stopping live OCR and draining pending trading actions..."
        case .error:
            return "The live OCR session stopped with an error."
        }
    }

    private func roiStatusSuffix(hasPositionROI: Bool, hasSymbolROI: Bool) -> String {
        switch (hasPositionROI, hasSymbolROI) {
        case (false, false):
            return "  |  OCR waiting for position+symbol ROIs"
        case (true, false):
            return "  |  position OCR active, symbol OCR waiting for ROI"
        case (false, true):
            return "  |  symbol OCR active, position OCR waiting for ROI"
        case (true, true):
            return "  |  OCR active"
        }
    }

    private func activeDecodeSeconds(for summary: LocalVideoDecodingSummary) -> Double {
        if
            let first = summary.firstPresentationTimeSeconds,
            let last = summary.lastPresentationTimeSeconds,
            last > first
        {
            return last - first
        }

        return frameDuration(nominalFrameRate: summary.nominalFrameRate, frameCount: summary.frameCount) * Double(summary.frameCount)
    }

    private func frameDuration(nominalFrameRate: Double?, frameCount: Int) -> Double {
        if let nominalFrameRate, nominalFrameRate > 0 {
            return 1 / nominalFrameRate
        }
        if frameCount > 0 {
            return 1 / 30
        }
        return 0
    }

    private func formatOptionalSeconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "nil"
    }
}

private struct LiveOCRWebSocketFrameState {
    var totalFrameCount: Int
    var totalActiveDecodeSeconds: Double
    var firstFrameLatencySeconds: Double?
    var frameSize: String?
    var lastSubscribedSymbol: String?

    private var firstPresentationTimeSeconds: Double?
    private var firstOCRWallTimestamp: CFAbsoluteTime?
    private var skippedStaleOCRFrameCount = 0
    private var lastSkippedStaleOCRLogCount = 0
    private var lastStatusPublish = Date.distantPast

    init(
        totalFrameCount: Int,
        totalActiveDecodeSeconds: Double,
        firstFrameLatencySeconds: Double?,
        frameSize: String?,
        lastSubscribedSymbol: String?
    ) {
        self.totalFrameCount = totalFrameCount
        self.totalActiveDecodeSeconds = totalActiveDecodeSeconds
        self.firstFrameLatencySeconds = firstFrameLatencySeconds
        self.frameSize = frameSize
        self.lastSubscribedSymbol = lastSubscribedSymbol
    }

    mutating func recordFirstFrameLatencyIfNeeded(sessionStart: Date) {
        if firstFrameLatencySeconds == nil {
            firstFrameLatencySeconds = Date().timeIntervalSince(sessionStart)
        }
    }

    mutating func shouldProcessLiveOCRFrame(
        frame: VideoFrame,
        maximumBacklogSeconds: TimeInterval
    ) -> Bool {
        guard let presentationTimeSeconds = frame.presentationTimeSeconds else {
            return true
        }

        if let firstPresentationTimeSeconds,
           presentationTimeSeconds < firstPresentationTimeSeconds {
            resetOCRClock(presentationTimeSeconds: presentationTimeSeconds)
            return true
        }

        if firstPresentationTimeSeconds == nil || firstOCRWallTimestamp == nil {
            resetOCRClock(presentationTimeSeconds: presentationTimeSeconds)
            return true
        }

        guard let firstPresentationTimeSeconds, let firstOCRWallTimestamp else {
            return true
        }

        let mediaElapsedSeconds = presentationTimeSeconds - firstPresentationTimeSeconds
        let wallElapsedSeconds = CFAbsoluteTimeGetCurrent() - firstOCRWallTimestamp
        return wallElapsedSeconds - mediaElapsedSeconds <= maximumBacklogSeconds
    }

    mutating func recordSkippedStaleOCRFrameIfLoggable() -> Int? {
        skippedStaleOCRFrameCount += 1
        guard skippedStaleOCRFrameCount == 1 ||
            skippedStaleOCRFrameCount - lastSkippedStaleOCRLogCount >= 300
        else {
            return nil
        }

        lastSkippedStaleOCRLogCount = skippedStaleOCRFrameCount
        return skippedStaleOCRFrameCount
    }

    mutating func recordDecodedFrame(_ frame: VideoFrame) {
        totalFrameCount += 1
        frameSize = frame.sizeSummary
        if let presentationTimeSeconds = frame.presentationTimeSeconds,
           let firstPresentationTimeSeconds {
            totalActiveDecodeSeconds = max(
                totalActiveDecodeSeconds,
                presentationTimeSeconds - firstPresentationTimeSeconds
            )
        } else {
            totalActiveDecodeSeconds += Self.frameDuration(
                nominalFrameRate: frame.nominalFrameRate,
                frameCount: 1
            )
        }
    }

    mutating func shouldPublishStatus(now: Date) -> Bool {
        let shouldPublish = totalFrameCount == 1 ||
            totalFrameCount.isMultiple(of: 30) ||
            now.timeIntervalSince(lastStatusPublish) >= 0.5
        if shouldPublish {
            lastStatusPublish = now
        }
        return shouldPublish
    }

    var effectiveFPS: Double? {
        totalActiveDecodeSeconds > 0 ? Double(totalFrameCount) / totalActiveDecodeSeconds : nil
    }

    private mutating func resetOCRClock(presentationTimeSeconds: Double) {
        firstPresentationTimeSeconds = presentationTimeSeconds
        firstOCRWallTimestamp = CFAbsoluteTimeGetCurrent()
    }

    private static func frameDuration(nominalFrameRate: Double?, frameCount: Int) -> Double {
        if let nominalFrameRate, nominalFrameRate > 0 {
            return 1 / nominalFrameRate
        }
        if frameCount > 0 {
            return 1 / 30
        }
        return 0
    }
}

private final class PendingFrameSnapshotRequest {
    let sessionID: UUID
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<LiveStreamFrameSnapshot, Error>?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

private extension LiveOCRSessionController {
    func fulfillPendingFrameSnapshotIfNeeded(
        frame: VideoFrame,
        seedURL: URL,
        sessionID: UUID
    ) {
        let request: PendingFrameSnapshotRequest?
        stateLock.lock()
        if let pendingFrameSnapshotRequest, pendingFrameSnapshotRequest.sessionID == sessionID {
            request = pendingFrameSnapshotRequest
            self.pendingFrameSnapshotRequest = nil
        } else {
            request = nil
        }
        stateLock.unlock()

        guard let request else {
            return
        }

        let result: Result<LiveStreamFrameSnapshot, Error>
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if let cgImage = snapshotCIContext.createCGImage(image, from: image.extent) {
            result = .success(
                LiveStreamFrameSnapshot(
                    cgImage: cgImage,
                    width: cgImage.width,
                    height: cgImage.height,
                    sourceURL: seedURL
                )
            )
        } else {
            result = .failure(LiveStreamFrameSnapshotterError.unableToRenderFrame(seedURL))
        }

        request.result = result
        request.semaphore.signal()
    }
}
