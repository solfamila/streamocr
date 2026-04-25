import Foundation

final class DirectTradingMessageSender: TradingMessageSending, @unchecked Sendable {
    private let manager: TradingRuntimeManager
    private let lock = NSLock()
    private var pendingOperations = 0

    init(manager: TradingRuntimeManager) {
        self.manager = manager
    }

    var reportsTransportOutcomes: Bool { true }

    func send(
        _ payload: String,
        event: String,
        completion: @escaping @Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void
    ) {
        beginPendingOperation()

        Task { @MainActor [self] in
            let result: Result<TradingMessageSendOutcome, any Error>

            do {
                switch event {
                case "BUY":
                    _ = try await manager.submitBuyAsync(source: "OCR", note: "OCR trigger")
                case "SUBSCRIBE":
                    let symbol = try parseSubscribeSymbol(from: payload)
                    _ = try await manager.requestSubscriptionAsync(symbol: symbol, recalcQtyFromFirstAsk: false)
                default:
                    throw TradingRuntimeManagerError.actionFailed("Unsupported direct trading event: \(event)")
                }
                result = .success(.submitted)
            } catch {
                result = .failure(error)
            }

            completion(result)
            finishPendingOperation()
        }
    }

    @discardableResult
    func waitForPendingMessages(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if pendingOperationCount == 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        return pendingOperationCount == 0
    }

    private func parseSubscribeSymbol(from payload: String) throws -> String {
        guard
            let data = payload.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let symbol = object["subscribe"] as? String,
            !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TradingRuntimeManagerError.actionFailed("Missing subscribe symbol in OCR payload.")
        }

        guard let normalized = TradingMessageContract.normalizedOCRSymbol(symbol), normalized == symbol else {
            throw TradingRuntimeManagerError.actionFailed("Invalid subscribe symbol in OCR payload.")
        }

        return normalized
    }

    private var pendingOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingOperations
    }

    private func beginPendingOperation() {
        lock.lock()
        pendingOperations += 1
        lock.unlock()
    }

    private func finishPendingOperation() {
        lock.lock()
        #if DEBUG
        precondition(pendingOperations > 0, "finishPendingOperation called with no pending operations")
        #endif
        if pendingOperations > 0 {
            pendingOperations -= 1
        }
        lock.unlock()
    }
}
