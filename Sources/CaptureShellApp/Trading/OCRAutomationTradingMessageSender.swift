import Foundation

@MainActor
struct OCRAutomationTradingConfiguration: Sendable {
    let buyQuantityRatio: Double
    let controllerArmed: Bool
}

final class OCRAutomationTradingMessageSender: TradingMessageSending, @unchecked Sendable {
    private let manager: TradingRuntimeManager
    private let configurationProvider: @MainActor () -> OCRAutomationTradingConfiguration
    private let lock = NSLock()
    private var pendingOperations = 0

    init(
        manager: TradingRuntimeManager,
        configurationProvider: @escaping @MainActor () -> OCRAutomationTradingConfiguration
    ) {
        self.manager = manager
        self.configurationProvider = configurationProvider
    }

    func send(
        _ payload: String,
        event: String,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        beginPendingOperation()

        Task { @MainActor [self] in
            let result: Result<Void, any Error>

            do {
                switch event {
                case "BUY":
                    try handleBuy(payload: payload)
                case "SUBSCRIBE":
                    try handleSubscribe(payload: payload)
                default:
                    throw TradingRuntimeManagerError.actionFailed("Unsupported OCR automation event: \(event)")
                }
                result = .success(())
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

    @MainActor
    private func handleSubscribe(payload: String) throws {
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

        _ = try manager.requestSubscription(symbol: normalized, recalcQtyFromFirstAsk: false)
        manager.appendMessage("OCR subscribed to \(normalized)")
    }

    @MainActor
    private func handleBuy(payload: String) throws {
        let configuration = configurationProvider()
        let buyMessage = try TradingMessageContract.parseBuyMessage(payload)

        guard configuration.controllerArmed else {
            return
        }

        let dashboard = manager.dashboard
        let quantityInput = resolvedBuyQuantity(
            ocrQuantity: buyMessage.ocrQuantity,
            ratio: configuration.buyQuantityRatio,
            fallbackQuantity: dashboard.inputs.quantityInput
        )

        manager.setUIInputs(
            symbolInput: dashboard.inputs.symbolInput,
            subscribedSymbol: dashboard.inputs.subscribedSymbol,
            subscribed: dashboard.inputs.subscribed,
            quantityInput: quantityInput,
            priceBuffer: dashboard.inputs.priceBuffer,
            maxPositionDollars: dashboard.inputs.maxPositionDollars,
            selectedTraceId: dashboard.inputs.selectedTraceId
        )

        _ = try manager.submitBuy(
            source: "OCR",
            note: buyNote(ocrQuantity: buyMessage.ocrQuantity, ratio: configuration.buyQuantityRatio, quantityInput: quantityInput)
        )

        if let ocrQuantity = buyMessage.ocrQuantity {
            manager.appendMessage(
                String(
                    format: "OCR buy submitted: detected %.0f shares x %.4f -> %d shares",
                    Double(ocrQuantity),
                    sanitizedRatio(configuration.buyQuantityRatio),
                    quantityInput
                )
            )
        }
    }

    private func resolvedBuyQuantity(ocrQuantity: Int?, ratio: Double, fallbackQuantity: Int) -> Int {
        guard let ocrQuantity, ocrQuantity > 0 else {
            return max(1, fallbackQuantity)
        }

        let computed = Int(floor(Double(ocrQuantity) * sanitizedRatio(ratio)))
        return max(1, computed)
    }

    private func sanitizedRatio(_ ratio: Double) -> Double {
        ratio.isFinite && ratio > 0 ? ratio : 0.5
    }

    private func buyNote(ocrQuantity: Int?, ratio: Double, quantityInput: Int) -> String {
        if let ocrQuantity {
            return String(
                format: "OCR trigger detected %d shares, ratio %.4f, submitted %d shares",
                ocrQuantity,
                sanitizedRatio(ratio),
                quantityInput
            )
        }

        return "OCR trigger submitted \(quantityInput) shares"
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
