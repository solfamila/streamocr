import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Vision

enum OCRRegionKind: String, Hashable, Sendable {
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

        let compact = trimmed.replacingOccurrences(of: ",", with: "")
        guard !compact.isEmpty else {
            return nil
        }

        var start = compact.startIndex
        if compact[start] == "+" || compact[start] == "-" {
            start = compact.index(after: start)
        }

        guard start < compact.endIndex else {
            return nil
        }

        guard compact[start...].allSatisfy(\.isNumber) else {
            return nil
        }

        return Int(compact)
    }
}

struct ManualCellTriggerEvaluation {
    let normalizedText: String
    let integerValue: Int?
    let isZeroOrEmpty: Bool
    let isDuplicate: Bool
    let shouldSendBuy: Bool
    let shouldBeep: Bool
    let wasArmed: Bool
    let isArmedAfter: Bool
}

struct ManualSymbolTriggerEvaluation {
    let normalizedSymbol: String
    let isDuplicate: Bool
    let shouldSendSubscribe: Bool
    let shouldBeep: Bool
}

final class TradingTriggerStateMachine {
    private var manualCellIsArmed = true
    private var lastManualCellText: String?
    private var lastManualSymbol: String?

    func reset() {
        manualCellIsArmed = true
        lastManualCellText = nil
        lastManualSymbol = nil
    }

    func clearManualSymbolState() {
        lastManualSymbol = nil
    }

    func evaluateManualCell(normalizedText: String) -> ManualCellTriggerEvaluation {
        let integerValue = ManualCellIntegerPolicy.parseInteger(normalizedText)
        let isZeroOrEmpty = integerValue == nil || integerValue == 0
        let isDuplicate = normalizedText == lastManualCellText
        let wasArmed = manualCellIsArmed
        let shouldSendBuy = manualCellIsArmed && !isZeroOrEmpty

        if isZeroOrEmpty {
            manualCellIsArmed = true
        } else if shouldSendBuy {
            manualCellIsArmed = false
        }

        if !isDuplicate {
            lastManualCellText = normalizedText
        }

        return ManualCellTriggerEvaluation(
            normalizedText: normalizedText,
            integerValue: integerValue,
            isZeroOrEmpty: isZeroOrEmpty,
            isDuplicate: isDuplicate,
            shouldSendBuy: shouldSendBuy,
            shouldBeep: !isDuplicate,
            wasArmed: wasArmed,
            isArmedAfter: manualCellIsArmed
        )
    }

    func evaluateManualSymbol(normalizedText: String) -> ManualSymbolTriggerEvaluation {
        let normalizedSymbol = TradingWebSocketContract.normalizeSymbol(normalizedText)
        let isDuplicate = normalizedSymbol == lastManualSymbol

        if !isDuplicate {
            lastManualSymbol = normalizedSymbol
        }

        return ManualSymbolTriggerEvaluation(
            normalizedSymbol: normalizedSymbol,
            isDuplicate: isDuplicate,
            shouldSendSubscribe: !normalizedSymbol.isEmpty && !isDuplicate,
            shouldBeep: !isDuplicate
        )
    }
}

private struct OCRRecognitionResult {
    let rawText: String
    let normalizedText: String
    let confidence: Double
}

private struct OCRPreprocessResult {
    let pixelBuffer: CVPixelBuffer
    let cropMilliseconds: Double
    let metalMilliseconds: Double
}

final class LowLatencyOCRFramePipeline: FramePipeline, @unchecked Sendable {
    private let ciContext: CIContext
    private let usesMetal: Bool
    private let unchangedLogCadence: Int
    private let requestByRegion: [OCRRegionKind: VNRecognizeTextRequest]
    private let webSocketClient: LocalTradingWebSocketClient
    private let beep: @Sendable () -> Void
    private let stateLock = NSLock()
    private let triggerStateMachine = TradingTriggerStateMachine()

    private var frameCount = 0
    private var didLogBackend = false
    private var lastFingerprintByRegion: [OCRRegionKind: UInt64] = [:]
    private var unchangedStreakByRegion: [OCRRegionKind: Int] = [:]

    init(
        unchangedLogCadence: Int = 30,
        webSocketClient: LocalTradingWebSocketClient = LocalTradingWebSocketClient(),
        beep: @escaping @Sendable () -> Void = {
            DispatchQueue.main.async {
                NSSound.beep()
            }
        }
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

        self.unchangedLogCadence = max(1, unchangedLogCadence)
        self.requestByRegion = [
            .manualCell: Self.makeRequest(),
            .manualSymbolCell: Self.makeRequest()
        ]
        self.webSocketClient = webSocketClient
        self.beep = beep
    }

    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        frameCount = 0
        didLogBackend = false
        lastFingerprintByRegion.removeAll(keepingCapacity: true)
        unchangedStreakByRegion.removeAll(keepingCapacity: true)
        triggerStateMachine.reset()
    }

    func process(_ sampleBuffer: CMSampleBuffer, runtimeConfig: CaptureRuntimeConfig?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        frameCount += 1

        guard let runtimeConfig else {
            if frameCount == 1 || frameCount.isMultiple(of: 120) {
                print("[ocr] frame=\(frameCount) gate=no_runtime_config")
            }
            return
        }

        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("[ocr] frame=\(frameCount) gate=missing_pixel_buffer")
            return
        }

        if !didLogBackend {
            didLogBackend = true
            print("[ocr] preprocess_backend=\(usesMetal ? "metal" : "cpu_fallback")")
        }

        if runtimeConfig.manualSymbolCellROI == nil {
            lastFingerprintByRegion.removeValue(forKey: .manualSymbolCell)
            unchangedStreakByRegion.removeValue(forKey: .manualSymbolCell)
            triggerStateMachine.clearManualSymbolState()
        }

        processRegion(.manualCell, sourcePixelBuffer: sourcePixelBuffer, runtimeConfig: runtimeConfig)

        if runtimeConfig.manualSymbolCellROI != nil {
            processRegion(.manualSymbolCell, sourcePixelBuffer: sourcePixelBuffer, runtimeConfig: runtimeConfig)
        }
    }

    private func processRegion(
        _ region: OCRRegionKind,
        sourcePixelBuffer: CVPixelBuffer,
        runtimeConfig: CaptureRuntimeConfig
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
            print("[ocr] frame=\(frameCount) region=\(region.rawValue) gate=invalid_roi roi=\(configuredROI.summary)")
            return
        }

        let totalStart = CFAbsoluteTimeGetCurrent()

        guard let preprocessResult = preprocess(sourcePixelBuffer: sourcePixelBuffer, roi: roi) else {
            print("[ocr] frame=\(frameCount) region=\(region.rawValue) gate=preprocess_failed roi=\(roi.summary)")
            return
        }

        let fingerprintStart = CFAbsoluteTimeGetCurrent()
        let fingerprint = OCRFingerprintPolicy.fingerprint(pixelBuffer: preprocessResult.pixelBuffer)
        let fingerprintMilliseconds = elapsedMilliseconds(since: fingerprintStart)

        let previousFingerprint = lastFingerprintByRegion[region]
        if previousFingerprint == fingerprint {
            let streak = (unchangedStreakByRegion[region] ?? 0) + 1
            unchangedStreakByRegion[region] = streak

            if streak == 1 || streak.isMultiple(of: unchangedLogCadence) {
                let totalMilliseconds = elapsedMilliseconds(since: totalStart)
                print(
                    "[ocr] frame=\(frameCount) region=\(region.rawValue) gate=unchanged skip_ocr=true streak=\(streak) " +
                        "fingerprint=\(fingerprintHex(fingerprint)) crop_ms=\(format(preprocessResult.cropMilliseconds)) " +
                        "metal_ms=\(format(preprocessResult.metalMilliseconds)) fingerprint_ms=\(format(fingerprintMilliseconds)) " +
                        "total_ms=\(format(totalMilliseconds))"
                )
            }
            return
        }

        lastFingerprintByRegion[region] = fingerprint
        unchangedStreakByRegion[region] = 0

        let ocrStart = CFAbsoluteTimeGetCurrent()
        let recognition = recognizeText(in: preprocessResult.pixelBuffer, region: region)
        let ocrMilliseconds = elapsedMilliseconds(since: ocrStart)
        let totalMilliseconds = elapsedMilliseconds(since: totalStart)

        let escapedNormalizedText = escapedForLog(recognition.normalizedText)
        let escapedRawText = escapedForLog(recognition.rawText)
        print(
            "[ocr] frame=\(frameCount) region=\(region.rawValue) gate=changed skip_ocr=false " +
                "fingerprint=\(fingerprintHex(fingerprint)) crop_ms=\(format(preprocessResult.cropMilliseconds)) " +
                "metal_ms=\(format(preprocessResult.metalMilliseconds)) fingerprint_ms=\(format(fingerprintMilliseconds)) " +
                "ocr_ms=\(format(ocrMilliseconds)) total_ms=\(format(totalMilliseconds)) " +
                "raw_text=\"\(escapedRawText)\" normalized_text=\"\(escapedNormalizedText)\" " +
                "confidence=\(format(recognition.confidence, precision: 3))"
        )

        handleTriggerBehavior(for: region, recognition: recognition)
    }

    private func preprocess(sourcePixelBuffer: CVPixelBuffer, roi: PixelRect) -> OCRPreprocessResult? {
        let imageWidth = CVPixelBufferGetWidth(sourcePixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(sourcePixelBuffer)
        guard imageWidth > 0, imageHeight > 0 else {
            return nil
        }

        let cropPreparationStart = CFAbsoluteTimeGetCurrent()

        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
        let ciY = imageHeight - roi.y - roi.height
        let rawCropRect = CGRect(x: roi.x, y: ciY, width: roi.width, height: roi.height).integral
        let boundedCropRect = rawCropRect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard boundedCropRect.width >= 1, boundedCropRect.height >= 1 else {
            return nil
        }

        let croppedImage = sourceImage.cropped(to: boundedCropRect)
        let cropMilliseconds = elapsedMilliseconds(since: cropPreparationStart)

        let metalStart = CFAbsoluteTimeGetCurrent()
        let filteredImage = croppedImage
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0.0,
                    kCIInputContrastKey: 1.35,
                    kCIInputBrightnessKey: 0.02
                ]
            )
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [
                    kCIInputSharpnessKey: 0.4
                ]
            )
            .transformed(by: CGAffineTransform(translationX: -boundedCropRect.origin.x, y: -boundedCropRect.origin.y))

        let outputWidth = Int(boundedCropRect.width)
        let outputHeight = Int(boundedCropRect.height)
        guard let outputPixelBuffer = Self.makeOutputPixelBuffer(width: outputWidth, height: outputHeight) else {
            return nil
        }

        ciContext.render(
            filteredImage,
            to: outputPixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let metalMilliseconds = elapsedMilliseconds(since: metalStart)

        return OCRPreprocessResult(
            pixelBuffer: outputPixelBuffer,
            cropMilliseconds: cropMilliseconds,
            metalMilliseconds: metalMilliseconds
        )
    }

    private func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRRecognitionResult {
        guard let request = requestByRegion[region] else {
            return OCRRecognitionResult(rawText: "", normalizedText: "", confidence: 0)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
            try handler.perform([request])
            let observations = request.results ?? []
            guard
                let topObservation = observations.first,
                let topCandidate = topObservation.topCandidates(1).first
            else {
                return OCRRecognitionResult(rawText: "", normalizedText: "", confidence: 0)
            }

            let rawText = topCandidate.string
            let normalizedText = OCRNormalizationPolicy.normalize(rawText, for: region)
            return OCRRecognitionResult(
                rawText: rawText,
                normalizedText: normalizedText,
                confidence: Double(topCandidate.confidence)
            )
        } catch {
            print("[ocr] frame=\(frameCount) region=\(region.rawValue) gate=ocr_error message=\(error.localizedDescription)")
            return OCRRecognitionResult(rawText: "", normalizedText: "", confidence: 0)
        }
    }

    private func handleTriggerBehavior(for region: OCRRegionKind, recognition: OCRRecognitionResult) {
        switch region {
        case .manualCell:
            handleManualCellBehavior(recognition: recognition)
        case .manualSymbolCell:
            handleManualSymbolBehavior(recognition: recognition)
        }
    }

    private func handleManualCellBehavior(recognition: OCRRecognitionResult) {
        let evaluation = triggerStateMachine.evaluateManualCell(normalizedText: recognition.normalizedText)
        let action: String

        if evaluation.shouldSendBuy {
            action = "buy_sent"
            webSocketClient.send(TradingWebSocketContract.buyMessage, event: "BUY")
        } else if evaluation.isZeroOrEmpty {
            action = "armed"
        } else if evaluation.isDuplicate {
            action = "duplicate_suppressed"
        } else {
            action = "already_triggered_waiting_for_rearm"
        }

        if evaluation.shouldBeep {
            beep()
        }

        print(
            "[trigger] frame=\(frameCount) region=\(OCRRegionKind.manualCell.rawValue) action=\(action) " +
                "raw_text=\"\(escapedForLog(recognition.rawText))\" normalized_text=\"\(escapedForLog(evaluation.normalizedText))\" " +
                "confidence=\(format(recognition.confidence, precision: 3)) parsed_int=\(evaluation.integerValue.map(String.init) ?? "nil") " +
                "zero_or_empty=\(evaluation.isZeroOrEmpty) duplicate=\(evaluation.isDuplicate) " +
                "armed_before=\(evaluation.wasArmed) armed_after=\(evaluation.isArmedAfter)"
        )
    }

    private func handleManualSymbolBehavior(recognition: OCRRecognitionResult) {
        let evaluation = triggerStateMachine.evaluateManualSymbol(normalizedText: recognition.normalizedText)
        let action: String

        if evaluation.shouldSendSubscribe {
            action = "subscribe_sent"
            let message = TradingWebSocketContract.subscribeMessage(symbol: evaluation.normalizedSymbol)
            webSocketClient.send(message, event: "SUBSCRIBE")
        } else if evaluation.isDuplicate {
            action = "duplicate_suppressed"
        } else {
            action = "symbol_empty_no_subscribe"
        }

        if evaluation.shouldBeep {
            beep()
        }

        print(
            "[trigger] frame=\(frameCount) region=\(OCRRegionKind.manualSymbolCell.rawValue) action=\(action) " +
                "raw_text=\"\(escapedForLog(recognition.rawText))\" normalized_text=\"\(escapedForLog(recognition.normalizedText))\" " +
                "symbol=\"\(escapedForLog(evaluation.normalizedSymbol))\" confidence=\(format(recognition.confidence, precision: 3)) " +
                "duplicate=\(evaluation.isDuplicate)"
        )
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        return request
    }

    private static func makeOutputPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBuffer
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
}
