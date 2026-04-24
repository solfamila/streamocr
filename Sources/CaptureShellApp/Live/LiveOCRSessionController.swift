import Foundation

struct LiveOCRSessionStatusSnapshot: Equatable, Sendable {
    enum State: String, Sendable {
        case off
        case connecting
        case live
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

    var errorDescription: String? {
        switch self {
        case let .invalidSeedURL(text):
            return "Invalid live stream URL: \(text)"
        case let .unsupportedSource(url):
            return "This live source is not supported by the native stream.mp4 OCR path: \(url.absoluteString)"
        }
    }
}

private enum LiveOCRSessionCancellation: Error {
    case cancelled
}

final class LiveOCRSessionController: @unchecked Sendable {
    var onStatusChanged: ((LiveOCRSessionStatusSnapshot) -> Void)?

    private let manager: TradingRuntimeManager
    private let chunkPuller = NanocosmosStreamingChunkPuller()
    private let decoder = LocalVideoFrameDecoder()
    private let stateLock = NSLock()

    private var latestStatus = LiveOCRSessionStatusSnapshot.off
    private var activeSessionID: UUID?
    private var activeRuntimeConfig: CaptureRuntimeConfig?
    private var buyQuantityRatio = 0.5

    init(manager: TradingRuntimeManager) {
        self.manager = manager
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
        stateLock.lock()
        activeSessionID = sessionID
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
            self?.runSession(sessionID: sessionID, seedURL: seedURL, loggingEnabled: loggingEnabled)
        }
    }

    func stop() {
        stateLock.lock()
        activeSessionID = nil
        stateLock.unlock()
        publishStatus(.off)
    }

    func currentStatusSnapshot() -> LiveOCRSessionStatusSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestStatus
    }

    private func runSession(sessionID: UUID, seedURL: URL, loggingEnabled: Bool) {
        let sessionStart = Date()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureShellApp-live-session-\(sessionID.uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            publishStatus(
                makeStatus(
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
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: loggingEnabled,
            recognizer: FontTemplateTextRecognizer(),
            messageSender: messageSender,
            beep: {},
            eventHandler: { [weak self] event in
                self?.handlePipelineEvent(event, sessionID: sessionID)
            }
        )

        var totalFrameCount = 0
        var totalActiveDecodeSeconds = 0.0
        var firstFrameLatencySeconds: Double?
        var frameSize: String?
        var lastSubscribedSymbol: String?
        var presentationTimeOffsetSeconds = 0.0
        var resolvedStream: ResolvedLiveStream?
        var chunkIndex = 0

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

                    let chunkURL = temporaryDirectory.appendingPathComponent("chunk-\(chunkIndex).mp4")
                    chunkIndex += 1
                    defer { try? FileManager.default.removeItem(at: chunkURL) }

                    let capturedChunk = try chunkPuller.captureChunk(
                        sourceURL: sourceURL,
                        destinationURL: chunkURL,
                        firstByteTimeoutSeconds: 8,
                        captureWindowSeconds: 1.5
                    )

                    if loggingEnabled {
                        print(
                            "[live-session] chunk_captured bytes=\(capturedChunk.byteCount) " +
                                "elapsed_seconds=\(String(format: "%.2f", capturedChunk.elapsedSeconds))"
                        )
                    }

                    let summary = try decoder.decode(
                        videoURL: capturedChunk.fileURL,
                        presentationTimeOffsetSeconds: presentationTimeOffsetSeconds
                    ) { [weak self] frame in
                        guard let self else { return }
                        guard self.shouldContinue(sessionID: sessionID) else {
                            throw LiveOCRSessionCancellation.cancelled
                        }

                        if firstFrameLatencySeconds == nil {
                            firstFrameLatencySeconds = Date().timeIntervalSince(sessionStart)
                        }

                        let adjustedRuntimeConfig = self.runtimeConfigSnapshot()?.adjustedForFrameSize(
                            width: frame.width,
                            height: frame.height,
                            displayID: 0
                        )
                        pipeline.process(frame, runtimeConfig: adjustedRuntimeConfig)
                        totalFrameCount += 1
                        frameSize = frame.sizeSummary
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
}
