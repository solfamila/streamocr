import Foundation

struct OCRTradingFrameObservation: Equatable, Sendable {
    let frameNumber: Int
    let mediaTime: Double?
    let symbol: OCRTradingSymbolObservation?
    let manualCell: OCRTradingManualCellObservation?

    init(
        frameNumber: Int,
        mediaTime: Double? = nil,
        symbol: OCRTradingSymbolObservation? = nil,
        manualCell: OCRTradingManualCellObservation? = nil
    ) {
        self.frameNumber = frameNumber
        self.mediaTime = mediaTime
        self.symbol = symbol
        self.manualCell = manualCell
    }
}

struct OCRTradingTextObservation: Equatable, Sendable {
    let rawText: String
    let normalizedText: String
    let confidence: Double

    init(rawText: String, normalizedText: String? = nil, confidence: Double) {
        self.rawText = rawText
        self.normalizedText = normalizedText ?? rawText
        self.confidence = confidence
    }
}

struct OCRTradingSymbolObservation: Equatable, Sendable {
    let fingerprint: UInt64?
    let recognition: OCRTradingTextObservation?
    let recognitionState: OCRTradingRecognitionState

    init(
        fingerprint: UInt64? = nil,
        recognition: OCRTradingTextObservation? = nil,
        recognitionState: OCRTradingRecognitionState
    ) {
        self.fingerprint = fingerprint
        self.recognition = recognition
        self.recognitionState = recognitionState
    }
}

struct OCRTradingManualCellObservation: Equatable, Sendable {
    let recognition: OCRTradingTextObservation

    init(rawText: String, normalizedText: String? = nil, confidence: Double) {
        recognition = OCRTradingTextObservation(
            rawText: rawText,
            normalizedText: normalizedText,
            confidence: confidence
        )
    }
}

enum OCRTradingRecognitionState: Equatable, Sendable {
    case notConfigured
    case unchanged
    case changedFingerprintPendingOCR
    case ocrPending
    case recognized
}

enum OCRTradingSymbolUncertaintyReason: Equatable, Sendable {
    case fingerprintChanged
    case ocrPending
    case lowConfidenceChangedSymbol
}

enum OCRTradingSymbolState: Equatable, Sendable {
    case unknown
    case stable(symbol: String, generation: OCRTradingSymbolGeneration, fingerprint: UInt64?)
    case uncertain(previous: String?, reason: OCRTradingSymbolUncertaintyReason)
    case candidate(symbol: String, confirmations: Int, required: Int, previous: String?, fingerprint: UInt64?)
    case subscribing(symbol: String, generation: OCRTradingSymbolGeneration, commandID: OCRTradingCommandID)

    var stableSymbol: String? {
        if case let .stable(symbol, _, _) = self {
            return symbol
        }
        return nil
    }

    var stableGeneration: OCRTradingSymbolGeneration? {
        if case let .stable(_, generation, _) = self {
            return generation
        }
        return nil
    }

    var isStable: Bool {
        stableSymbol != nil
    }
}

struct OCRTradingManualPositionState: Equatable, Sendable {
    var symbolGeneration: OCRTradingSymbolGeneration?
    var isArmed = true
    var zeroLikeStreak = 0
    var pendingIntegerValue: Int?
    var pendingConfirmationCount = 0
    var openPositionPeakValue: Int?
    var sellWasTriggered = false
    var lastText: String?

    mutating func resetForSymbolGeneration(_ generation: OCRTradingSymbolGeneration) {
        symbolGeneration = generation
        isArmed = true
        zeroLikeStreak = 0
        pendingIntegerValue = nil
        pendingConfirmationCount = 0
        openPositionPeakValue = nil
        sellWasTriggered = false
        lastText = nil
    }

    mutating func rearmBuyForCurrentSymbolGeneration() {
        isArmed = true
        zeroLikeStreak = 0
        pendingIntegerValue = nil
        pendingConfirmationCount = 0
        lastText = nil
    }
}

enum OCRTradingRetryKind: Equatable, Hashable, Sendable {
    case buy
    case sell
}

struct OCRTradingRetryKey: Equatable, Hashable, Sendable {
    let kind: OCRTradingRetryKind
    let symbol: String
    let symbolGeneration: OCRTradingSymbolGeneration
}

struct OCRTradingRetryCooldown: Equatable, Sendable {
    let reason: String
    let timestamp: Double
}

struct OCRTradingState: Equatable, Sendable {
    var sessionGeneration: OCRTradingSessionGeneration = 0
    var symbol: OCRTradingSymbolState = .unknown
    var symbolStableSinceFrame: Int?
    var manual = OCRTradingManualPositionState()
    var pendingCommands: [OCRTradingCommandID: OCRTradingPendingCommand] = [:]
    var terminalResults: [OCRTradingCommandID: OCRTradingCommandResult] = [:]
    var recentRetryableRejections: [OCRTradingRetryKey: OCRTradingRetryCooldown] = [:]
    var nextCommandID: OCRTradingCommandID = 1
    var nextSymbolGeneration: OCRTradingSymbolGeneration = 1
}
