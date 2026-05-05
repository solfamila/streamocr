import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal

enum OCRRegionKind: String, CaseIterable, Hashable, Sendable {
    case manualCell = "manual_cell"
    case manualSymbolCell = "manual_symbol_cell"

    func roi(from config: CaptureRuntimeConfig) -> PixelRect? {
        switch self {
        case .manualCell:
            config.manualCellROI
        case .manualSymbolCell:
            config.manualSymbolCellROI
        }
    }
}

enum OCRNormalizationPolicy {
    static func normalize(_ text: String, for region: OCRRegionKind) -> String {
        let collapsedWhitespace = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        switch region {
        case .manualCell:
            return collapsedWhitespace.replacingOccurrences(of: " ", with: "")
        case .manualSymbolCell:
            return collapsedWhitespace.uppercased()
        }
    }
}

typealias OCRTradingFrameObservationHandler = @Sendable (OCRTradingFrameObservation) -> Void

enum OCRTriggerHandlingMode: Sendable {
    // Compatibility path for the pre-coordinator trigger state machine.
    case legacyDispatcher

    // Preferred path: emit frame observations and let OCRTradingCoordinator own trading decisions.
    case frameObservationsOnly
}

enum OCRFingerprintPolicy {
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211
    private static let gridWidth = 16
    private static let gridHeight = 16
    private static let quantizationBucketSize = 64

    static func fingerprint(pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else {
            return 0
        }

        let effectiveGridWidth = min(gridWidth, width)
        let effectiveGridHeight = min(gridHeight, height)
        let cellCount = effectiveGridWidth * effectiveGridHeight
        var lumaTotals = Array(repeating: 0, count: cellCount)
        var pixelCounts = Array(repeating: 0, count: cellCount)

        let basePointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let rowPointer = basePointer.advanced(by: y * bytesPerRow)
            let cellY = min(effectiveGridHeight - 1, y * effectiveGridHeight / height)
            for x in 0..<width {
                let pixelPointer = rowPointer.advanced(by: x * 4)
                let luma = (299 * Int(pixelPointer[2]) + 587 * Int(pixelPointer[1]) + 114 * Int(pixelPointer[0])) / 1000
                let cellX = min(effectiveGridWidth - 1, x * effectiveGridWidth / width)
                let index = cellY * effectiveGridWidth + cellX
                lumaTotals[index] += luma
                pixelCounts[index] += 1
            }
        }

        var hash = fnvOffsetBasis
        mix(&hash, byte: UInt8(width & 0xFF))
        mix(&hash, byte: UInt8((width >> 8) & 0xFF))
        mix(&hash, byte: UInt8(height & 0xFF))
        mix(&hash, byte: UInt8((height >> 8) & 0xFF))
        mix(&hash, byte: UInt8(effectiveGridWidth))
        mix(&hash, byte: UInt8(effectiveGridHeight))
        for index in 0..<cellCount {
            let averageLuma = pixelCounts[index] > 0 ? lumaTotals[index] / pixelCounts[index] : 0
            let quantizedLuma = UInt8(max(0, min(15, averageLuma / quantizationBucketSize)))
            mix(&hash, byte: quantizedLuma)
        }
        return hash
    }

    private static func mix(_ hash: inout UInt64, byte: UInt8) {
        hash ^= UInt64(byte)
        hash &*= fnvPrime
    }
}

private struct ChangedRecognitionContext {
    let frameNumber: Int
    let region: OCRRegionKind
    let gate: String
    let fingerprint: UInt64
    let frameIngressTimestamp: CFAbsoluteTime
    let regionStartTimestamp: CFAbsoluteTime
    let presentationTimeSeconds: Double?
    let cropMilliseconds: Double
    let metalMilliseconds: Double
    let fingerprintMilliseconds: Double
    let gatingMilliseconds: Double
    let symbolGeneration: UInt64
}

private struct DeferredSymbolReplay {
    let frameNumber: Int
    let fingerprint: UInt64
    let frameIngressTimestamp: CFAbsoluteTime
    let regionStartTimestamp: CFAbsoluteTime
    let presentationTimeSeconds: Double?
    let cropMilliseconds: Double
    let metalMilliseconds: Double
    let fingerprintMilliseconds: Double
    let gatingMilliseconds: Double
    let shouldLogEvaluation: Bool
    let symbolGeneration: UInt64
}

private final class AsyncPixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

private struct FrameObservationDraft {
    let frameNumber: Int
    let mediaTime: Double?
    var symbol: OCRTradingSymbolObservation?
    var manualCell: OCRTradingManualCellObservation?

    var hasContent: Bool {
        symbol != nil || manualCell != nil
    }

    func makeObservation() -> OCRTradingFrameObservation {
        OCRTradingFrameObservation(
            frameNumber: frameNumber,
            mediaTime: mediaTime,
            symbol: symbol,
            manualCell: manualCell
        )
    }
}

private final class PipelineStateLockAccessGuard: @unchecked Sendable {
    #if DEBUG
    private var ownerThreadID: UInt64?
    private var recursionDepth = 0
    #endif

    func didLock() {
        #if DEBUG
        let threadID = currentThreadID()
        if let ownerThreadID {
            assert(ownerThreadID == threadID, "Pipeline state lock was reacquired from a different thread")
        } else {
            ownerThreadID = threadID
        }
        recursionDepth += 1
        #endif
    }

    func didUnlock() {
        #if DEBUG
        assert(recursionDepth > 0, "Pipeline state lock recursion depth underflow")
        recursionDepth -= 1
        if recursionDepth == 0 {
            ownerThreadID = nil
        }
        #endif
    }

    func assertHeld(file: StaticString = #fileID, line: UInt = #line) {
        #if DEBUG
        let threadID = currentThreadID()
        assert(
            recursionDepth > 0 && ownerThreadID == threadID,
            "TriggerDispatcher sync access requires the pipeline state lock to be held",
            file: file,
            line: line
        )
        #endif
    }

    #if DEBUG
    private func currentThreadID() -> UInt64 {
        UInt64(pthread_mach_thread_np(pthread_self()))
    }
    #endif
}

final class LowLatencyOCRFramePipeline: FramePipeline, @unchecked Sendable {
    private let ciContext: CIContext
    private let usesMetal: Bool
    private let preprocessor: OCRRegionPreprocessor
    private let loggingEnabled: Bool
    private let unchangedLogCadence: Int
    private let manualCellRearmConfirmationFrames: Int
    private let manualCellTriggerConfirmationFrames: Int
    private let manualSymbolSamplingIntervalFrames: Int
    private let manualSymbolFreshOCRIntervalSeconds: CFAbsoluteTime
    private let manualSymbolTriggerConfirmationFrames: Int
    private let asyncSymbolRecognitionEnabled: Bool
    private let manualCellRecognizer: any OCRTextRecognizing
    private let manualSymbolRecognizer: any OCRTextRecognizing
    private let legacyMessageSender: any TradingMessageSending
    private let beep: @Sendable () -> Void
    private let eventHandler: OCRPipelineEventHandler?
    private let frameObservationHandler: OCRTradingFrameObservationHandler?
    private let triggerHandlingMode: OCRTriggerHandlingMode
    private let stateLock = NSRecursiveLock()
    private let stateLockAccessGuard = PipelineStateLockAccessGuard()
    private var triggerStateMachine: TradingTriggerStateMachine?
    private var triggerDispatcher: TriggerDispatcher?
    private let symbolRecognitionQueue = DispatchQueue(label: "capture-shell.symbol-ocr", qos: .userInitiated)
    private let timeProvider: @Sendable () -> CFAbsoluteTime

    private var frameCount = 0
    private var didLogBackend = false
    private var regionTrackers: [OCRRegionKind: OCRRegionTracker] = [:]
    private var symbolGeneration: UInt64 = 0
    private var deferredSymbolReplay: DeferredSymbolReplay?
    private var lastManualSymbolFreshOCRTimestamp: CFAbsoluteTime?
    private var activeFrameObservationDraft: FrameObservationDraft?

    init(
        loggingEnabled: Bool = true,
        unchangedLogCadence: Int = 30,
        manualCellRearmConfirmationFrames: Int = 12,
        manualCellTriggerConfirmationFrames: Int = 2,
        manualSymbolSamplingIntervalFrames: Int = 30,
        manualSymbolFreshOCRIntervalSeconds: CFAbsoluteTime = 10,
        manualSymbolTriggerConfirmationFrames: Int = 2,
        recognizer: any OCRTextRecognizing = FontTemplateTextRecognizer(),
        symbolRecognizer: (any OCRTextRecognizing)? = nil,
        asyncSymbolRecognitionEnabled: Bool? = nil,
        messageSender: any TradingMessageSending = DiscardingTradingMessageSender(),
        beep: @escaping @Sendable () -> Void = {
            DispatchQueue.main.async {
                NSSound.beep()
            }
        },
        eventHandler: OCRPipelineEventHandler? = nil,
        frameObservationHandler: OCRTradingFrameObservationHandler? = nil,
        triggerHandlingMode: OCRTriggerHandlingMode = .frameObservationsOnly,
        timeProvider: @escaping @Sendable () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
    ) {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(
                mtlDevice: device,
                options: [.cacheIntermediates: false]
            )
            usesMetal = true
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
            usesMetal = false
        }

        preprocessor = OCRRegionPreprocessor(ciContext: ciContext)
        self.loggingEnabled = loggingEnabled
        self.unchangedLogCadence = max(1, unchangedLogCadence)
        self.manualCellRearmConfirmationFrames = manualCellRearmConfirmationFrames
        self.manualCellTriggerConfirmationFrames = manualCellTriggerConfirmationFrames
        self.manualSymbolSamplingIntervalFrames = max(1, manualSymbolSamplingIntervalFrames)
        self.manualSymbolFreshOCRIntervalSeconds = max(0.1, manualSymbolFreshOCRIntervalSeconds)
        self.manualSymbolTriggerConfirmationFrames = manualSymbolTriggerConfirmationFrames
        self.timeProvider = timeProvider
        manualCellRecognizer = recognizer
        if let symbolRecognizer {
            manualSymbolRecognizer = symbolRecognizer
        } else if recognizer is FontTemplateTextRecognizer {
            manualSymbolRecognizer = FontTemplateTextRecognizer()
        } else {
            preconditionFailure("Provide an explicit symbolRecognizer when using a custom manual-cell recognizer")
        }
        if let asyncSymbolRecognitionEnabled {
            self.asyncSymbolRecognitionEnabled = asyncSymbolRecognitionEnabled
        } else {
            self.asyncSymbolRecognitionEnabled =
                recognizer is FontTemplateTextRecognizer ||
                manualSymbolRecognizer is FontTemplateTextRecognizer
        }
        self.legacyMessageSender = messageSender
        self.beep = beep
        self.eventHandler = eventHandler
        self.frameObservationHandler = frameObservationHandler
        self.triggerHandlingMode = triggerHandlingMode

        if triggerHandlingMode == .legacyDispatcher {
            let stateMachine = TradingTriggerStateMachine(
                manualCellRearmConfirmationFrames: manualCellRearmConfirmationFrames,
                manualCellTriggerConfirmationFrames: manualCellTriggerConfirmationFrames,
                manualSymbolTriggerConfirmationFrames: manualSymbolTriggerConfirmationFrames
            )
            triggerStateMachine = stateMachine
            triggerDispatcher = Self.makeTriggerDispatcher(
                stateLock: stateLock,
                stateLockAccessGuard: stateLockAccessGuard,
                loggingEnabled: loggingEnabled,
                messageSender: messageSender,
                eventHandler: eventHandler,
                triggerStateMachine: stateMachine
            )
        } else {
            triggerStateMachine = nil
            triggerDispatcher = nil
        }
    }

    private static func makeTriggerDispatcher(
        stateLock: NSRecursiveLock,
        stateLockAccessGuard: PipelineStateLockAccessGuard,
        loggingEnabled: Bool,
        messageSender: any TradingMessageSending,
        eventHandler: OCRPipelineEventHandler?,
        triggerStateMachine: TradingTriggerStateMachine
    ) -> TriggerDispatcher {
        TriggerDispatcher(
            withPipelineState: { [stateLock, stateLockAccessGuard] action in
                stateLock.lock()
                stateLockAccessGuard.didLock()
                defer {
                    stateLockAccessGuard.didUnlock()
                    stateLock.unlock()
                }
                action()
            },
            assertPipelineStateHeld: { [stateLockAccessGuard] in
                stateLockAccessGuard.assertHeld()
            },
            loggingEnabled: loggingEnabled,
            messageSender: messageSender,
            eventHandler: eventHandler,
            triggerStateMachine: triggerStateMachine
        )
    }

    func reset() {
        withStateLock {
            frameCount = 0
            didLogBackend = false
            regionTrackers.removeAll(keepingCapacity: true)
            triggerDispatcher?.reset()
            symbolGeneration &+= 1
            deferredSymbolReplay = nil
            lastManualSymbolFreshOCRTimestamp = nil
            activeFrameObservationDraft = nil
            triggerStateMachine?.reset()
        }
    }

    func process(_ frame: VideoFrame, runtimeConfig: CaptureRuntimeConfig?) {
        withStateLock {
            frameCount += 1
            let frameIngressTimestamp = timeProvider()
            beginFrameObservation(frameNumber: frameCount, mediaTime: frame.presentationTimeSeconds)
            defer {
                flushActiveFrameObservation()
            }

            guard let runtimeConfig else {
                if shouldLog(count: frameCount, cadence: 120) {
                    print("[ocr] frame=\(frameCount) gate=no_runtime_config")
                }
                return
            }

            let sourcePixelBuffer = frame.pixelBuffer

            if loggingEnabled && !didLogBackend {
                didLogBackend = true
                print("[ocr] preprocess_path=\(usesMetal ? "metal" : "cpu_fallback")")
            }

            if runtimeConfig.manualSymbolCellROI == nil {
                regionTrackers.removeValue(forKey: .manualSymbolCell)
                deferredSymbolReplay = nil
                lastManualSymbolFreshOCRTimestamp = nil
                triggerStateMachine?.clearManualSymbolState()
                emitSymbolObservation(
                    frameNumber: frameCount,
                    presentationTimeSeconds: frame.presentationTimeSeconds,
                    fingerprint: nil,
                    recognition: nil,
                    recognitionState: .notConfigured
                )
            }

            var shouldDeferManualCellForSymbolRefresh = false
            if runtimeConfig.manualSymbolCellROI != nil {
                let symbolFreshnessTimestamp = frame.presentationTimeSeconds ?? frameIngressTimestamp
                let symbolSamplingDecision = manualSymbolSamplingDecision(now: symbolFreshnessTimestamp)
                let didStartFreshOCR = processRegion(
                    .manualSymbolCell,
                    sourcePixelBuffer: sourcePixelBuffer,
                    runtimeConfig: runtimeConfig,
                    frameIngressTimestamp: frameIngressTimestamp,
                    presentationTimeSeconds: frame.presentationTimeSeconds,
                    forceFreshOCR: symbolSamplingDecision.forceFreshOCR,
                    evaluateUnchangedRecognition: symbolSamplingDecision.shouldProcess
                )
                if didStartFreshOCR {
                    lastManualSymbolFreshOCRTimestamp = symbolFreshnessTimestamp
                }
                shouldDeferManualCellForSymbolRefresh = isManualSymbolRecognitionPending()
            }

            if shouldDeferManualCellForSymbolRefresh {
                if loggingEnabled && shouldLog(count: frameCount, cadence: unchangedLogCadence) {
                    print("[ocr] frame=\(frameCount) region=\(OCRRegionKind.manualCell.rawValue) gate=symbol_ocr_pending skip_ocr=true")
                }
                return
            }

            processRegion(
                .manualCell,
                sourcePixelBuffer: sourcePixelBuffer,
                runtimeConfig: runtimeConfig,
                frameIngressTimestamp: frameIngressTimestamp,
                presentationTimeSeconds: frame.presentationTimeSeconds
            )
        }
    }

    private func isManualSymbolRecognitionPending() -> Bool {
        guard let tracker = regionTrackers[.manualSymbolCell] else {
            return false
        }

        return tracker.lastFingerprint != nil && tracker.lastRecognition == nil
    }

    private func manualSymbolSamplingDecision(now: CFAbsoluteTime) -> (shouldProcess: Bool, forceFreshOCR: Bool) {
        let shouldProcessByFrameCadence = matchesCadence(count: frameCount, cadence: manualSymbolSamplingIntervalFrames)
        let shouldForceFreshOCR: Bool
        if let lastManualSymbolFreshOCRTimestamp {
            let elapsedSeconds = now - lastManualSymbolFreshOCRTimestamp
            shouldForceFreshOCR = elapsedSeconds < 0 || elapsedSeconds >= manualSymbolFreshOCRIntervalSeconds
        } else {
            shouldForceFreshOCR = true
        }
        return (
            shouldProcess: shouldProcessByFrameCadence || shouldForceFreshOCR,
            forceFreshOCR: shouldForceFreshOCR
        )
    }

    @discardableResult
    private func processRegion(
        _ region: OCRRegionKind,
        sourcePixelBuffer: CVPixelBuffer,
        runtimeConfig: CaptureRuntimeConfig,
        frameIngressTimestamp: CFAbsoluteTime,
        presentationTimeSeconds: Double?,
        forceFreshOCR: Bool = false,
        evaluateUnchangedRecognition: Bool = true
    ) -> Bool {
        guard let configuredROI = region.roi(from: runtimeConfig) else {
            return false
        }

        guard
            let roi = configuredROI.clamped(
                maxWidth: CVPixelBufferGetWidth(sourcePixelBuffer),
                maxHeight: CVPixelBufferGetHeight(sourcePixelBuffer)
            )
        else {
            if loggingEnabled {
                print("[ocr] frame=\(frameCount) region=\(region.rawValue) gate=invalid_roi roi=\(configuredROI.summary)")
            }
            return false
        }

        let regionStartTimestamp = CFAbsoluteTimeGetCurrent()

        guard let preprocessResult = preprocessor.preprocess(sourcePixelBuffer: sourcePixelBuffer, roi: roi, region: region) else {
            if loggingEnabled {
                print("[ocr] frame=\(frameCount) region=\(region.rawValue) gate=preprocess_failed roi=\(roi.summary)")
            }
            return false
        }

        let fingerprintStart = CFAbsoluteTimeGetCurrent()
        let fingerprint = OCRFingerprintPolicy.fingerprint(pixelBuffer: preprocessResult.pixelBuffer)
        let fingerprintMilliseconds = elapsedMilliseconds(since: fingerprintStart)

        let gatingStart = CFAbsoluteTimeGetCurrent()
        var tracker = regionTrackers[region] ?? OCRRegionTracker()
        if tracker.lastFingerprint == fingerprint, !forceFreshOCR {
            let streak = tracker.markUnchanged()
            regionTrackers[region] = tracker
            let gatingMilliseconds = elapsedMilliseconds(since: gatingStart)

            if shouldLog(count: streak, cadence: unchangedLogCadence) {
                let totalMilliseconds = elapsedMilliseconds(since: regionStartTimestamp)
                print(
                    "[ocr] frame=\(frameCount) region=\(region.rawValue) gate=unchanged skip_ocr=true streak=\(streak) " +
                        "fingerprint=\(fingerprintHex(fingerprint)) crop_ms=\(format(preprocessResult.cropMilliseconds)) " +
                        "metal_ms=\(format(preprocessResult.metalMilliseconds)) fingerprint_ms=\(format(fingerprintMilliseconds)) " +
                        "gating_ms=\(format(gatingMilliseconds)) " +
                        "total_ms=\(format(totalMilliseconds))"
                )
            }

            if region == .manualSymbolCell, tracker.lastRecognition == nil {
                emitSymbolObservation(
                    frameNumber: frameCount,
                    presentationTimeSeconds: presentationTimeSeconds,
                    fingerprint: fingerprint,
                    recognition: nil,
                    recognitionState: .ocrPending
                )
                deferredSymbolReplay = DeferredSymbolReplay(
                    frameNumber: frameCount,
                    fingerprint: fingerprint,
                    frameIngressTimestamp: frameIngressTimestamp,
                    regionStartTimestamp: regionStartTimestamp,
                    presentationTimeSeconds: presentationTimeSeconds,
                    cropMilliseconds: preprocessResult.cropMilliseconds,
                    metalMilliseconds: preprocessResult.metalMilliseconds,
                    fingerprintMilliseconds: fingerprintMilliseconds,
                    gatingMilliseconds: gatingMilliseconds,
                    shouldLogEvaluation: shouldLog(count: streak, cadence: unchangedLogCadence),
                    symbolGeneration: symbolGeneration
                )
                return false
            }

            if region == .manualSymbolCell, !evaluateUnchangedRecognition {
                emitSymbolObservation(
                    frameNumber: frameCount,
                    presentationTimeSeconds: presentationTimeSeconds,
                    fingerprint: fingerprint,
                    recognition: tracker.lastRecognition,
                    recognitionState: .unchanged
                )
                return false
            }

            replayCachedRecognitionForTriggerIfNeeded(
                region: region,
                recognition: tracker.lastRecognition,
                fingerprint: fingerprint,
                frameIngressTimestamp: frameIngressTimestamp,
                regionStartTimestamp: regionStartTimestamp,
                presentationTimeSeconds: presentationTimeSeconds,
                cropMilliseconds: preprocessResult.cropMilliseconds,
                metalMilliseconds: preprocessResult.metalMilliseconds,
                fingerprintMilliseconds: fingerprintMilliseconds,
                gatingMilliseconds: gatingMilliseconds,
                shouldLogEvaluation: shouldLog(count: streak, cadence: unchangedLogCadence)
            )
            return false
        }

        let gate = forceFreshOCR && tracker.lastFingerprint == fingerprint ? "forced_resample" : "changed"
        if region == .manualSymbolCell {
            deferredSymbolReplay = nil
        }
        tracker.markChanged(fingerprint: fingerprint)
        regionTrackers[region] = tracker
        let gatingMilliseconds = elapsedMilliseconds(since: gatingStart)
        if region == .manualSymbolCell {
            emitSymbolObservation(
                frameNumber: frameCount,
                presentationTimeSeconds: presentationTimeSeconds,
                fingerprint: fingerprint,
                recognition: nil,
                recognitionState: .changedFingerprintPendingOCR
            )
        }
        let context = ChangedRecognitionContext(
            frameNumber: frameCount,
            region: region,
            gate: gate,
            fingerprint: fingerprint,
            frameIngressTimestamp: frameIngressTimestamp,
            regionStartTimestamp: regionStartTimestamp,
            presentationTimeSeconds: presentationTimeSeconds,
            cropMilliseconds: preprocessResult.cropMilliseconds,
            metalMilliseconds: preprocessResult.metalMilliseconds,
            fingerprintMilliseconds: fingerprintMilliseconds,
            gatingMilliseconds: gatingMilliseconds,
            symbolGeneration: symbolGeneration
        )

        if region == .manualSymbolCell, asyncSymbolRecognitionEnabled {
            enqueueAsyncSymbolRecognition(pixelBuffer: preprocessResult.pixelBuffer, context: context)
            return true
        }

        let ocrStart = CFAbsoluteTimeGetCurrent()
        let recognition = recognizeText(
            in: preprocessResult.pixelBuffer,
            region: region,
            recognizer: recognizer(for: region)
        )
        let ocrMilliseconds = elapsedMilliseconds(since: ocrStart)
        let ocrDetectedTimestamp = CFAbsoluteTimeGetCurrent()

        processChangedRecognition(
            recognition: recognition,
            context: context,
            ocrMilliseconds: ocrMilliseconds,
            ocrDetectedTimestamp: ocrDetectedTimestamp,
            shouldLogEvaluation: loggingEnabled
        )
        return true
    }

    private func replayCachedRecognitionForTriggerIfNeeded(
        region: OCRRegionKind,
        recognition: OCRRecognitionResult?,
        fingerprint: UInt64,
        frameIngressTimestamp: CFAbsoluteTime,
        regionStartTimestamp: CFAbsoluteTime,
        presentationTimeSeconds: Double?,
        cropMilliseconds: Double,
        metalMilliseconds: Double,
        fingerprintMilliseconds: Double,
        gatingMilliseconds: Double,
        shouldLogEvaluation: Bool
    ) {
        guard let recognition else {
            return
        }

        emitRecognitionObservation(
            region: region,
            frameNumber: frameCount,
            presentationTimeSeconds: presentationTimeSeconds,
            fingerprint: fingerprint,
            recognition: recognition
        )

        guard triggerHandlingMode == .legacyDispatcher else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        handleTriggerBehavior(
            for: region,
            frameNumber: frameCount,
            recognition: recognition,
            timings: TriggerStageTimings(
                frameIngressTimestamp: frameIngressTimestamp,
                regionStartTimestamp: regionStartTimestamp,
                ocrDetectedTimestamp: now,
                presentationTimeSeconds: presentationTimeSeconds,
                cropMilliseconds: cropMilliseconds,
                metalMilliseconds: metalMilliseconds,
                fingerprintMilliseconds: fingerprintMilliseconds,
                gatingMilliseconds: gatingMilliseconds,
                ocrMilliseconds: 0
            ),
            shouldLogEvaluation: shouldLogEvaluation
        )
    }

    private func recognizer(for region: OCRRegionKind) -> any OCRTextRecognizing {
        switch region {
        case .manualCell:
            manualCellRecognizer
        case .manualSymbolCell:
            manualSymbolRecognizer
        }
    }

    private func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        region: OCRRegionKind,
        recognizer: any OCRTextRecognizing
    ) -> OCRRecognitionResult {
        let recognition = recognizer.recognizeText(in: pixelBuffer, region: region)
        let normalizedText = OCRNormalizationPolicy.normalize(recognition.rawText, for: region)
        return OCRRecognitionResult(
            rawText: recognition.rawText,
            normalizedText: normalizedText,
            confidence: recognition.confidence
        )
    }

    private func enqueueAsyncSymbolRecognition(
        pixelBuffer: CVPixelBuffer,
        context: ChangedRecognitionContext
    ) {
        let pixelBufferBox = AsyncPixelBufferBox(pixelBuffer: pixelBuffer)
        let recognizer = manualSymbolRecognizer
        symbolRecognitionQueue.async { [weak self] in
            guard let self else {
                return
            }

            let ocrStart = CFAbsoluteTimeGetCurrent()
            let recognition = self.recognizeText(
                in: pixelBufferBox.pixelBuffer,
                region: .manualSymbolCell,
                recognizer: recognizer
            )
            let ocrMilliseconds = self.elapsedMilliseconds(since: ocrStart)
            let ocrDetectedTimestamp = CFAbsoluteTimeGetCurrent()

            self.finishAsyncSymbolRecognition(
                recognition: recognition,
                context: context,
                ocrMilliseconds: ocrMilliseconds,
                ocrDetectedTimestamp: ocrDetectedTimestamp
            )
        }
    }

    private func finishAsyncSymbolRecognition(
        recognition: OCRRecognitionResult,
        context: ChangedRecognitionContext,
        ocrMilliseconds: Double,
        ocrDetectedTimestamp: CFAbsoluteTime
    ) {
        withStateLock {
            guard context.symbolGeneration == symbolGeneration else {
                return
            }

            guard regionTrackers[context.region]?.lastFingerprint == context.fingerprint else {
                return
            }

            processChangedRecognition(
                recognition: recognition,
                context: context,
                ocrMilliseconds: ocrMilliseconds,
                ocrDetectedTimestamp: ocrDetectedTimestamp,
                shouldLogEvaluation: loggingEnabled
            )
            flushDeferredSymbolReplayIfNeeded(recognition: recognition)
        }
    }

    private func processChangedRecognition(
        recognition: OCRRecognitionResult,
        context: ChangedRecognitionContext,
        ocrMilliseconds: Double,
        ocrDetectedTimestamp: CFAbsoluteTime,
        shouldLogEvaluation: Bool
    ) {
        let totalMilliseconds = max(0, (ocrDetectedTimestamp - context.regionStartTimestamp) * 1_000)
        var tracker = regionTrackers[context.region] ?? OCRRegionTracker()
        tracker.lastRecognition = recognition
        regionTrackers[context.region] = tracker

        let escapedNormalizedText = escapedForLog(recognition.normalizedText)
        let escapedRawText = escapedForLog(recognition.rawText)
        if loggingEnabled {
            print(
                "[ocr] frame=\(context.frameNumber) region=\(context.region.rawValue) gate=\(context.gate) skip_ocr=false " +
                    "fingerprint=\(fingerprintHex(context.fingerprint)) crop_ms=\(format(context.cropMilliseconds)) " +
                    "metal_ms=\(format(context.metalMilliseconds)) fingerprint_ms=\(format(context.fingerprintMilliseconds)) " +
                    "gating_ms=\(format(context.gatingMilliseconds)) " +
                    "ocr_ms=\(format(ocrMilliseconds)) total_ms=\(format(totalMilliseconds)) " +
                    "raw_text=\"\(escapedRawText)\" normalized_text=\"\(escapedNormalizedText)\" " +
                    "confidence=\(format(recognition.confidence, precision: 3))"
            )
        }

        eventHandler?(
            OCRPipelineEvent(
                kind: .recognition,
                frameNumber: context.frameNumber,
                region: context.region.rawValue,
                action: context.gate == "forced_resample" ? "ocr_resampled" : "ocr_changed",
                rawText: recognition.rawText,
                normalizedText: recognition.normalizedText,
                confidence: recognition.confidence,
                symbol: context.region == .manualSymbolCell ? TradingMessageContract.normalizedOCRSymbol(recognition.normalizedText) : nil,
                parsedInteger: context.region == .manualCell ? ManualCellIntegerPolicy.parseInteger(recognition.normalizedText) : nil,
                isDuplicate: nil,
                isZeroOrEmpty: nil,
                presentationTimeSeconds: context.presentationTimeSeconds
            )
        )

        emitRecognitionObservation(
            region: context.region,
            frameNumber: context.frameNumber,
            presentationTimeSeconds: context.presentationTimeSeconds,
            fingerprint: context.fingerprint,
            recognition: recognition
        )

        guard triggerHandlingMode == .legacyDispatcher else {
            return
        }

        handleTriggerBehavior(
            for: context.region,
            frameNumber: context.frameNumber,
            recognition: recognition,
            timings: TriggerStageTimings(
                frameIngressTimestamp: context.frameIngressTimestamp,
                regionStartTimestamp: context.regionStartTimestamp,
                ocrDetectedTimestamp: ocrDetectedTimestamp,
                presentationTimeSeconds: context.presentationTimeSeconds,
                cropMilliseconds: context.cropMilliseconds,
                metalMilliseconds: context.metalMilliseconds,
                fingerprintMilliseconds: context.fingerprintMilliseconds,
                gatingMilliseconds: context.gatingMilliseconds,
                ocrMilliseconds: ocrMilliseconds
            ),
            shouldLogEvaluation: shouldLogEvaluation
        )
    }

    private func flushDeferredSymbolReplayIfNeeded(recognition: OCRRecognitionResult) {
        guard let deferredSymbolReplay else {
            return
        }

        guard deferredSymbolReplay.symbolGeneration == symbolGeneration else {
            self.deferredSymbolReplay = nil
            return
        }

        guard regionTrackers[.manualSymbolCell]?.lastFingerprint == deferredSymbolReplay.fingerprint else {
            self.deferredSymbolReplay = nil
            return
        }

        self.deferredSymbolReplay = nil
        guard triggerHandlingMode == .legacyDispatcher else {
            emitSymbolObservation(
                frameNumber: deferredSymbolReplay.frameNumber,
                presentationTimeSeconds: deferredSymbolReplay.presentationTimeSeconds,
                fingerprint: deferredSymbolReplay.fingerprint,
                recognition: recognition,
                recognitionState: .recognized
            )
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        handleTriggerBehavior(
            for: .manualSymbolCell,
            frameNumber: deferredSymbolReplay.frameNumber,
            recognition: recognition,
            timings: TriggerStageTimings(
                frameIngressTimestamp: deferredSymbolReplay.frameIngressTimestamp,
                regionStartTimestamp: deferredSymbolReplay.regionStartTimestamp,
                ocrDetectedTimestamp: now,
                presentationTimeSeconds: deferredSymbolReplay.presentationTimeSeconds,
                cropMilliseconds: deferredSymbolReplay.cropMilliseconds,
                metalMilliseconds: deferredSymbolReplay.metalMilliseconds,
                fingerprintMilliseconds: deferredSymbolReplay.fingerprintMilliseconds,
                gatingMilliseconds: deferredSymbolReplay.gatingMilliseconds,
                ocrMilliseconds: 0
            ),
            shouldLogEvaluation: deferredSymbolReplay.shouldLogEvaluation
        )
    }

    private func handleTriggerBehavior(
        for region: OCRRegionKind,
        frameNumber: Int,
        recognition: OCRRecognitionResult,
        timings: TriggerStageTimings?,
        shouldLogEvaluation: Bool
    ) {
        switch region {
        case .manualCell:
            handleManualCellBehavior(
                frameNumber: frameNumber,
                recognition: recognition,
                timings: timings,
                shouldLogEvaluation: shouldLogEvaluation
            )
        case .manualSymbolCell:
            handleManualSymbolBehavior(
                frameNumber: frameNumber,
                recognition: recognition,
                timings: timings,
                shouldLogEvaluation: shouldLogEvaluation
            )
        }
    }

    private func emitRecognitionObservation(
        region: OCRRegionKind,
        frameNumber: Int,
        presentationTimeSeconds: Double?,
        fingerprint: UInt64?,
        recognition: OCRRecognitionResult
    ) {
        switch region {
        case .manualCell:
            emitManualCellObservation(
                frameNumber: frameNumber,
                presentationTimeSeconds: presentationTimeSeconds,
                observation: OCRTradingManualCellObservation(
                    rawText: recognition.rawText,
                    normalizedText: recognition.normalizedText,
                    confidence: recognition.confidence
                )
            )
        case .manualSymbolCell:
            emitSymbolObservation(
                frameNumber: frameNumber,
                presentationTimeSeconds: presentationTimeSeconds,
                fingerprint: fingerprint,
                recognition: recognition,
                recognitionState: .recognized
            )
        }
    }

    private func emitSymbolObservation(
        frameNumber: Int,
        presentationTimeSeconds: Double?,
        fingerprint: UInt64?,
        recognition: OCRRecognitionResult?,
        recognitionState: OCRTradingRecognitionState
    ) {
        emitFrameObservationComponent(
            frameNumber: frameNumber,
            presentationTimeSeconds: presentationTimeSeconds,
            symbol: OCRTradingSymbolObservation(
                fingerprint: fingerprint,
                recognition: recognition.map {
                    OCRTradingTextObservation(
                        rawText: $0.rawText,
                        normalizedText: $0.normalizedText,
                        confidence: $0.confidence
                    )
                },
                recognitionState: recognitionState
            )
        )
    }

    private func emitManualCellObservation(
        frameNumber: Int,
        presentationTimeSeconds: Double?,
        observation: OCRTradingManualCellObservation
    ) {
        emitFrameObservationComponent(
            frameNumber: frameNumber,
            presentationTimeSeconds: presentationTimeSeconds,
            manualCell: observation
        )
    }

    private func beginFrameObservation(frameNumber: Int, mediaTime: Double?) {
        activeFrameObservationDraft = FrameObservationDraft(
            frameNumber: frameNumber,
            mediaTime: mediaTime,
            symbol: nil,
            manualCell: nil
        )
    }

    private func emitFrameObservationComponent(
        frameNumber: Int,
        presentationTimeSeconds: Double?,
        symbol: OCRTradingSymbolObservation? = nil,
        manualCell: OCRTradingManualCellObservation? = nil
    ) {
        guard
            activeFrameObservationDraft?.frameNumber == frameNumber,
            activeFrameObservationDraft?.mediaTime == presentationTimeSeconds
        else {
            emitFrameObservationNow(
                OCRTradingFrameObservation(
                    frameNumber: frameNumber,
                    mediaTime: presentationTimeSeconds,
                    symbol: symbol,
                    manualCell: manualCell
                )
            )
            return
        }

        if let symbol {
            activeFrameObservationDraft?.symbol = symbol
        }
        if let manualCell {
            activeFrameObservationDraft?.manualCell = manualCell
        }
    }

    private func flushActiveFrameObservation() {
        guard let draft = activeFrameObservationDraft else {
            return
        }
        activeFrameObservationDraft = nil
        guard draft.hasContent else {
            return
        }
        emitFrameObservationNow(draft.makeObservation())
    }

    private func emitFrameObservationNow(_ observation: OCRTradingFrameObservation) {
        frameObservationHandler?(observation)
    }

    private func handleManualCellBehavior(
        frameNumber: Int,
        recognition: OCRRecognitionResult,
        timings: TriggerStageTimings?,
        shouldLogEvaluation: Bool
    ) {
        guard let triggerStateMachine, let triggerDispatcher else {
            return
        }

        let triggerEvaluationStart = CFAbsoluteTimeGetCurrent()
        let evaluation = triggerStateMachine.evaluateManualCell(
            normalizedText: recognition.normalizedText,
            confidence: recognition.confidence
        )
        triggerDispatcher.invalidatePendingBuyIfNeeded(evaluation: evaluation)
        triggerDispatcher.invalidatePendingSellAfterManualCellRearm(evaluation)
        triggerDispatcher.invalidatePendingSubscribeAfterManualCellRearm(evaluation)
        let triggerEvaluationMilliseconds = elapsedMilliseconds(since: triggerEvaluationStart)
        let decisionStart = CFAbsoluteTimeGetCurrent()
        let dispatchDecision = triggerDispatcher.manualCellDispatchDecision(for: evaluation)
        let decisionMilliseconds = elapsedMilliseconds(since: decisionStart)

        if dispatchDecision.shouldDispatchTrigger {
            let triggerEvent = OCRPipelineEvent(
                kind: .trigger,
                frameNumber: frameNumber,
                region: OCRRegionKind.manualCell.rawValue,
                action: dispatchDecision.action,
                rawText: recognition.rawText,
                normalizedText: evaluation.normalizedText,
                confidence: recognition.confidence,
                symbol: nil,
                parsedInteger: evaluation.integerValue,
                isDuplicate: evaluation.isDuplicate,
                isZeroOrEmpty: evaluation.isZeroOrEmpty,
                presentationTimeSeconds: timings?.presentationTimeSeconds
            )
            eventHandler?(triggerEvent)
            switch dispatchDecision.event {
            case .some(.buy):
                triggerDispatcher.dispatchBuy(
                    triggerEvent: triggerEvent,
                    integerValue: evaluation.integerValue,
                    timings: timings,
                    triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
                    buyDecisionMilliseconds: decisionMilliseconds
                )
            case .some(.sell):
                triggerDispatcher.dispatchSell(
                    triggerEvent: triggerEvent,
                    integerValue: evaluation.integerValue,
                    openPositionPeakValue: evaluation.openPositionPeakValue,
                    timings: timings,
                    triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
                    decisionMilliseconds: decisionMilliseconds
                )
            case .some(.subscribe), .none:
                break
            }
        }

        if dispatchDecision.shouldDispatchTrigger || evaluation.shouldBeep {
            beep()
        }

        if shouldLogEvaluation {
            print(
                "[trigger] frame=\(frameNumber) region=\(OCRRegionKind.manualCell.rawValue) action=\(dispatchDecision.action) " +
                    "raw_text=\"\(escapedForLog(recognition.rawText))\" normalized_text=\"\(escapedForLog(evaluation.normalizedText))\" " +
                    "confidence=\(format(recognition.confidence, precision: 3)) parsed_int=\(evaluation.integerValue.map(String.init) ?? "nil") " +
                    "open_peak=\(evaluation.openPositionPeakValue.map(String.init) ?? "nil") " +
                    "confirmation=\(evaluation.confirmationProgress)/\(evaluation.requiredConfirmationCount) " +
                    "zero_or_empty=\(evaluation.isZeroOrEmpty) duplicate=\(evaluation.isDuplicate) " +
                    "armed_before=\(evaluation.wasArmed) armed_after=\(evaluation.isArmedAfter)"
            )
        }
    }

    private func handleManualSymbolBehavior(
        frameNumber: Int,
        recognition: OCRRecognitionResult,
        timings: TriggerStageTimings?,
        shouldLogEvaluation: Bool
    ) {
        guard let triggerStateMachine, let triggerDispatcher else {
            return
        }

        let triggerEvaluationStart = CFAbsoluteTimeGetCurrent()
        let evaluation = triggerStateMachine.evaluateManualSymbol(
            normalizedText: recognition.normalizedText,
            confidence: recognition.confidence
        )
        let triggerEvaluationMilliseconds = elapsedMilliseconds(since: triggerEvaluationStart)
        triggerDispatcher.invalidatePendingSubscribeIfNeeded(evaluation: evaluation)
        let decisionStart = CFAbsoluteTimeGetCurrent()
        let dispatchDecision = triggerDispatcher.subscribeDispatchDecision(for: evaluation)
        let decisionMilliseconds = elapsedMilliseconds(since: decisionStart)

        if dispatchDecision.shouldDispatchTrigger {
            let triggerEvent = OCRPipelineEvent(
                kind: .trigger,
                frameNumber: frameNumber,
                region: OCRRegionKind.manualSymbolCell.rawValue,
                action: dispatchDecision.action,
                rawText: recognition.rawText,
                normalizedText: recognition.normalizedText,
                confidence: recognition.confidence,
                symbol: evaluation.normalizedSymbol,
                parsedInteger: nil,
                isDuplicate: evaluation.isDuplicate,
                isZeroOrEmpty: nil,
                presentationTimeSeconds: timings?.presentationTimeSeconds
            )
            eventHandler?(triggerEvent)
            triggerDispatcher.dispatchSubscribe(
                triggerEvent: triggerEvent,
                symbol: evaluation.normalizedSymbol,
                timings: timings,
                triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
                decisionMilliseconds: decisionMilliseconds
            )
        }

        if dispatchDecision.shouldDispatchTrigger || evaluation.shouldBeep {
            beep()
        }

        if shouldLogEvaluation {
            print(
                "[trigger] frame=\(frameNumber) region=\(OCRRegionKind.manualSymbolCell.rawValue) action=\(dispatchDecision.action) " +
                    "raw_text=\"\(escapedForLog(recognition.rawText))\" normalized_text=\"\(escapedForLog(recognition.normalizedText))\" " +
                    "symbol=\"\(escapedForLog(evaluation.normalizedSymbol))\" confidence=\(format(recognition.confidence, precision: 3)) " +
                    "duplicate=\(evaluation.isDuplicate) confirmation=\(evaluation.confirmationProgress)/\(evaluation.requiredConfirmationCount)"
            )
        }
    }

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        max(0, (CFAbsoluteTimeGetCurrent() - start) * 1_000)
    }

    private func shouldLog(count: Int, cadence: Int) -> Bool {
        loggingEnabled && matchesCadence(count: count, cadence: cadence)
    }

    private func matchesCadence(count: Int, cadence: Int) -> Bool {
        count == 1 || count.isMultiple(of: cadence)
    }

    private func format(_ value: Double, precision: Int = 2) -> String {
        String(format: "%.\(precision)f", value)
    }

    private func fingerprintHex(_ fingerprint: UInt64) -> String {
        String(format: "%016llx", fingerprint)
    }

    private func escapedForLog(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func ensureLegacyTriggerHandlingForTesting() {
        guard triggerStateMachine == nil || triggerDispatcher == nil else {
            return
        }

        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: manualCellRearmConfirmationFrames,
            manualCellTriggerConfirmationFrames: manualCellTriggerConfirmationFrames,
            manualSymbolTriggerConfirmationFrames: manualSymbolTriggerConfirmationFrames
        )
        triggerStateMachine = stateMachine
        triggerDispatcher = Self.makeTriggerDispatcher(
            stateLock: stateLock,
            stateLockAccessGuard: stateLockAccessGuard,
            loggingEnabled: loggingEnabled,
            messageSender: legacyMessageSender,
            eventHandler: eventHandler,
            triggerStateMachine: stateMachine
        )
    }

    // Deterministic test-only trigger path that bypasses OCR/capture.
    func processTriggerEventForTesting(
        region: OCRRegionKind,
        rawText: String,
        normalizedText: String,
        confidence: Double
    ) {
        withStateLock {
            ensureLegacyTriggerHandlingForTesting()
            frameCount += 1
            let recognition = OCRRecognitionResult(
                rawText: rawText,
                normalizedText: normalizedText,
                confidence: confidence
            )
            let now = CFAbsoluteTimeGetCurrent()
            let syntheticTimings = TriggerStageTimings(
                frameIngressTimestamp: now,
                regionStartTimestamp: now,
                ocrDetectedTimestamp: now,
                presentationTimeSeconds: nil,
                cropMilliseconds: 0,
                metalMilliseconds: 0,
                fingerprintMilliseconds: 0,
                gatingMilliseconds: 0,
                ocrMilliseconds: 0
            )
            handleTriggerBehavior(
                for: region,
                frameNumber: frameCount,
                recognition: recognition,
                timings: syntheticTimings,
                shouldLogEvaluation: loggingEnabled
            )
        }
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        stateLockAccessGuard.didLock()
        defer {
            stateLockAccessGuard.didUnlock()
            stateLock.unlock()
        }
        return body()
    }
}
