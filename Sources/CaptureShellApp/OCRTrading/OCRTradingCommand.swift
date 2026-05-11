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

    var resultDescription: String {
        switch self {
        case .submitted:
            return "Command submitted."
        case let .intentionallyIgnored(reason),
             let .retryableRejected(reason),
             let .failed(reason),
             let .cancelled(reason),
             let .staleIgnored(reason):
            return reason
        }
    }
}

struct OCRTradingPendingCommand: Equatable, Sendable {
    let command: OCRTradingCommand
    let previousSymbolWorld: OCRTradingPreviousSymbolWorld?
    let symbolFingerprint: UInt64?
}

struct OCRTradingEffects: Equatable, RandomAccessCollection, Sendable {
    typealias Element = OCRTradingCommand
    typealias Index = Array<OCRTradingCommand>.Index

    var commandsToStart: [OCRTradingCommand] = []
    var commandIDsToCancel: [OCRTradingCommandID] = []

    static let none = OCRTradingEffects()

    var startIndex: Index { commandsToStart.startIndex }
    var endIndex: Index { commandsToStart.endIndex }

    subscript(position: Index) -> OCRTradingCommand {
        commandsToStart[position]
    }

    mutating func append(command: OCRTradingCommand) {
        commandsToStart.append(command)
    }

    mutating func appendCancel(_ commandID: OCRTradingCommandID) {
        commandIDsToCancel.append(commandID)
    }

    mutating func appendCancels(_ commandIDs: [OCRTradingCommandID]) {
        commandIDsToCancel.append(contentsOf: commandIDs)
    }
}

enum OCRTradingEvent {
    case sessionStarted(OCRTradingSessionGeneration)
    case sessionStopping(reason: String)
    case frame(OCRTradingFrameObservation)
    case commandCompleted(OCRTradingCommandID, OCRTradingCommandResult)
}

struct OCRTradingCommandAuditEvent: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case started
        case cancellationRequested = "cancellation_requested"
        case completed
    }

    let phase: Phase
    let command: OCRTradingCommand
    let result: OCRTradingCommandResult?
    let coordinatorResult: OCRTradingCommandResult?

    init(
        phase: Phase,
        command: OCRTradingCommand,
        result: OCRTradingCommandResult?,
        coordinatorResult: OCRTradingCommandResult? = nil
    ) {
        self.phase = phase
        self.command = command
        self.result = result
        self.coordinatorResult = coordinatorResult
    }
}

typealias OCRTradingCommandAuditEventHandler = @Sendable (OCRTradingCommandAuditEvent) -> Void
