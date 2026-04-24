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

    var reportsTransportOutcomes: Bool { false }

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
        let quantityInput = resolvedBuyQuantity(
            ocrQuantity: buyMessage.ocrQuantity,
            ratio: configuration.buyQuantityRatio,
            fallbackQuantity: manager.dashboard.inputs.quantityInput
        )

        guard configuration.controllerArmed else {
            print(disarmedBuyLogLine(ocrQuantity: buyMessage.ocrQuantity, ratio: configuration.buyQuantityRatio, quantityInput: quantityInput))
            return
        }

        let dashboard = manager.dashboard

        manager.setUIInputs(
            symbolInput: dashboard.inputs.symbolInput,
            subscribedSymbol: dashboard.inputs.subscribedSymbol,
            subscribed: dashboard.inputs.subscribed,
            quantityInput: quantityInput,
            priceBuffer: dashboard.inputs.priceBuffer,
            maxPositionDollars: dashboard.inputs.maxPositionDollars,
            selectedTraceId: dashboard.inputs.selectedTraceId
        )

        let preSubmitDashboard = manager.dashboard
        print(armedBuyAttemptLogLine(
            snapshot: preSubmitDashboard,
            ocrQuantity: buyMessage.ocrQuantity,
            ratio: configuration.buyQuantityRatio,
            quantityInput: quantityInput
        ))

        do {
            _ = try manager.submitBuy(
                source: "OCR",
                note: buyNote(ocrQuantity: buyMessage.ocrQuantity, ratio: configuration.buyQuantityRatio, quantityInput: quantityInput)
            )
        } catch {
            let postFailureDashboard = manager.dashboard
            if let consumedReason = consumedBuyRejectionReason(error: error, snapshot: postFailureDashboard) {
                let rejectionLine = rejectedBuyLogLine(
                    reason: consumedReason,
                    snapshot: postFailureDashboard,
                    ocrQuantity: buyMessage.ocrQuantity,
                    ratio: configuration.buyQuantityRatio,
                    quantityInput: quantityInput
                )
                print(rejectionLine)
                manager.appendMessage("OCR buy rejected: \(consumedReason)")
                return
            }
            let failureLine = failedBuyLogLine(
                error: error,
                snapshot: postFailureDashboard,
                ocrQuantity: buyMessage.ocrQuantity,
                ratio: configuration.buyQuantityRatio,
                quantityInput: quantityInput
            )
            print(failureLine)
            manager.appendMessage("OCR buy rejected: \(error.localizedDescription)")
            throw error
        }

        print(submittedBuyLogLine(ocrQuantity: buyMessage.ocrQuantity, ratio: configuration.buyQuantityRatio, quantityInput: quantityInput))
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

    private func disarmedBuyLogLine(ocrQuantity: Int?, ratio: Double, quantityInput: Int) -> String {
        if let ocrQuantity {
            return String(
                format: "OCR buy signal detected while controller disarmed: detected %.0f shares x %.4f -> %d shares (not submitted)",
                Double(ocrQuantity),
                sanitizedRatio(ratio),
                quantityInput
            )
        }

        return "OCR buy signal detected while controller disarmed: using fallback quantity \(quantityInput) shares (not submitted)"
    }

    private func submittedBuyLogLine(ocrQuantity: Int?, ratio: Double, quantityInput: Int) -> String {
        if let ocrQuantity {
            return String(
                format: "OCR buy signal submitted: detected %.0f shares x %.4f -> %d shares",
                Double(ocrQuantity),
                sanitizedRatio(ratio),
                quantityInput
            )
        }

        return "OCR buy signal submitted: using fallback quantity \(quantityInput) shares"
    }

    private func rejectedBuyLogLine(
        reason: String,
        snapshot: TradingDashboardSnapshot,
        ocrQuantity: Int?,
        ratio: Double,
        quantityInput: Int
    ) -> String {
        let prefix: String
        if let ocrQuantity {
            prefix = String(
                format: "OCR buy signal rejected: detected %.0f shares x %.4f -> %d shares",
                Double(ocrQuantity),
                sanitizedRatio(ratio),
                quantityInput
            )
        } else {
            prefix = "OCR buy signal rejected: using fallback quantity \(quantityInput) shares"
        }
        return "\(prefix); reason=\(reason); \(buyGateDiagnostic(snapshot: snapshot, quantityInput: quantityInput))"
    }

    private func armedBuyAttemptLogLine(
        snapshot: TradingDashboardSnapshot,
        ocrQuantity: Int?,
        ratio: Double,
        quantityInput: Int
    ) -> String {
        let prefix: String
        if let ocrQuantity {
            prefix = String(
                format: "OCR buy signal armed: detected %.0f shares x %.4f -> %d shares",
                Double(ocrQuantity),
                sanitizedRatio(ratio),
                quantityInput
            )
        } else {
            prefix = "OCR buy signal armed: using fallback quantity \(quantityInput) shares"
        }
        return "\(prefix); \(buyGateDiagnostic(snapshot: snapshot, quantityInput: quantityInput))"
    }

    private func failedBuyLogLine(
        error: any Error,
        snapshot: TradingDashboardSnapshot,
        ocrQuantity: Int?,
        ratio: Double,
        quantityInput: Int
    ) -> String {
        let prefix: String
        if let ocrQuantity {
            prefix = String(
                format: "OCR buy signal failed: detected %.0f shares x %.4f -> %d shares",
                Double(ocrQuantity),
                sanitizedRatio(ratio),
                quantityInput
            )
        } else {
            prefix = "OCR buy signal failed: using fallback quantity \(quantityInput) shares"
        }
        return "\(prefix); error=\(error.localizedDescription); \(buyGateDiagnostic(snapshot: snapshot, quantityInput: quantityInput))"
    }

    private func buyGateDiagnostic(snapshot: TradingDashboardSnapshot, quantityInput: Int) -> String {
        let status = snapshot.panel.status
        let panel = snapshot.panel
        let symbol = snapshot.inputs.subscribedSymbol.isEmpty ? snapshot.inputs.symbolInput : snapshot.inputs.subscribedSymbol
        return String(
            format: "symbol=%@ connected=%@ sessionReady=%@ subscribed=%@ freshQuote=%@ canTrade=%@ canBuy=%@ controllerArmed=%@ killSwitch=%@ qty=%d buyPrice=%.4f quoteAgeMs=%.0f orderNotional=%.2f projectedOpenNotional=%.2f maxOrderNotional=%.2f maxOpenNotional=%.2f",
            symbol.isEmpty ? "<empty>" : symbol,
            status.connected.description,
            status.sessionReady.description,
            snapshot.inputs.subscribed.description,
            panel.symbol.hasFreshQuote.description,
            panel.canTrade.description,
            panel.canBuy.description,
            status.controllerArmed.description,
            status.tradingKillSwitch.description,
            quantityInput,
            panel.buyPrice,
            panel.symbol.quoteAgeMs,
            panel.orderNotional,
            panel.projectedOpenNotional,
            panel.risk.maxOrderNotional,
            panel.risk.maxOpenNotional
        )
    }

    private func consumedBuyRejectionReason(
        error: any Error,
        snapshot: TradingDashboardSnapshot
    ) -> String? {
        if case let TradingRuntimeManagerError.actionFailed(message) = error {
            if message == "Buy action is not currently available" {
                return specificBuyUnavailableReason(snapshot)
            }

            if isRuntimeBuyGateError(message) {
                return message
            }
        }

        if !snapshot.panel.canBuy {
            return specificBuyUnavailableReason(snapshot)
        }

        return nil
    }

    private func specificBuyUnavailableReason(_ snapshot: TradingDashboardSnapshot) -> String {
        let status = snapshot.panel.status
        let panel = snapshot.panel
        if !status.connected { return "TWS is disconnected." }
        if !status.sessionReady { return "TWS session is still initializing." }
        if !snapshot.inputs.subscribed { return "Subscribe to a symbol first." }
        if !panel.symbol.hasFreshQuote { return "Waiting for a fresh quote." }
        if status.tradingKillSwitch { return "Kill switch is enabled." }
        if panel.risk.maxOrderNotional > 0, panel.orderNotional > panel.risk.maxOrderNotional {
            return "Order exceeds the max order notional limit."
        }
        if panel.risk.maxOpenNotional > 0, panel.projectedOpenNotional > panel.risk.maxOpenNotional {
            return "Projected exposure exceeds the max open notional limit."
        }
        if !panel.canTrade { return "Trading is not currently available for the active symbol." }
        if !panel.canBuy { return "Buy is not currently available." }
        return "Buy action is not currently available."
    }

    private func isRuntimeBuyGateError(_ message: String) -> Bool {
        let knownPrefixes = [
            "TWS session not ready",
            "Configured account is not present",
            "Trading is halted by the kill switch",
            "No quote has been received for the active symbol yet",
            "Quote is stale",
            "Order notional $",
            "Projected open notional $"
        ]
        return knownPrefixes.contains { message.hasPrefix($0) }
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
