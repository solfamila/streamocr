import Foundation

typealias OCRTradingCommandID = UInt64
typealias OCRTradingSessionGeneration = UInt64
typealias OCRTradingSymbolGeneration = UInt64

struct OCRTradingCommand: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case subscribe
        case buy(ocrQuantity: Int, submittedQuantity: Int)
        case sell(previousOCRQuantity: Int?, currentOCRQuantity: Int?)
    }

    let id: OCRTradingCommandID
    let kind: Kind
    let symbol: String
    let symbolGeneration: OCRTradingSymbolGeneration
    let sessionGeneration: OCRTradingSessionGeneration
    let originatingFrame: Int
    let originatingMediaTime: Double?
}

enum OCRTradingCommandResult: Equatable, Sendable {
    case submitted
    case intentionallyIgnored(reason: String)
    case retryableRejected(reason: String)
    case failed(reason: String)
    case cancelled(reason: String)
    case staleIgnored(reason: String)

    var commitsTradingState: Bool {
        switch self {
        case .submitted, .intentionallyIgnored:
            true
        case .retryableRejected, .failed, .cancelled, .staleIgnored:
            false
        }
    }
}

struct OCRTradingPendingCommand: Equatable, Sendable {
    let command: OCRTradingCommand
    let previousSymbol: String?
}

enum OCRTradingEvent {
    case sessionStarted(OCRTradingSessionGeneration)
    case sessionStopping(reason: String)
    case frame(OCRTradingFrameObservation)
    case commandCompleted(OCRTradingCommandID, OCRTradingCommandResult)
    case brokerSnapshot(TradingDashboardSnapshot)
}
