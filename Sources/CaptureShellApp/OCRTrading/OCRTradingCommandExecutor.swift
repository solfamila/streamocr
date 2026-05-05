import Foundation

struct OCRTradingCommandPayload: Equatable, Sendable {
    let event: String
    let payload: String
}

enum OCRTradingCommandEncodingError: LocalizedError, Sendable {
    case invalidSymbol(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSymbol(symbol):
            "Refusing to execute OCR trading command with invalid symbol: \(symbol)"
        }
    }
}

enum OCRTradingCommandEncoder {
    static func encode(_ command: OCRTradingCommand) throws -> OCRTradingCommandPayload {
        switch command.kind {
        case .subscribe:
            guard let payload = TradingMessageContract.subscribeMessage(symbol: command.symbol) else {
                throw OCRTradingCommandEncodingError.invalidSymbol(command.symbol)
            }
            return OCRTradingCommandPayload(event: "SUBSCRIBE", payload: payload)
        case let .buy(ocrQuantity, _):
            guard TradingMessageContract.normalizedOCRSymbol(command.symbol) == command.symbol else {
                throw OCRTradingCommandEncodingError.invalidSymbol(command.symbol)
            }
            return OCRTradingCommandPayload(
                event: "BUY",
                payload: TradingMessageContract.buyMessage(
                    ocrQuantity: ocrQuantity,
                    symbol: command.symbol
                )
            )
        case let .sell(previousOCRQuantity, currentOCRQuantity):
            guard TradingMessageContract.normalizedOCRSymbol(command.symbol) == command.symbol else {
                throw OCRTradingCommandEncodingError.invalidSymbol(command.symbol)
            }
            return OCRTradingCommandPayload(
                event: "SELL",
                payload: TradingMessageContract.sellMessage(
                    ocrQuantity: currentOCRQuantity,
                    previousOCRQuantity: previousOCRQuantity,
                    symbol: command.symbol
                )
            )
        }
    }
}

protocol OCRTradingCommandExecuting: Sendable {
    func beginCommandSession()
    func execute(_ command: OCRTradingCommand) async -> OCRTradingCommandResult
    func cancelPendingCommand(id: OCRTradingCommandID, reason: String)
    @discardableResult
    func waitForPendingCommands(timeout: TimeInterval) -> Bool
    func cancelPendingCommands(reason: String)
}

extension OCRTradingCommandExecuting {
    func beginCommandSession() {}

    @discardableResult
    func waitForPendingCommands(timeout _: TimeInterval) -> Bool {
        true
    }

    func cancelPendingCommand(id _: OCRTradingCommandID, reason _: String) {}

    func cancelPendingCommands(reason _: String) {}
}

final class OCRTradingDryRunCommandExecutor: OCRTradingCommandExecuting, @unchecked Sendable {
    func execute(_ command: OCRTradingCommand) async -> OCRTradingCommandResult {
        _ = command
        return .submitted
    }
}
