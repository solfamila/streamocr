import AppKit
import CoreImage
import CoreMedia
import CoreVideo
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

enum OCRFingerprintPolicy {
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    static func fingerprint(pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let xStride = max(1, width / 64)
        let yStride = max(1, height / 64)
        let basePointer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var hash = fnvOffsetBasis
        for y in stride(from: 0, to: height, by: yStride) {
            let rowPointer = basePointer.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: xStride) {
                let pixelPointer = rowPointer.advanced(by: x * 4)
                mix(&hash, byte: pixelPointer[0])
                mix(&hash, byte: pixelPointer[1])
                mix(&hash, byte: pixelPointer[2])
            }
        }

        mix(&hash, byte: UInt8(width & 0xFF))
        mix(&hash, byte: UInt8(height & 0xFF))
        return hash
    }

    private static func mix(_ hash: inout UInt64, byte: UInt8) {
        hash ^= UInt64(byte)
        hash &*= fnvPrime
    }
}

enum ManualCellIntegerPolicy {
    static func parseInteger(_ normalizedText: String) -> Int? {
        let trimmed = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let compact = trimmed
            .uppercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else {
            return nil
        }

        var sign = ""
        var body = compact
        if let first = body.first, first == "+" || first == "-" {
            sign = String(first)
            body.removeFirst()
        }

        guard !body.isEmpty else {
            return nil
        }

        let characters = Array(body)
        let digitCount = characters.filter(\.isNumber).count
        let ambiguousCount = characters.count - digitCount

        guard digitCount > 0 else {
            return nil
        }

        // Allow a couple of OCR-confused glyphs when the token is otherwise numeric.
        guard ambiguousCount <= 2 else {
            return nil
        }

        var normalizedDigits = ""
        normalizedDigits.reserveCapacity(characters.count)

        for index in characters.indices {
            let character = characters[index]
            if character.isNumber {
                normalizedDigits.append(character)
                continue
            }

            guard
                let substituted = substituteAmbiguousDigit(character, index: index, characters: characters)
            else {
                return nil
            }

            normalizedDigits.append(substituted)
        }

        return Int(sign + normalizedDigits)
    }

    private static func substituteAmbiguousDigit(
        _ character: Character,
        index: Int,
        characters: [Character]
    ) -> Character? {
        let replacement: Character?
        switch character {
        case "A":
            replacement = "4"
        case "O", "Q", "D":
            replacement = "0"
        case "I", "L", "|":
            replacement = "1"
        case "S":
            replacement = "5"
        case "B":
            replacement = "8"
        case "Z":
            replacement = "2"
        default:
            replacement = nil
        }

        guard let replacement else {
            return nil
        }

        let previousIsDigit = index > 0 && characters[index - 1].isNumber
        let nextIsDigit = index + 1 < characters.count && characters[index + 1].isNumber
        guard previousIsDigit || nextIsDigit else {
            return nil
        }

        return replacement
    }
}

struct ManualCellTriggerEvaluation {
    let normalizedText: String
    let integerValue: Int?
    let isZeroOrEmpty: Bool
    let isDuplicate: Bool
    let isAwaitingConfirmation: Bool
    let confirmationProgress: Int
    let requiredConfirmationCount: Int
    let shouldTriggerBuy: Bool
    let shouldBeep: Bool
    let wasArmed: Bool
    let isArmedAfter: Bool
}

struct ManualSymbolTriggerEvaluation {
    let normalizedSymbol: String
    let isDuplicate: Bool
    let isChangeLocked: Bool
    let isAwaitingConfirmation: Bool
    let confirmationProgress: Int
    let requiredConfirmationCount: Int
    let shouldTriggerSubscribe: Bool
    let shouldBeep: Bool
}

final class TradingTriggerStateMachine {
    private let manualCellRearmConfirmationFrames: Int
    private let manualCellTriggerConfirmationFrames: Int
    private let manualSymbolTriggerConfirmationFrames: Int
    private let manualSymbolChangedSymbolMinimumConfidence: Double
    private var manualCellIsArmed = true
    private var manualCellZeroLikeStreak = 0
    private var pendingManualCellIntegerValue: Int?
    private var pendingManualCellConfirmationCount = 0
    private var lastManualCellText: String?
    private var lastCommittedManualSymbol: String?
    private var pendingManualSymbol: String?
    private var pendingManualSymbolConfirmationCount = 0
    private var manualSymbolChangeIsArmed = true

    init(
        manualCellRearmConfirmationFrames: Int = 1,
        manualCellTriggerConfirmationFrames: Int = 1,
        manualSymbolTriggerConfirmationFrames: Int = 1,
        manualSymbolChangedSymbolMinimumConfidence: Double = 0.80
    ) {
        self.manualCellRearmConfirmationFrames = max(1, manualCellRearmConfirmationFrames)
        self.manualCellTriggerConfirmationFrames = max(1, manualCellTriggerConfirmationFrames)
        self.manualSymbolTriggerConfirmationFrames = max(1, manualSymbolTriggerConfirmationFrames)
        self.manualSymbolChangedSymbolMinimumConfidence = min(
            max(0, manualSymbolChangedSymbolMinimumConfidence),
            1
        )
    }

    func reset() {
        manualCellIsArmed = true
        manualCellZeroLikeStreak = 0
        pendingManualCellIntegerValue = nil
        pendingManualCellConfirmationCount = 0
        lastManualCellText = nil
        lastCommittedManualSymbol = nil
        pendingManualSymbol = nil
        pendingManualSymbolConfirmationCount = 0
        manualSymbolChangeIsArmed = true
    }

    func clearManualSymbolState() {
        lastCommittedManualSymbol = nil
        pendingManualSymbol = nil
        pendingManualSymbolConfirmationCount = 0
        manualSymbolChangeIsArmed = true
    }

    func evaluateManualCell(normalizedText: String) -> ManualCellTriggerEvaluation {
        let integerValue = ManualCellIntegerPolicy.parseInteger(normalizedText)
        let isZeroOrEmpty = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || integerValue == 0
        let isDuplicate = normalizedText == lastManualCellText
        let wasArmed = manualCellIsArmed
        if isZeroOrEmpty {
            manualCellZeroLikeStreak += 1
        } else {
            manualCellZeroLikeStreak = 0
        }

        let shouldRearm = isZeroOrEmpty && manualCellZeroLikeStreak >= manualCellRearmConfirmationFrames
        var confirmationProgress = 0

        if manualCellIsArmed {
            if let integerValue, !isZeroOrEmpty {
                if pendingManualCellIntegerValue == integerValue {
                    pendingManualCellConfirmationCount += 1
                } else {
                    pendingManualCellIntegerValue = integerValue
                    pendingManualCellConfirmationCount = 1
                }
                confirmationProgress = pendingManualCellConfirmationCount
            } else {
                pendingManualCellIntegerValue = nil
                pendingManualCellConfirmationCount = 0
            }
        } else {
            pendingManualCellIntegerValue = nil
            pendingManualCellConfirmationCount = 0
        }

        let shouldTriggerBuy =
            manualCellIsArmed &&
            integerValue != nil &&
            !isZeroOrEmpty &&
            confirmationProgress >= manualCellTriggerConfirmationFrames

        if shouldRearm {
            manualCellIsArmed = true
            pendingManualCellIntegerValue = nil
            pendingManualCellConfirmationCount = 0
            // Only unlock symbol changes when we actually transition from an active
            // position back to the rearmed state. Startup blank frames should not
            // repeatedly unlock the symbol path.
            if !wasArmed {
                manualSymbolChangeIsArmed = true
            }
        }

        if !isDuplicate {
            lastManualCellText = normalizedText
        }

        return ManualCellTriggerEvaluation(
            normalizedText: normalizedText,
            integerValue: integerValue,
            isZeroOrEmpty: isZeroOrEmpty,
            isDuplicate: isDuplicate,
            isAwaitingConfirmation:
                manualCellIsArmed &&
                integerValue != nil &&
                !isZeroOrEmpty &&
                !shouldTriggerBuy &&
                confirmationProgress > 0,
            confirmationProgress: confirmationProgress,
            requiredConfirmationCount: manualCellTriggerConfirmationFrames,
            shouldTriggerBuy: shouldTriggerBuy,
            shouldBeep: !isDuplicate,
            wasArmed: wasArmed,
            isArmedAfter: manualCellIsArmed
        )
    }

    func evaluateManualSymbol(normalizedText: String, confidence: Double) -> ManualSymbolTriggerEvaluation {
        let normalizedSymbol = TradingWebSocketContract.normalizedOCRSymbol(normalizedText) ?? ""
        let isDuplicate = !normalizedSymbol.isEmpty && normalizedSymbol == lastCommittedManualSymbol
        let hasCommittedSymbol = lastCommittedManualSymbol != nil
        let isLowConfidenceChangedSymbol =
            hasCommittedSymbol &&
            !normalizedSymbol.isEmpty &&
            !isDuplicate &&
            confidence < manualSymbolChangedSymbolMinimumConfidence
        let isChangeLocked =
            !normalizedSymbol.isEmpty &&
            !isDuplicate &&
            lastCommittedManualSymbol != nil &&
            (!manualSymbolChangeIsArmed || isLowConfidenceChangedSymbol)
        var confirmationProgress = 0

        if normalizedSymbol.isEmpty || isDuplicate || isChangeLocked {
            pendingManualSymbol = nil
            pendingManualSymbolConfirmationCount = 0
        } else if pendingManualSymbol == normalizedSymbol {
            pendingManualSymbolConfirmationCount += 1
            confirmationProgress = pendingManualSymbolConfirmationCount
        } else {
            pendingManualSymbol = normalizedSymbol
            pendingManualSymbolConfirmationCount = 1
            confirmationProgress = pendingManualSymbolConfirmationCount
        }

        let shouldTriggerSubscribe =
            !normalizedSymbol.isEmpty &&
            !isDuplicate &&
            !isChangeLocked &&
            confirmationProgress >= manualSymbolTriggerConfirmationFrames

        return ManualSymbolTriggerEvaluation(
            normalizedSymbol: normalizedSymbol,
            isDuplicate: isDuplicate,
            isChangeLocked: isChangeLocked,
            isAwaitingConfirmation:
                !normalizedSymbol.isEmpty &&
                !isDuplicate &&
                !isChangeLocked &&
                !shouldTriggerSubscribe &&
                confirmationProgress > 0,
            confirmationProgress: confirmationProgress,
            requiredConfirmationCount: manualSymbolTriggerConfirmationFrames,
            shouldTriggerSubscribe: shouldTriggerSubscribe,
            shouldBeep: shouldTriggerSubscribe
        )
    }

    func commitManualCellTriggerSuccess() {
        manualCellIsArmed = false
        pendingManualCellIntegerValue = nil
        pendingManualCellConfirmationCount = 0
    }

    func commitManualSymbolTriggerSuccess(symbol: String) {
        lastCommittedManualSymbol = TradingWebSocketContract.normalizeSymbol(symbol)
        pendingManualSymbol = nil
        pendingManualSymbolConfirmationCount = 0
        manualSymbolChangeIsArmed = false
    }
}

private struct OCRRecognitionResult {
    let rawText: String
    let normalizedText: String
    let confidence: Double
}

private struct TriggerStageTimings {
    let frameIngressTimestamp: CFAbsoluteTime
    let regionStartTimestamp: CFAbsoluteTime
    let ocrDetectedTimestamp: CFAbsoluteTime
    let presentationTimeSeconds: Double?
    let cropMilliseconds: Double
    let metalMilliseconds: Double
    let fingerprintMilliseconds: Double
    let gatingMilliseconds: Double
    let ocrMilliseconds: Double
}

private struct PendingBuyTransport {
    let integerValue: Int?
    let triggerEvent: OCRPipelineEvent
    let timings: TriggerStageTimings?
    let triggerEvaluationMilliseconds: Double
    let buyDecisionMilliseconds: Double
    var isStale = false

    func matches(integerValue: Int?) -> Bool {
        self.integerValue == integerValue
    }
}

private struct PendingSubscribeTransport {
    let symbol: String
    let triggerEvent: OCRPipelineEvent
    var isStale = false

    func matches(symbol: String) -> Bool {
        self.symbol == symbol
    }
}

final class LowLatencyOCRFramePipeline: FramePipeline, @unchecked Sendable {
    private let ciContext: CIContext
    private let usesMetal: Bool
    private let preprocessor: OCRRegionPreprocessor
    private let loggingEnabled: Bool
    private let unchangedLogCadence: Int
    private let manualSymbolSamplingIntervalFrames: Int
    private let recognizer: any OCRTextRecognizing
    private let messageSender: any TradingMessageSending
    private let beep: @Sendable () -> Void
    private let eventHandler: OCRPipelineEventHandler?
    private let stateLock = NSRecursiveLock()
    private let triggerStateMachine: TradingTriggerStateMachine

    private var frameCount = 0
    private var didLogBackend = false
    private var lastFingerprintByRegion: [OCRRegionKind: UInt64] = [:]
    private var lastRecognitionByRegion: [OCRRegionKind: OCRRecognitionResult] = [:]
    private var unchangedStreakByRegion: [OCRRegionKind: Int] = [:]
    private var pendingBuyTransport: PendingBuyTransport?
    private var pendingSubscribeTransport: PendingSubscribeTransport?

    init(
        loggingEnabled: Bool = true,
        unchangedLogCadence: Int = 30,
        manualCellRearmConfirmationFrames: Int = 12,
        manualCellTriggerConfirmationFrames: Int = 2,
        manualSymbolSamplingIntervalFrames: Int = 30,
        manualSymbolTriggerConfirmationFrames: Int = 2,
        recognizer: any OCRTextRecognizing = FontTemplateTextRecognizer(),
        messageSender: any TradingMessageSending = LocalTradingWebSocketClient(),
        beep: @escaping @Sendable () -> Void = {
            DispatchQueue.main.async {
                NSSound.beep()
            }
        },
        eventHandler: OCRPipelineEventHandler? = nil
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
        self.manualSymbolSamplingIntervalFrames = max(1, manualSymbolSamplingIntervalFrames)
        triggerStateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: manualCellRearmConfirmationFrames,
            manualCellTriggerConfirmationFrames: manualCellTriggerConfirmationFrames,
            manualSymbolTriggerConfirmationFrames: manualSymbolTriggerConfirmationFrames
        )
        self.recognizer = recognizer
        self.messageSender = messageSender
        self.beep = beep
        self.eventHandler = eventHandler
    }

    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        frameCount = 0
        didLogBackend = false
        lastFingerprintByRegion.removeAll(keepingCapacity: true)
        lastRecognitionByRegion.removeAll(keepingCapacity: true)
        unchangedStreakByRegion.removeAll(keepingCapacity: true)
        pendingBuyTransport = nil
        pendingSubscribeTransport = nil
        triggerStateMachine.reset()
    }

    func process(_ frame: VideoFrame, runtimeConfig: CaptureRuntimeConfig?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        frameCount += 1
        let frameIngressTimestamp = CFAbsoluteTimeGetCurrent()

        guard let runtimeConfig else {
            if loggingEnabled && (frameCount == 1 || frameCount.isMultiple(of: 120)) {
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
            lastFingerprintByRegion.removeValue(forKey: .manualSymbolCell)
            lastRecognitionByRegion.removeValue(forKey: .manualSymbolCell)
            unchangedStreakByRegion.removeValue(forKey: .manualSymbolCell)
            triggerStateMachine.clearManualSymbolState()
        }

        processRegion(
            .manualCell,
            sourcePixelBuffer: sourcePixelBuffer,
            runtimeConfig: runtimeConfig,
            frameIngressTimestamp: frameIngressTimestamp,
            presentationTimeSeconds: frame.presentationTimeSeconds
        )

        if runtimeConfig.manualSymbolCellROI != nil, shouldProcessManualSymbolRegionThisFrame() {
            processRegion(
                .manualSymbolCell,
                sourcePixelBuffer: sourcePixelBuffer,
                runtimeConfig: runtimeConfig,
                frameIngressTimestamp: frameIngressTimestamp,
                presentationTimeSeconds: frame.presentationTimeSeconds
            )
        }
    }

    private func shouldProcessManualSymbolRegionThisFrame() -> Bool {
        frameCount == 1 || frameCount.isMultiple(of: manualSymbolSamplingIntervalFrames)
    }

    private func processRegion(
        _ region: OCRRegionKind,
        sourcePixelBuffer: CVPixelBuffer,
        runtimeConfig: CaptureRuntimeConfig,
        frameIngressTimestamp: CFAbsoluteTime,
        presentationTimeSeconds: Double?
    ) {
        guard let configuredROI = region.roi(from: runtimeConfig) else {
            return
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
            return
        }

        let regionStartTimestamp = CFAbsoluteTimeGetCurrent()

        guard let preprocessResult = preprocessor.preprocess(sourcePixelBuffer: sourcePixelBuffer, roi: roi, region: region) else {
            if loggingEnabled {
                print("[ocr] frame=\(frameCount) region=\(region.rawValue) gate=preprocess_failed roi=\(roi.summary)")
            }
            return
        }

        let fingerprintStart = CFAbsoluteTimeGetCurrent()
        let fingerprint = OCRFingerprintPolicy.fingerprint(pixelBuffer: preprocessResult.pixelBuffer)
        let fingerprintMilliseconds = elapsedMilliseconds(since: fingerprintStart)

        let gatingStart = CFAbsoluteTimeGetCurrent()
        let previousFingerprint = lastFingerprintByRegion[region]
        if previousFingerprint == fingerprint {
            let streak = (unchangedStreakByRegion[region] ?? 0) + 1
            unchangedStreakByRegion[region] = streak
            let gatingMilliseconds = elapsedMilliseconds(since: gatingStart)

            if loggingEnabled && (streak == 1 || streak.isMultiple(of: unchangedLogCadence)) {
                let totalMilliseconds = elapsedMilliseconds(since: regionStartTimestamp)
                print(
                    "[ocr] frame=\(frameCount) region=\(region.rawValue) gate=unchanged skip_ocr=true streak=\(streak) " +
                        "fingerprint=\(fingerprintHex(fingerprint)) crop_ms=\(format(preprocessResult.cropMilliseconds)) " +
                        "metal_ms=\(format(preprocessResult.metalMilliseconds)) fingerprint_ms=\(format(fingerprintMilliseconds)) " +
                        "gating_ms=\(format(gatingMilliseconds)) " +
                        "total_ms=\(format(totalMilliseconds))"
                )
            }
            replayCachedRecognitionForTriggerIfNeeded(
                region: region,
                frameIngressTimestamp: frameIngressTimestamp,
                regionStartTimestamp: regionStartTimestamp,
                presentationTimeSeconds: presentationTimeSeconds,
                cropMilliseconds: preprocessResult.cropMilliseconds,
                metalMilliseconds: preprocessResult.metalMilliseconds,
                fingerprintMilliseconds: fingerprintMilliseconds,
                gatingMilliseconds: gatingMilliseconds,
                shouldLogEvaluation: loggingEnabled && (streak == 1 || streak.isMultiple(of: unchangedLogCadence))
            )
            return
        }

        lastFingerprintByRegion[region] = fingerprint
        unchangedStreakByRegion[region] = 0
        let gatingMilliseconds = elapsedMilliseconds(since: gatingStart)

        let ocrStart = CFAbsoluteTimeGetCurrent()
        let recognition = recognizeText(in: preprocessResult.pixelBuffer, region: region)
        let ocrMilliseconds = elapsedMilliseconds(since: ocrStart)
        let ocrDetectedTimestamp = CFAbsoluteTimeGetCurrent()
        let totalMilliseconds = elapsedMilliseconds(since: regionStartTimestamp)
        lastRecognitionByRegion[region] = recognition

        let escapedNormalizedText = escapedForLog(recognition.normalizedText)
        let escapedRawText = escapedForLog(recognition.rawText)
        if loggingEnabled {
            print(
                    "[ocr] frame=\(frameCount) region=\(region.rawValue) gate=changed skip_ocr=false " +
                    "fingerprint=\(fingerprintHex(fingerprint)) crop_ms=\(format(preprocessResult.cropMilliseconds)) " +
                    "metal_ms=\(format(preprocessResult.metalMilliseconds)) fingerprint_ms=\(format(fingerprintMilliseconds)) " +
                    "gating_ms=\(format(gatingMilliseconds)) " +
                    "ocr_ms=\(format(ocrMilliseconds)) total_ms=\(format(totalMilliseconds)) " +
                    "raw_text=\"\(escapedRawText)\" normalized_text=\"\(escapedNormalizedText)\" " +
                    "confidence=\(format(recognition.confidence, precision: 3))"
            )
        }

        eventHandler?(
            OCRPipelineEvent(
                kind: .recognition,
                frameNumber: frameCount,
                region: region.rawValue,
                action: "ocr_changed",
                rawText: recognition.rawText,
                normalizedText: recognition.normalizedText,
                confidence: recognition.confidence,
                symbol: region == .manualSymbolCell ? TradingWebSocketContract.normalizedOCRSymbol(recognition.normalizedText) : nil,
                parsedInteger: region == .manualCell ? ManualCellIntegerPolicy.parseInteger(recognition.normalizedText) : nil,
                isDuplicate: nil,
                isZeroOrEmpty: nil,
                presentationTimeSeconds: presentationTimeSeconds
            )
        )

        handleTriggerBehavior(
            for: region,
            recognition: recognition,
            timings: TriggerStageTimings(
                frameIngressTimestamp: frameIngressTimestamp,
                regionStartTimestamp: regionStartTimestamp,
                ocrDetectedTimestamp: ocrDetectedTimestamp,
                presentationTimeSeconds: presentationTimeSeconds,
                cropMilliseconds: preprocessResult.cropMilliseconds,
                metalMilliseconds: preprocessResult.metalMilliseconds,
                fingerprintMilliseconds: fingerprintMilliseconds,
                gatingMilliseconds: gatingMilliseconds,
                ocrMilliseconds: ocrMilliseconds
            ),
            shouldLogEvaluation: loggingEnabled
        )
    }

    private func replayCachedRecognitionForTriggerIfNeeded(
        region: OCRRegionKind,
        frameIngressTimestamp: CFAbsoluteTime,
        regionStartTimestamp: CFAbsoluteTime,
        presentationTimeSeconds: Double?,
        cropMilliseconds: Double,
        metalMilliseconds: Double,
        fingerprintMilliseconds: Double,
        gatingMilliseconds: Double,
        shouldLogEvaluation: Bool
    ) {
        guard let recognition = lastRecognitionByRegion[region] else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        handleTriggerBehavior(
            for: region,
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

    private func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRRecognitionResult {
        let recognition = recognizer.recognizeText(in: pixelBuffer, region: region)
        let normalizedText = OCRNormalizationPolicy.normalize(recognition.rawText, for: region)
        return OCRRecognitionResult(
            rawText: recognition.rawText,
            normalizedText: normalizedText,
            confidence: recognition.confidence
        )
    }

    private func handleTriggerBehavior(
        for region: OCRRegionKind,
        recognition: OCRRecognitionResult,
        timings: TriggerStageTimings?,
        shouldLogEvaluation: Bool
    ) {
        switch region {
        case .manualCell:
            handleManualCellBehavior(
                recognition: recognition,
                timings: timings,
                shouldLogEvaluation: shouldLogEvaluation
            )
        case .manualSymbolCell:
            handleManualSymbolBehavior(
                recognition: recognition,
                timings: timings,
                shouldLogEvaluation: shouldLogEvaluation
            )
        }
    }

    private func handleManualCellBehavior(
        recognition: OCRRecognitionResult,
        timings: TriggerStageTimings?,
        shouldLogEvaluation: Bool
    ) {
        let triggerEvaluationStart = CFAbsoluteTimeGetCurrent()
        let evaluation = triggerStateMachine.evaluateManualCell(normalizedText: recognition.normalizedText)
        invalidatePendingBuyTransportIfNeeded(evaluation: evaluation)
        invalidatePendingSubscribeTransportIfNeeded(manualCellEvaluation: evaluation)
        let triggerEvaluationMilliseconds = elapsedMilliseconds(since: triggerEvaluationStart)
        let buyDecisionStart = CFAbsoluteTimeGetCurrent()
        let action: String
        let shouldDispatchTrigger: Bool

        if evaluation.shouldTriggerBuy {
            if let pendingBuyTransport {
                if pendingBuyTransport.matches(integerValue: evaluation.integerValue) {
                    action = "transport_pending_duplicate_suppressed"
                } else {
                    action = "transport_pending_suppressed"
                }
                shouldDispatchTrigger = false
            } else {
                action = "buy_triggered"
                shouldDispatchTrigger = true
            }
        } else if evaluation.isZeroOrEmpty {
            action = "armed"
            shouldDispatchTrigger = false
        } else if evaluation.isAwaitingConfirmation {
            action = "confirmation_pending"
            shouldDispatchTrigger = false
        } else if evaluation.isDuplicate {
            action = "duplicate_suppressed"
            shouldDispatchTrigger = false
        } else {
            action = "already_triggered_waiting_for_rearm"
            shouldDispatchTrigger = false
        }
        let buyDecisionMilliseconds = elapsedMilliseconds(since: buyDecisionStart)

        if shouldDispatchTrigger {
            let triggerEvent = OCRPipelineEvent(
                kind: .trigger,
                frameNumber: frameCount,
                region: OCRRegionKind.manualCell.rawValue,
                action: action,
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
            startPendingBuyTransport(
                triggerEvent: triggerEvent,
                integerValue: evaluation.integerValue,
                timings: timings,
                triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
                buyDecisionMilliseconds: buyDecisionMilliseconds
            )
        }

        if shouldDispatchTrigger || evaluation.shouldBeep {
            beep()
        }

        if shouldLogEvaluation {
            print(
                "[trigger] frame=\(frameCount) region=\(OCRRegionKind.manualCell.rawValue) action=\(action) " +
                    "raw_text=\"\(escapedForLog(recognition.rawText))\" normalized_text=\"\(escapedForLog(evaluation.normalizedText))\" " +
                    "confidence=\(format(recognition.confidence, precision: 3)) parsed_int=\(evaluation.integerValue.map(String.init) ?? "nil") " +
                    "confirmation=\(evaluation.confirmationProgress)/\(evaluation.requiredConfirmationCount) " +
                    "zero_or_empty=\(evaluation.isZeroOrEmpty) duplicate=\(evaluation.isDuplicate) " +
                    "armed_before=\(evaluation.wasArmed) armed_after=\(evaluation.isArmedAfter)"
            )
        }
    }

    private func handleManualSymbolBehavior(
        recognition: OCRRecognitionResult,
        timings: TriggerStageTimings?,
        shouldLogEvaluation: Bool
    ) {
        let evaluation = triggerStateMachine.evaluateManualSymbol(
            normalizedText: recognition.normalizedText,
            confidence: recognition.confidence
        )
        invalidatePendingSubscribeTransportIfNeeded(evaluation: evaluation)
        let action: String
        let shouldDispatchTrigger: Bool

        if evaluation.shouldTriggerSubscribe {
            if let pendingSubscribeTransport {
                if pendingSubscribeTransport.matches(symbol: evaluation.normalizedSymbol) {
                    action = "transport_pending_duplicate_suppressed"
                } else {
                    action = "transport_pending_suppressed"
                }
                shouldDispatchTrigger = false
            } else {
                action = "subscribe_triggered"
                shouldDispatchTrigger = true
            }
        } else if evaluation.isDuplicate {
            action = "duplicate_suppressed"
            shouldDispatchTrigger = false
        } else if evaluation.isChangeLocked {
            action = "locked_waiting_for_rearm"
            shouldDispatchTrigger = false
        } else if evaluation.isAwaitingConfirmation {
            action = "confirmation_pending"
            shouldDispatchTrigger = false
        } else {
            action = "symbol_empty_no_subscribe"
            shouldDispatchTrigger = false
        }

        if shouldDispatchTrigger {
            let triggerEvent = OCRPipelineEvent(
                kind: .trigger,
                frameNumber: frameCount,
                region: OCRRegionKind.manualSymbolCell.rawValue,
                action: action,
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
            startPendingSubscribeTransport(
                triggerEvent: triggerEvent,
                symbol: evaluation.normalizedSymbol
            )
        }

        if shouldDispatchTrigger || evaluation.shouldBeep {
            beep()
        }

        if shouldLogEvaluation {
            print(
                "[trigger] frame=\(frameCount) region=\(OCRRegionKind.manualSymbolCell.rawValue) action=\(action) " +
                    "raw_text=\"\(escapedForLog(recognition.rawText))\" normalized_text=\"\(escapedForLog(recognition.normalizedText))\" " +
                    "symbol=\"\(escapedForLog(evaluation.normalizedSymbol))\" confidence=\(format(recognition.confidence, precision: 3)) " +
                    "duplicate=\(evaluation.isDuplicate) confirmation=\(evaluation.confirmationProgress)/\(evaluation.requiredConfirmationCount)"
            )
        }
    }

    private func startPendingBuyTransport(
        triggerEvent: OCRPipelineEvent,
        integerValue: Int?,
        timings: TriggerStageTimings?,
        triggerEvaluationMilliseconds: Double,
        buyDecisionMilliseconds: Double
    ) {
        pendingBuyTransport = PendingBuyTransport(
            integerValue: integerValue,
            triggerEvent: triggerEvent,
            timings: timings,
            triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
            buyDecisionMilliseconds: buyDecisionMilliseconds
        )

        messageSender.send(TradingWebSocketContract.buyMessage, event: "BUY") { result in
            self.handleBuyTransportResult(result)
        }
    }

    private func handleBuyTransportResult(_ result: Result<Void, any Error>) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let pendingBuyTransport else {
            return
        }
        self.pendingBuyTransport = nil

        if messageSender.reportsTransportOutcomes {
            let action = transportAction(for: result, success: "buy_transport_succeeded", failure: "buy_transport_failed")
            eventHandler?(transportOutcomeEvent(from: pendingBuyTransport.triggerEvent, action: action))
        }

        if let timings = pendingBuyTransport.timings {
            let sendCompletionTimestamp = CFAbsoluteTimeGetCurrent()
            let frameIngressToRegionMilliseconds = max(
                0,
                (timings.regionStartTimestamp - timings.frameIngressTimestamp) * 1_000
            )
            let wsSendCompletionMilliseconds = max(
                0,
                (sendCompletionTimestamp - timings.frameIngressTimestamp) * 1_000
            )
            let ocrToCompletionMilliseconds = max(
                0,
                (sendCompletionTimestamp - timings.ocrDetectedTimestamp) * 1_000
            )
            let sendResult = transportResultLabel(for: result)
            let sendErrorSuffix = transportErrorSuffix(for: result)

            if loggingEnabled {
                print(
                    "[latency] frame=\(pendingBuyTransport.triggerEvent.frameNumber) event=BUY send_result=\(sendResult) " +
                        "frame_ingress_to_region_ms=\(format(frameIngressToRegionMilliseconds)) " +
                        "crop_ms=\(format(timings.cropMilliseconds)) metal_ms=\(format(timings.metalMilliseconds)) " +
                        "fingerprint_ms=\(format(timings.fingerprintMilliseconds)) " +
                        "gating_ms=\(format(timings.gatingMilliseconds)) " +
                        "ocr_ms=\(format(timings.ocrMilliseconds)) " +
                        "trigger_eval_ms=\(format(pendingBuyTransport.triggerEvaluationMilliseconds)) " +
                        "buy_decision_ms=\(format(pendingBuyTransport.buyDecisionMilliseconds)) " +
                        "ws_send_completion_ms=\(format(wsSendCompletionMilliseconds)) " +
                        "ocr_to_completion_ms=\(format(ocrToCompletionMilliseconds)) " +
                        "total_end_to_end_ms=\(format(wsSendCompletionMilliseconds))\(sendErrorSuffix)"
                )
            }
        }

        if case .success = result, !pendingBuyTransport.isStale {
            triggerStateMachine.commitManualCellTriggerSuccess()
        }
    }

    private func startPendingSubscribeTransport(
        triggerEvent: OCRPipelineEvent,
        symbol: String
    ) {
        pendingSubscribeTransport = PendingSubscribeTransport(symbol: symbol, triggerEvent: triggerEvent)
        guard let message = TradingWebSocketContract.subscribeMessage(symbol: symbol) else {
            handleSubscribeTransportResult(.failure(TradingWebSocketContractError.invalidSymbol(symbol)))
            return
        }
        messageSender.send(message, event: "SUBSCRIBE") { result in
            self.handleSubscribeTransportResult(result)
        }
    }

    private func handleSubscribeTransportResult(_ result: Result<Void, any Error>) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let pendingSubscribeTransport else {
            return
        }
        self.pendingSubscribeTransport = nil

        if messageSender.reportsTransportOutcomes {
            let action = transportAction(
                for: result,
                success: "subscribe_transport_succeeded",
                failure: "subscribe_transport_failed"
            )
            eventHandler?(transportOutcomeEvent(from: pendingSubscribeTransport.triggerEvent, action: action))
        }

        if case .success = result, !pendingSubscribeTransport.isStale {
            triggerStateMachine.commitManualSymbolTriggerSuccess(symbol: pendingSubscribeTransport.symbol)
        }
    }

    private func invalidatePendingBuyTransportIfNeeded(evaluation: ManualCellTriggerEvaluation) {
        guard var pendingBuyTransport, !pendingBuyTransport.isStale else {
            return
        }

        let didGenuinelyRearm = !evaluation.wasArmed && evaluation.isArmedAfter
        let didConfirmDifferentCandidate =
            evaluation.shouldTriggerBuy &&
            evaluation.integerValue != nil &&
            !pendingBuyTransport.matches(integerValue: evaluation.integerValue)

        guard didGenuinelyRearm || didConfirmDifferentCandidate else {
            return
        }

        pendingBuyTransport.isStale = true
        self.pendingBuyTransport = pendingBuyTransport
    }

    private func invalidatePendingSubscribeTransportIfNeeded(evaluation: ManualSymbolTriggerEvaluation) {
        guard var pendingSubscribeTransport, !pendingSubscribeTransport.isStale else {
            return
        }

        guard
            evaluation.shouldTriggerSubscribe,
            !pendingSubscribeTransport.matches(symbol: evaluation.normalizedSymbol)
        else {
            return
        }

        pendingSubscribeTransport.isStale = true
        self.pendingSubscribeTransport = pendingSubscribeTransport
    }

    private func invalidatePendingSubscribeTransportIfNeeded(manualCellEvaluation: ManualCellTriggerEvaluation) {
        guard var pendingSubscribeTransport, !pendingSubscribeTransport.isStale else {
            return
        }

        guard !manualCellEvaluation.wasArmed, manualCellEvaluation.isArmedAfter else {
            return
        }

        pendingSubscribeTransport.isStale = true
        self.pendingSubscribeTransport = pendingSubscribeTransport
    }

    private func transportOutcomeEvent(from triggerEvent: OCRPipelineEvent, action: String) -> OCRPipelineEvent {
        OCRPipelineEvent(
            kind: .trigger,
            frameNumber: triggerEvent.frameNumber,
            region: triggerEvent.region,
            action: action,
            rawText: triggerEvent.rawText,
            normalizedText: triggerEvent.normalizedText,
            confidence: triggerEvent.confidence,
            symbol: triggerEvent.symbol,
            parsedInteger: triggerEvent.parsedInteger,
            isDuplicate: triggerEvent.isDuplicate,
            isZeroOrEmpty: triggerEvent.isZeroOrEmpty,
            presentationTimeSeconds: triggerEvent.presentationTimeSeconds
        )
    }

    private func transportAction(
        for result: Result<Void, any Error>,
        success: String,
        failure: String
    ) -> String {
        switch result {
        case .success:
            success
        case .failure:
            failure
        }
    }

    private func transportResultLabel(for result: Result<Void, any Error>) -> String {
        switch result {
        case .success:
            "success"
        case .failure:
            "failure"
        }
    }

    private func transportErrorSuffix(for result: Result<Void, any Error>) -> String {
        switch result {
        case .success:
            ""
        case let .failure(error):
            " send_error=\"\(escapedForLog(error.localizedDescription))\""
        }
    }

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        max(0, (CFAbsoluteTimeGetCurrent() - start) * 1_000)
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

    // Deterministic test-only trigger path that bypasses OCR/capture.
    func processTriggerEventForTesting(
        region: OCRRegionKind,
        rawText: String,
        normalizedText: String,
        confidence: Double
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }

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
            recognition: recognition,
            timings: syntheticTimings,
            shouldLogEvaluation: loggingEnabled
        )
    }
}
