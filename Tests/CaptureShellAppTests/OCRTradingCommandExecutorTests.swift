import Foundation
import Testing
@testable import CaptureShellApp

struct OCRTradingCommandExecutorTests {
    @Test
    func encoderBuildsBoundaryPayloadsFromTypedCommands() throws {
        let subscribe = command(kind: .subscribe, symbol: "PLRZ")
        let buy = command(kind: .buy(ocrQuantity: 10000, submittedQuantity: 5000), symbol: "PLRZ")
        let sell = command(
            kind: .sell(previousOCRQuantity: 30000, currentOCRQuantity: 25950),
            symbol: "PLRZ"
        )

        #expect(try OCRTradingCommandEncoder.encode(subscribe) == OCRTradingCommandPayload(
            event: "SUBSCRIBE",
            payload: #"{"subscribe":"PLRZ"}"#
        ))
        #expect(try OCRTradingCommandEncoder.encode(buy) == OCRTradingCommandPayload(
            event: "BUY",
            payload: #"{"action":"BUY","symbol":"PLRZ","ocrQuantity":10000}"#
        ))
        #expect(try OCRTradingCommandEncoder.encode(sell) == OCRTradingCommandPayload(
            event: "SELL",
            payload: #"{"action":"SELL","symbol":"PLRZ","ocrQuantity":25950,"previousOCRQuantity":30000}"#
        ))
    }

    @Test
    func encoderRejectsInvalidCommandSymbols() {
        do {
            _ = try OCRTradingCommandEncoder.encode(command(kind: .buy(ocrQuantity: 10000, submittedQuantity: 5000), symbol: "PLR2"))
            Issue.record("Expected invalid command symbol to throw.")
        } catch let error as OCRTradingCommandEncodingError {
            #expect(error.localizedDescription.contains("PLR2"))
        } catch {
            Issue.record("Expected OCRTradingCommandEncodingError, got \(error).")
        }
    }

    private func command(kind: OCRTradingCommand.Kind, symbol: String) -> OCRTradingCommand {
        OCRTradingCommand(
            id: 1,
            kind: kind,
            symbol: symbol,
            symbolGeneration: 2,
            sessionGeneration: 3,
            originatingFrame: 4,
            originatingMediaTime: 5
        )
    }
}
