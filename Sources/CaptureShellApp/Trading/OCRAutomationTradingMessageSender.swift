import Foundation

@MainActor
struct OCRAutomationTradingConfiguration: Sendable {
    let buyQuantityRatio: Double
    let controllerArmed: Bool
}

private enum OCRActionRejectionDisposition {
    case intentionallyIgnored(String)
    case retryable(String)
}

final class OCRAutomationTradingMessageSender: TradingMessageSending, @unchecked Sendable {
    private let manager: TradingRuntimeManager
    private let configurationProvider: @MainActor () -> OCRAutomationTradingConfiguration
    private let lock = NSLock()
    private var currentGeneration = 0
    private var pendingOperations = 0
    private var pendingOperationsByGeneration: [Int: Int] = [:]
    private var cancellationReasonsByGeneration: [Int: String] = [:]

    private let buyAvailabilityPollIntervalNanoseconds: UInt64 = 100_000_000
    private let buyAvailabilityTimeoutSeconds: TimeInterval = 2.0

    init(
        manager: TradingRuntimeManager,
        configurationProvider: @escaping @MainActor () -> OCRAutomationTradingConfiguration
    ) {
        self.manager = manager
        self.configurationProvider = configurationProvider
    }

    var reportsTransportOutcomes: Bool { false }

    func beginMessageSession() {
        lock.lock()
        currentGeneration += 1
        cleanupCompletedCancelledGenerationsLocked()
        lock.unlock()
    }

    func send(
        _ payload: String,
        event: String,
        completion: @escaping @Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void
    ) {
        let generation = beginPendingOperation()

        Task { @MainActor [self] in
            let result: Result<TradingMessageSendOutcome, any Error>

            do {
                if let cancellationReason = cancellationReasonSnapshot(for: generation) {
                    result = .failure(TradingMessageSendError.cancelled(reason: cancellationReason))
                } else {
                    switch event {
                    case "BUY":
                        result = .success(try await handleBuy(payload: payload, generation: generation))
                    case "SELL":
                        result = .success(try await handleSell(payload: payload, generation: generation))
                    case "SUBSCRIBE":
                        try throwIfCancelled(generation: generation)
                        result = .success(try await handleSubscribe(payload: payload, generation: generation))
                    default:
                        throw TradingRuntimeManagerError.actionFailed("Unsupported OCR automation event: \(event)")
                    }
                }
            } catch {
                result = .failure(error)
            }

            completion(result)
            finishPendingOperation(generation: generation)
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

    func cancelPendingMessages(reason: String) {
        lock.lock()
        cancellationReasonsByGeneration[currentGeneration] = reason
        lock.unlock()
    }

    @MainActor
    private func handleSubscribe(payload: String, generation: Int) async throws -> TradingMessageSendOutcome {
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

        try throwIfCancelled(generation: generation)
        _ = try await manager.requestSubscriptionAsync(symbol: normalized, recalcQtyFromFirstAsk: false)
        await manager.appendMessageAsync("OCR subscribed to \(normalized)")
        return .submitted
    }

    @MainActor
    private func handleSell(payload: String, generation: Int) async throws -> TradingMessageSendOutcome {
        let sellMessage = try TradingMessageContract.parseSellMessage(payload)
        try throwIfCancelled(generation: generation)

        let preSubmitDashboard = try await awaitSellAvailability(generation: generation)
        print(armedSellAttemptLogLine(snapshot: preSubmitDashboard, sellMessage: sellMessage))

        if let disposition = sellRejectionDisposition(snapshot: preSubmitDashboard) {
            let reason = rejectionReason(for: disposition)
            let rejectionLine = rejectedSellLogLine(
                reason: reason,
                snapshot: preSubmitDashboard,
                sellMessage: sellMessage
            )
            print(rejectionLine)
            await manager.appendMessageAsync("OCR sell rejected: \(reason)")
            switch disposition {
            case .intentionallyIgnored:
                return .intentionallyIgnored(reason: reason)
            case .retryable:
                throw TradingMessageSendError.retryableRejection(reason: reason)
            }
        }

        try throwIfCancelled(generation: generation)

        do {
            _ = try await manager.submitCloseAsync(
                source: "OCR",
                note: sellNote(sellMessage: sellMessage)
            )
        } catch {
            let postFailureDashboard = manager.dashboard
            if let disposition = classifiedSellRejection(error: error, snapshot: postFailureDashboard) {
                let consumedReason = rejectionReason(for: disposition)
                let rejectionLine = rejectedSellLogLine(
                    reason: consumedReason,
                    snapshot: postFailureDashboard,
                    sellMessage: sellMessage
                )
                print(rejectionLine)
                await manager.appendMessageAsync("OCR sell rejected: \(consumedReason)")
                switch disposition {
                case .intentionallyIgnored:
                    return .intentionallyIgnored(reason: consumedReason)
                case .retryable:
                    throw TradingMessageSendError.retryableRejection(reason: consumedReason)
                }
            }

            let failureLine = failedSellLogLine(
                error: error,
                snapshot: postFailureDashboard,
                sellMessage: sellMessage
            )
            print(failureLine)
            await manager.appendMessageAsync("OCR sell rejected: \(error.localizedDescription)")
            throw error
        }

        print(submittedSellLogLine(snapshot: manager.dashboard, sellMessage: sellMessage))
        await manager.appendMessageAsync(submittedSellMessage(sellMessage: sellMessage))
        return .submitted
    }

    @MainActor
    private func handleBuy(payload: String, generation: Int) async throws -> TradingMessageSendOutcome {
        let configuration = configurationProvider()
        let buyMessage = try TradingMessageContract.parseBuyMessage(payload)
        let quantityInput = resolvedBuyQuantity(
            ocrQuantity: buyMessage.ocrQuantity,
            ratio: configuration.buyQuantityRatio,
            fallbackQuantity: manager.dashboard.inputs.quantityInput
        )

        guard configuration.controllerArmed else {
            print(disarmedBuyLogLine(ocrQuantity: buyMessage.ocrQuantity, ratio: configuration.buyQuantityRatio, quantityInput: quantityInput))
            return .intentionallyIgnored(reason: "Controller trading is not armed.")
        }

        try throwIfCancelled(generation: generation)

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

        let preSubmitDashboard = try await awaitBuyAvailability(quantityInput: quantityInput, generation: generation)
        print(armedBuyAttemptLogLine(
            snapshot: preSubmitDashboard,
            ocrQuantity: buyMessage.ocrQuantity,
            ratio: configuration.buyQuantityRatio,
            quantityInput: quantityInput
        ))

        if let disposition = buyRejectionDisposition(snapshot: preSubmitDashboard) {
            let reason = rejectionReason(for: disposition)
            let rejectionLine = rejectedBuyLogLine(
                reason: reason,
                snapshot: preSubmitDashboard,
                ocrQuantity: buyMessage.ocrQuantity,
                ratio: configuration.buyQuantityRatio,
                quantityInput: quantityInput
            )
            print(rejectionLine)
            await manager.appendMessageAsync("OCR buy rejected: \(reason)")
            switch disposition {
            case .intentionallyIgnored:
                return .intentionallyIgnored(reason: reason)
            case .retryable:
                throw TradingMessageSendError.retryableRejection(reason: reason)
            }
        }

        try throwIfCancelled(generation: generation)

        do {
            _ = try await manager.submitBuyAsync(
                source: "OCR",
                note: buyNote(ocrQuantity: buyMessage.ocrQuantity, ratio: configuration.buyQuantityRatio, quantityInput: quantityInput)
            )
        } catch {
            let postFailureDashboard = manager.dashboard
            if let disposition = classifiedBuyRejection(error: error, snapshot: postFailureDashboard) {
                let consumedReason = rejectionReason(for: disposition)
                let rejectionLine = rejectedBuyLogLine(
                    reason: consumedReason,
                    snapshot: postFailureDashboard,
                    ocrQuantity: buyMessage.ocrQuantity,
                    ratio: configuration.buyQuantityRatio,
                    quantityInput: quantityInput
                )
                print(rejectionLine)
                await manager.appendMessageAsync("OCR buy rejected: \(consumedReason)")
                switch disposition {
                case .intentionallyIgnored:
                    return .intentionallyIgnored(reason: consumedReason)
                case .retryable:
                    throw TradingMessageSendError.retryableRejection(reason: consumedReason)
                }
            }
            let failureLine = failedBuyLogLine(
                error: error,
                snapshot: postFailureDashboard,
                ocrQuantity: buyMessage.ocrQuantity,
                ratio: configuration.buyQuantityRatio,
                quantityInput: quantityInput
            )
            print(failureLine)
            await manager.appendMessageAsync("OCR buy rejected: \(error.localizedDescription)")
            throw error
        }

        print(submittedBuyLogLine(ocrQuantity: buyMessage.ocrQuantity, ratio: configuration.buyQuantityRatio, quantityInput: quantityInput))
        if let ocrQuantity = buyMessage.ocrQuantity {
            await manager.appendMessageAsync(
                String(
                    format: "OCR buy submitted: detected %.0f shares x %.4f -> %d shares",
                    Double(ocrQuantity),
                    sanitizedRatio(configuration.buyQuantityRatio),
                    quantityInput
                )
            )
        }

        return .submitted
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

    private func armedSellAttemptLogLine(
        snapshot: TradingDashboardSnapshot,
        sellMessage: OCRSellMessage
    ) -> String {
        "OCR sell signal armed: \(sellSignalSummary(sellMessage)); \(sellGateDiagnostic(snapshot: snapshot))"
    }

    private func submittedSellLogLine(
        snapshot: TradingDashboardSnapshot,
        sellMessage: OCRSellMessage
    ) -> String {
        "OCR sell signal submitted: \(sellSignalSummary(sellMessage)); \(sellGateDiagnostic(snapshot: snapshot))"
    }

    private func rejectedSellLogLine(
        reason: String,
        snapshot: TradingDashboardSnapshot,
        sellMessage: OCRSellMessage
    ) -> String {
        "OCR sell signal rejected: \(sellSignalSummary(sellMessage)); reason=\(reason); \(sellGateDiagnostic(snapshot: snapshot))"
    }

    private func failedSellLogLine(
        error: any Error,
        snapshot: TradingDashboardSnapshot,
        sellMessage: OCRSellMessage
    ) -> String {
        "OCR sell signal failed: \(sellSignalSummary(sellMessage)); error=\(error.localizedDescription); \(sellGateDiagnostic(snapshot: snapshot))"
    }

    private func submittedSellMessage(sellMessage: OCRSellMessage) -> String {
        "OCR sell submitted: \(sellSignalSummary(sellMessage))"
    }

    private func sellSignalSummary(_ sellMessage: OCRSellMessage) -> String {
        switch (sellMessage.previousOCRQuantity, sellMessage.ocrQuantity) {
        case let (.some(previous), .some(current)):
            "detected position decrease \(previous) -> \(current) shares"
        case let (.some(previous), .none):
            "detected position decrease from \(previous) shares"
        case let (.none, .some(current)):
            "detected position decrease to \(current) shares"
        case (.none, .none):
            "detected position decrease"
        }
    }

    private func sellGateDiagnostic(snapshot: TradingDashboardSnapshot) -> String {
        let status = snapshot.panel.status
        let panel = snapshot.panel
        let symbol = snapshot.inputs.subscribedSymbol.isEmpty ? snapshot.inputs.symbolInput : snapshot.inputs.subscribedSymbol
        return String(
            format: "symbol=%@ connected=%@ sessionReady=%@ subscribed=%@ freshQuote=%@ canTrade=%@ canClose=%@ controllerArmed=%@ killSwitch=%@ closeableShares=%.0f sellPrice=%.4f quoteAgeMs=%.0f",
            symbol.isEmpty ? "<empty>" : symbol,
            status.connected.description,
            status.sessionReady.description,
            snapshot.inputs.subscribed.description,
            panel.symbol.hasFreshQuote.description,
            panel.canTrade.description,
            panel.canClosePosition.description,
            status.controllerArmed.description,
            status.tradingKillSwitch.description,
            panel.symbol.availableLongToClose,
            panel.sellPrice,
            panel.symbol.quoteAgeMs
        )
    }

    private func classifiedBuyRejection(
        error: any Error,
        snapshot: TradingDashboardSnapshot
    ) -> OCRActionRejectionDisposition? {
        if let sendError = error as? TradingMessageSendError {
            switch sendError {
            case let .retryableRejection(reason):
                return .retryable(reason)
            case let .cancelled(reason):
                return .intentionallyIgnored(reason)
            }
        }

        if case let TradingRuntimeManagerError.actionFailed(message) = error {
            if message == "Buy action is not currently available" {
                return buyRejectionDisposition(snapshot: snapshot)
            }

            if isRuntimeBuyGateError(message) {
                return classifyKnownRuntimeBuyGateMessage(message)
            }
        }

        if !snapshot.panel.canBuy {
            return buyRejectionDisposition(snapshot: snapshot)
        }

        return nil
    }

    private func classifiedSellRejection(
        error: any Error,
        snapshot: TradingDashboardSnapshot
    ) -> OCRActionRejectionDisposition? {
        if let sendError = error as? TradingMessageSendError {
            switch sendError {
            case let .retryableRejection(reason):
                return .retryable(reason)
            case let .cancelled(reason):
                return .intentionallyIgnored(reason)
            }
        }

        if case let TradingRuntimeManagerError.actionFailed(message) = error {
            if message == "Close action is not currently available" {
                return sellRejectionDisposition(snapshot: snapshot)
            }

            if isRuntimeSellGateError(message) {
                return classifyKnownRuntimeSellGateMessage(message)
            }
        }

        if !snapshot.panel.canClosePosition {
            return sellRejectionDisposition(snapshot: snapshot)
        }

        return nil
    }

    private func buyRejectionDisposition(snapshot: TradingDashboardSnapshot) -> OCRActionRejectionDisposition? {
        let reason = specificBuyUnavailableReason(snapshot)
        switch reason {
        case "Kill switch is enabled.",
            "Order exceeds the max order notional limit.",
            "Projected exposure exceeds the max open notional limit.":
            return .intentionallyIgnored(reason)
        case "Buy action is not currently available.":
            return .retryable(reason)
        default:
            return .retryable(reason)
        }
    }

    private func sellRejectionDisposition(snapshot: TradingDashboardSnapshot) -> OCRActionRejectionDisposition? {
        .retryable(specificSellUnavailableReason(snapshot))
    }

    private func classifyKnownRuntimeBuyGateMessage(_ message: String) -> OCRActionRejectionDisposition {
        if message == "Trading is halted by the kill switch" ||
            message.hasPrefix("Order notional $") ||
            message.hasPrefix("Projected open notional $")
        {
            return .intentionallyIgnored(message)
        }

        return .retryable(message)
    }

    private func classifyKnownRuntimeSellGateMessage(_ message: String) -> OCRActionRejectionDisposition {
        .retryable(message)
    }

    private func rejectionReason(for disposition: OCRActionRejectionDisposition) -> String {
        switch disposition {
        case let .intentionallyIgnored(reason), let .retryable(reason):
            return reason
        }
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

    private func specificSellUnavailableReason(_ snapshot: TradingDashboardSnapshot) -> String {
        let status = snapshot.panel.status
        let panel = snapshot.panel
        if !status.connected { return "TWS is disconnected." }
        if !status.sessionReady { return "TWS session is still initializing." }
        if !snapshot.inputs.subscribed { return "Subscribe to a symbol first." }
        if !panel.symbol.hasFreshQuote { return "Waiting for a fresh quote." }
        if status.tradingKillSwitch { return "Kill switch is enabled." }
        if !panel.canTrade { return "Trading is not currently available for the active symbol." }
        if panel.symbol.availableLongToClose <= 0 { return "No long position is available to close." }
        if panel.sellPrice <= 0 { return "Waiting for a sell price." }
        if !panel.canClosePosition { return "Close is not currently available." }
        return "Close action is not currently available."
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

    private func isRuntimeSellGateError(_ message: String) -> Bool {
        let knownPrefixes = [
            "TWS session not ready",
            "Configured account is not present",
            "Trading is halted by the kill switch",
            "No quote has been received for the active symbol yet",
            "Quote is stale",
            "No long shares available to close"
        ]
        return knownPrefixes.contains { message.hasPrefix($0) }
    }

    @MainActor
    private func awaitBuyAvailability(quantityInput: Int, generation: Int) async throws -> TradingDashboardSnapshot {
        manager.refreshDashboard()
        var snapshot = manager.dashboard
        if snapshot.panel.canBuy {
            return snapshot
        }

        let deadline = Date().addingTimeInterval(buyAvailabilityTimeoutSeconds)
        while Date() < deadline {
            try throwIfCancelled(generation: generation)
            try await Task.sleep(nanoseconds: buyAvailabilityPollIntervalNanoseconds)
            manager.refreshDashboard()
            snapshot = manager.dashboard
            if snapshot.panel.canBuy {
                return snapshot
            }

            if snapshot.panel.status.tradingKillSwitch {
                return snapshot
            }

            if quantityInput <= 0 {
                return snapshot
            }
        }

        return snapshot
    }

    @MainActor
    private func awaitSellAvailability(generation: Int) async throws -> TradingDashboardSnapshot {
        manager.refreshDashboard()
        var snapshot = manager.dashboard
        if snapshot.panel.canClosePosition {
            return snapshot
        }

        let deadline = Date().addingTimeInterval(buyAvailabilityTimeoutSeconds)
        while Date() < deadline {
            try throwIfCancelled(generation: generation)
            try await Task.sleep(nanoseconds: buyAvailabilityPollIntervalNanoseconds)
            manager.refreshDashboard()
            snapshot = manager.dashboard
            if snapshot.panel.canClosePosition {
                return snapshot
            }

            if snapshot.panel.status.tradingKillSwitch {
                return snapshot
            }
        }

        return snapshot
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

    private func sellNote(sellMessage: OCRSellMessage) -> String {
        "OCR trigger \(sellSignalSummary(sellMessage))"
    }

    private var pendingOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingOperations
    }

    private func cancellationReasonSnapshot(for generation: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationReasonsByGeneration[generation]
    }

    @MainActor
    private func throwIfCancelled(generation: Int) throws {
        if let cancellationReason = cancellationReasonSnapshot(for: generation) {
            throw TradingMessageSendError.cancelled(reason: cancellationReason)
        }
    }

    private func beginPendingOperation() -> Int {
        lock.lock()
        let generation = currentGeneration
        pendingOperations += 1
        pendingOperationsByGeneration[generation, default: 0] += 1
        lock.unlock()
        return generation
    }

    private func finishPendingOperation(generation: Int) {
        lock.lock()
        #if DEBUG
        precondition(pendingOperations > 0, "finishPendingOperation called with no pending operations")
        #endif
        if pendingOperations > 0 {
            pendingOperations -= 1
        }
        if let generationCount = pendingOperationsByGeneration[generation] {
            let nextCount = generationCount - 1
            if nextCount > 0 {
                pendingOperationsByGeneration[generation] = nextCount
            } else {
                pendingOperationsByGeneration[generation] = nil
            }
        }
        cleanupCompletedCancelledGenerationsLocked()
        lock.unlock()
    }

    private func cleanupCompletedCancelledGenerationsLocked() {
        for generation in cancellationReasonsByGeneration.keys where
            generation != currentGeneration &&
            pendingOperationsByGeneration[generation, default: 0] == 0 {
            cancellationReasonsByGeneration[generation] = nil
        }
    }
}
