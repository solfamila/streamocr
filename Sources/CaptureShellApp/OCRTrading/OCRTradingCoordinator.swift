import Foundation

struct OCRTradingCoordinator: Sendable {
    private(set) var state: OCRTradingState
    private let manualCellRearmConfirmationFrames: Int
    private let manualCellTriggerConfirmationFrames: Int
    private let manualCellSellMinimumConfidence: Double
    private let manualSymbolTriggerConfirmationFrames: Int
    private let manualSymbolChangedSymbolMinimumConfidence: Double
    private let retryableCommandCooldownSeconds: Double
    private let timeProvider: @Sendable () -> Double

    init(
        state: OCRTradingState = OCRTradingState(),
        manualCellRearmConfirmationFrames: Int = 1,
        manualCellTriggerConfirmationFrames: Int = 1,
        manualCellSellMinimumConfidence: Double = 0.70,
        manualSymbolTriggerConfirmationFrames: Int = 1,
        manualSymbolChangedSymbolMinimumConfidence: Double = 0.80,
        retryableCommandCooldownSeconds: Double = 1.0,
        timeProvider: @escaping @Sendable () -> Double = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.state = state
        self.manualCellRearmConfirmationFrames = max(1, manualCellRearmConfirmationFrames)
        self.manualCellTriggerConfirmationFrames = max(1, manualCellTriggerConfirmationFrames)
        self.manualCellSellMinimumConfidence = min(max(0, manualCellSellMinimumConfidence), 1)
        self.manualSymbolTriggerConfirmationFrames = max(1, manualSymbolTriggerConfirmationFrames)
        self.manualSymbolChangedSymbolMinimumConfidence = min(
            max(0, manualSymbolChangedSymbolMinimumConfidence),
            1
        )
        self.retryableCommandCooldownSeconds = max(0, retryableCommandCooldownSeconds)
        self.timeProvider = timeProvider
    }

    static func liveTradingDefaults() -> OCRTradingCoordinator {
        OCRTradingCoordinator(
            manualCellRearmConfirmationFrames: 12,
            manualCellTriggerConfirmationFrames: 2,
            manualSymbolTriggerConfirmationFrames: 2
        )
    }

    mutating func reduce(_ event: OCRTradingEvent) -> OCRTradingEffects {
        switch event {
        case let .sessionStarted(generation):
            return startSession(generation)
        case let .sessionStopping(reason):
            return sessionStopping(reason: reason)
        case let .frame(frame):
            return reduce(frame)
        case let .commandCompleted(id, result):
            return completeCommand(id: id, result: result)
        }
    }

    private mutating func startSession(_ generation: OCRTradingSessionGeneration) -> OCRTradingEffects {
        var effects = OCRTradingEffects()
        effects.appendCancels(cancelPendingCommands(reason: "OCR trading session generation changed."))
        state.sessionGeneration = generation
        state.symbol = .unknown
        state.symbolStableSinceFrame = nil
        state.manual = OCRTradingManualPositionState()
        state.recentRetryableRejections.removeAll(keepingCapacity: true)
        state.nextSymbolGeneration = 1
        return effects
    }

    private mutating func sessionStopping(reason: String) -> OCRTradingEffects {
        var effects = OCRTradingEffects()
        effects.appendCancels(cancelPendingCommands(reason: reason))
        return effects
    }

    private mutating func reduce(_ frame: OCRTradingFrameObservation) -> OCRTradingEffects {
        var effects = OCRTradingEffects()
        updateSymbolState(from: frame, effects: &effects)

        guard
            let stableSymbol = state.symbol.stableSymbol,
            let symbolGeneration = state.symbol.stableGeneration,
            !hasPendingSubscribe(forDifferentSymbolThan: stableSymbol),
            symbolWasStableBeforeFrame(frame.frameNumber)
        else {
            return effects
        }

        if state.manual.symbolGeneration != symbolGeneration {
            state.manual.resetForSymbolGeneration(symbolGeneration)
        }

        if let manualCell = frame.manualCell {
            updateManualState(
                from: manualCell,
                stableSymbol: stableSymbol,
                symbolGeneration: symbolGeneration,
                frame: frame,
                effects: &effects
            )
        }

        return effects
    }

    private mutating func updateSymbolState(
        from frame: OCRTradingFrameObservation,
        effects: inout OCRTradingEffects
    ) {
        guard let symbolObservation = frame.symbol else {
            return
        }

        switch symbolObservation.recognitionState {
        case .notConfigured:
            effects.appendCancels(cancelPendingCommands(reason: "Symbol ROI is not configured."))
            state.symbol = .unknown
            state.symbolStableSinceFrame = nil
            state.manual = OCRTradingManualPositionState()
        case .unchanged:
            return
        case .changedFingerprintPendingOCR, .ocrPending:
            markSymbolUncertainIfNeeded(
                fingerprint: symbolObservation.fingerprint,
                reason: symbolObservation.recognitionState == .ocrPending ? .ocrPending : .fingerprintChanged,
                effects: &effects
            )
        case .recognized:
            recognizeSymbol(from: symbolObservation, frame: frame, effects: &effects)
        }
    }

    private mutating func markSymbolUncertainIfNeeded(
        fingerprint: UInt64?,
        reason: OCRTradingSymbolUncertaintyReason,
        effects: inout OCRTradingEffects
    ) {
        switch state.symbol {
        case let .stable(symbol, _, stableFingerprint):
            if fingerprint == nil || stableFingerprint == nil || fingerprint != stableFingerprint {
                state.symbol = .uncertain(previous: symbol, reason: reason)
                state.symbolStableSinceFrame = nil
                effects.appendCancels(cancelManualCommands(reason: "Symbol became uncertain."))
            }
        case let .subscribing(_, _, commandID):
            let cancellation = cancelPendingSubscribe(
                commandID: commandID,
                reason: "Symbol changed before subscribe completed."
            )
            state.symbol = .uncertain(previous: cancellation.previousSymbol, reason: reason)
            state.symbolStableSinceFrame = nil
            effects.appendCancels(cancellation.cancelledIDs)
        case .unknown, .candidate, .uncertain:
            return
        }
    }

    private mutating func recognizeSymbol(
        from observation: OCRTradingSymbolObservation,
        frame: OCRTradingFrameObservation,
        effects: inout OCRTradingEffects
    ) {
        guard
            let recognition = observation.recognition,
            let normalizedSymbol = TradingMessageContract.normalizedOCRSymbol(recognition.normalizedText)
        else {
            return
        }

        switch state.symbol {
        case let .stable(symbol, generation, _):
            if normalizedSymbol == symbol {
                state.symbol = .stable(
                    symbol: symbol,
                    generation: generation,
                    fingerprint: observation.fingerprint
                )
                return
            }

            guard recognition.confidence >= manualSymbolChangedSymbolMinimumConfidence else {
                state.symbol = .uncertain(previous: symbol, reason: .lowConfidenceChangedSymbol)
                state.symbolStableSinceFrame = nil
                effects.appendCancels(cancelManualCommands(reason: "Symbol changed with low confidence."))
                return
            }

            setSymbolCandidate(
                normalizedSymbol,
                previous: symbol,
                fingerprint: observation.fingerprint,
                frame: frame,
                effects: &effects
            )
        case let .candidate(symbol, confirmations, required, previous, _):
            if normalizedSymbol == symbol {
                let nextConfirmations = confirmations + 1
                if nextConfirmations >= required {
                    effects.append(command: makeSubscribeCommand(
                        symbol: normalizedSymbol,
                        frame: frame
                    ))
                } else {
                    state.symbol = .candidate(
                        symbol: symbol,
                        confirmations: nextConfirmations,
                        required: required,
                        previous: previous,
                        fingerprint: observation.fingerprint
                    )
                }
            } else {
                setSymbolCandidate(
                    normalizedSymbol,
                    previous: previous,
                    fingerprint: observation.fingerprint,
                    frame: frame,
                    effects: &effects
                )
            }
        case let .uncertain(previous, _):
            if let previous, normalizedSymbol == previous {
                let generation = max(1, state.nextSymbolGeneration - 1)
                state.symbol = .stable(
                    symbol: normalizedSymbol,
                    generation: generation,
                    fingerprint: observation.fingerprint
                )
                state.symbolStableSinceFrame = frame.frameNumber
            } else {
                if previous != nil, recognition.confidence < manualSymbolChangedSymbolMinimumConfidence {
                    state.symbol = .uncertain(previous: previous, reason: .lowConfidenceChangedSymbol)
                    state.symbolStableSinceFrame = nil
                    return
                }

                setSymbolCandidate(
                    normalizedSymbol,
                    previous: previous,
                    fingerprint: observation.fingerprint,
                    frame: frame,
                    effects: &effects
                )
            }
        case .unknown:
            setSymbolCandidate(
                normalizedSymbol,
                previous: nil,
                fingerprint: observation.fingerprint,
                frame: frame,
                effects: &effects
            )
        case let .subscribing(symbol, _, commandID):
            guard normalizedSymbol != symbol else {
                return
            }

            let cancellation = cancelPendingSubscribe(
                commandID: commandID,
                reason: "Symbol changed before subscribe completed."
            )
            effects.appendCancels(cancellation.cancelledIDs)

            if cancellation.previousSymbol != nil,
               recognition.confidence < manualSymbolChangedSymbolMinimumConfidence {
                state.symbol = .uncertain(
                    previous: cancellation.previousSymbol,
                    reason: .lowConfidenceChangedSymbol
                )
                state.symbolStableSinceFrame = nil
                return
            }

            setSymbolCandidate(
                normalizedSymbol,
                previous: cancellation.previousSymbol,
                fingerprint: observation.fingerprint,
                frame: frame,
                effects: &effects
            )
        }
    }

    private mutating func setSymbolCandidate(
        _ symbol: String,
        previous: String?,
        fingerprint: UInt64?,
        frame: OCRTradingFrameObservation,
        effects: inout OCRTradingEffects
    ) {
        if previous != nil {
            effects.appendCancels(cancelManualCommands(reason: "Symbol candidate changed."))
        }

        if manualSymbolTriggerConfirmationFrames <= 1 {
            effects.append(command: makeSubscribeCommand(symbol: symbol, frame: frame))
            return
        }

        state.symbol = .candidate(
            symbol: symbol,
            confirmations: 1,
            required: manualSymbolTriggerConfirmationFrames,
            previous: previous,
            fingerprint: fingerprint
        )
        state.symbolStableSinceFrame = nil
    }

    private mutating func updateManualState(
        from observation: OCRTradingManualCellObservation,
        stableSymbol: String,
        symbolGeneration: OCRTradingSymbolGeneration,
        frame: OCRTradingFrameObservation,
        effects: inout OCRTradingEffects
    ) {
        let text = observation.recognition.normalizedText
        let integerValue = ManualCellIntegerPolicy.parseInteger(text)
        let isZeroOrEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || integerValue == 0
        var shouldTriggerSell = false
        let openPositionPeakBeforeUpdate = state.manual.openPositionPeakValue

        if let integerValue,
           let openPositionPeakBeforeUpdate,
           !state.manual.sellWasTriggered {
            if integerValue > openPositionPeakBeforeUpdate {
                state.manual.openPositionPeakValue = integerValue
            } else if integerValue < openPositionPeakBeforeUpdate,
                      isSafeSellDecrease(
                        currentValue: integerValue,
                        peakValue: openPositionPeakBeforeUpdate,
                        confidence: observation.recognition.confidence
                      ) {
                shouldTriggerSell = true
            }
        }

        if isZeroOrEmpty {
            state.manual.zeroLikeStreak += 1
        } else {
            state.manual.zeroLikeStreak = 0
        }

        let shouldRearm =
            isZeroOrEmpty &&
            state.manual.zeroLikeStreak >= manualCellRearmConfirmationFrames
        var confirmationProgress = 0

        if state.manual.isArmed {
            if let integerValue, !isZeroOrEmpty {
                if state.manual.pendingIntegerValue == integerValue {
                    state.manual.pendingConfirmationCount += 1
                } else {
                    state.manual.pendingIntegerValue = integerValue
                    state.manual.pendingConfirmationCount = 1
                }
                confirmationProgress = state.manual.pendingConfirmationCount
            } else {
                state.manual.pendingIntegerValue = nil
                state.manual.pendingConfirmationCount = 0
            }
        } else {
            state.manual.pendingIntegerValue = nil
            state.manual.pendingConfirmationCount = 0
        }

        let shouldTriggerBuy =
            state.manual.isArmed &&
            state.manual.openPositionPeakValue == nil &&
            integerValue != nil &&
            !isZeroOrEmpty &&
            confirmationProgress >= manualCellTriggerConfirmationFrames

        if shouldRearm {
            state.manual.rearmBuyForCurrentSymbolGeneration()
        }

        if state.manual.lastText != text {
            state.manual.lastText = text
        }

        if shouldTriggerSell,
           !hasPendingCommand(kind: .sell, symbolGeneration: symbolGeneration),
           !isRetryableCooldownActive(kind: .sell, symbol: stableSymbol, symbolGeneration: symbolGeneration),
           let sellCommand = makeSellCommand(
            symbol: stableSymbol,
            symbolGeneration: symbolGeneration,
            previousOCRQuantity: openPositionPeakBeforeUpdate,
            currentOCRQuantity: integerValue,
            frame: frame
           ) {
            effects.append(command: sellCommand)
            return
        }

        if shouldTriggerBuy,
           !hasPendingCommand(kind: .buy, symbolGeneration: symbolGeneration),
           !isRetryableCooldownActive(kind: .buy, symbol: stableSymbol, symbolGeneration: symbolGeneration),
           let integerValue {
            effects.append(command: makeBuyCommand(
                symbol: stableSymbol,
                symbolGeneration: symbolGeneration,
                ocrQuantity: integerValue,
                frame: frame
            ))
        }
    }

    private mutating func makeSubscribeCommand(
        symbol: String,
        frame: OCRTradingFrameObservation
    ) -> OCRTradingCommand {
        let generation = state.nextSymbolGeneration
        state.nextSymbolGeneration += 1
        let command = makeCommand(
            kind: .subscribe,
            symbol: symbol,
            symbolGeneration: generation,
            previousSymbol: currentPreviousSymbol(),
            frame: frame
        )
        state.symbol = .subscribing(
            symbol: symbol,
            generation: generation,
            commandID: command.id
        )
        state.symbolStableSinceFrame = nil
        return command
    }

    private mutating func makeBuyCommand(
        symbol: String,
        symbolGeneration: OCRTradingSymbolGeneration,
        ocrQuantity: Int,
        frame: OCRTradingFrameObservation
    ) -> OCRTradingCommand {
        makeCommand(
            kind: .buy(ocrQuantity: ocrQuantity, submittedQuantity: ocrQuantity),
            symbol: symbol,
            symbolGeneration: symbolGeneration,
            frame: frame
        )
    }

    private mutating func makeSellCommand(
        symbol: String,
        symbolGeneration: OCRTradingSymbolGeneration,
        previousOCRQuantity: Int?,
        currentOCRQuantity: Int?,
        frame: OCRTradingFrameObservation
    ) -> OCRTradingCommand? {
        guard state.manual.openPositionPeakValue != nil else {
            return nil
        }

        return makeCommand(
            kind: .sell(
                previousOCRQuantity: previousOCRQuantity,
                currentOCRQuantity: currentOCRQuantity
            ),
            symbol: symbol,
            symbolGeneration: symbolGeneration,
            frame: frame
        )
    }

    private mutating func makeCommand(
        kind: OCRTradingCommand.Kind,
        symbol: String,
        symbolGeneration: OCRTradingSymbolGeneration,
        previousSymbol: String? = nil,
        frame: OCRTradingFrameObservation
    ) -> OCRTradingCommand {
        let command = OCRTradingCommand(
            id: state.nextCommandID,
            kind: kind,
            symbol: symbol,
            symbolGeneration: symbolGeneration,
            sessionGeneration: state.sessionGeneration,
            originatingFrame: frame.frameNumber,
            originatingMediaTime: frame.mediaTime
        )
        state.nextCommandID += 1
        state.pendingCommands[command.id] = OCRTradingPendingCommand(
            command: command,
            previousSymbol: previousSymbol
        )
        return command
    }

    private mutating func completeCommand(
        id: OCRTradingCommandID,
        result: OCRTradingCommandResult
    ) -> OCRTradingEffects {
        var effects = OCRTradingEffects()
        guard let pending = state.pendingCommands.removeValue(forKey: id) else {
            if state.terminalResults[id] == nil {
                state.terminalResults[id] = .staleIgnored(reason: "Command is no longer pending.")
            }
            return effects
        }

        let command = pending.command
        guard command.sessionGeneration == state.sessionGeneration else {
            state.terminalResults[id] = .staleIgnored(reason: "Command belongs to an old OCR session.")
            return effects
        }

        guard commandStillBelongsToCurrentSymbolWorld(command) else {
            state.terminalResults[id] = .staleIgnored(reason: "Command belongs to an old OCR symbol generation.")
            return effects
        }

        state.terminalResults[id] = result
        updateRetryableCooldown(for: command, result: result)
        if case .subscribe = command.kind, !result.commitsTradingState {
            state.symbol = .uncertain(previous: pending.previousSymbol, reason: .ocrPending)
            state.symbolStableSinceFrame = nil
        }

        guard result.commitsTradingState else {
            return effects
        }

        switch command.kind {
        case .subscribe:
            state.symbol = .stable(
                symbol: command.symbol,
                generation: command.symbolGeneration,
                fingerprint: nil
            )
            state.symbolStableSinceFrame = command.originatingFrame
            state.manual.resetForSymbolGeneration(command.symbolGeneration)
            effects.appendCancels(cancelManualCommands(except: id, reason: "Symbol generation changed."))
        case let .buy(ocrQuantity, _):
            state.manual.isArmed = false
            state.manual.pendingIntegerValue = nil
            state.manual.pendingConfirmationCount = 0
            if result == .submitted, ocrQuantity > 0 {
                state.manual.openPositionPeakValue = ocrQuantity
                state.manual.sellWasTriggered = false
            } else {
                state.manual.openPositionPeakValue = nil
                state.manual.sellWasTriggered = false
            }
        case .sell:
            if result == .submitted {
                state.manual.openPositionPeakValue = nil
                state.manual.sellWasTriggered = true
            }
        }
        return effects
    }

    private func commandStillBelongsToCurrentSymbolWorld(_ command: OCRTradingCommand) -> Bool {
        switch command.kind {
        case .subscribe:
            if case let .subscribing(symbol, generation, commandID) = state.symbol {
                return symbol == command.symbol &&
                    generation == command.symbolGeneration &&
                    commandID == command.id
            }
            return false
        case .buy, .sell:
            return state.symbol.stableSymbol == command.symbol &&
                state.symbol.stableGeneration == command.symbolGeneration
        }
    }

    private func currentPreviousSymbol() -> String? {
        switch state.symbol {
        case let .stable(symbol, _, _):
            return symbol
        case let .uncertain(previous, _):
            return previous
        case let .candidate(_, _, _, previous, _):
            return previous
        case .unknown, .subscribing:
            return nil
        }
    }

    private func symbolWasStableBeforeFrame(_ frameNumber: Int) -> Bool {
        guard let symbolStableSinceFrame = state.symbolStableSinceFrame else {
            return false
        }
        return symbolStableSinceFrame < frameNumber
    }

    private mutating func cancelPendingCommands(reason: String) -> [OCRTradingCommandID] {
        var cancelledIDs: [OCRTradingCommandID] = []
        for id in state.pendingCommands.keys.sorted() {
            state.terminalResults[id] = .cancelled(reason: reason)
            cancelledIDs.append(id)
        }
        state.pendingCommands.removeAll(keepingCapacity: true)
        return cancelledIDs
    }

    private mutating func cancelManualCommands(reason: String) -> [OCRTradingCommandID] {
        cancelManualCommands(except: nil, reason: reason)
    }

    private mutating func cancelManualCommands(
        except idToKeep: OCRTradingCommandID? = nil,
        reason: String
    ) -> [OCRTradingCommandID] {
        var cancelledIDs: [OCRTradingCommandID] = []
        for id in state.pendingCommands.keys.sorted() {
            guard let pending = state.pendingCommands[id] else {
                continue
            }
            if let idToKeep, id == idToKeep {
                continue
            }
            switch pending.command.kind {
            case .buy, .sell:
                state.pendingCommands[id] = nil
                state.terminalResults[id] = .cancelled(reason: reason)
                cancelledIDs.append(id)
            case .subscribe:
                continue
            }
        }
        return cancelledIDs
    }

    private mutating func cancelPendingSubscribe(
        commandID: OCRTradingCommandID,
        reason: String
    ) -> (previousSymbol: String?, cancelledIDs: [OCRTradingCommandID]) {
        guard let pending = state.pendingCommands.removeValue(forKey: commandID) else {
            return (previousSymbol: nil, cancelledIDs: [])
        }

        state.terminalResults[commandID] = .cancelled(reason: reason)
        return (previousSymbol: pending.previousSymbol, cancelledIDs: [commandID])
    }

    private func hasPendingSubscribe(forDifferentSymbolThan symbol: String) -> Bool {
        state.pendingCommands.values.contains { pending in
            if case .subscribe = pending.command.kind {
                return pending.command.symbol != symbol
            }
            return false
        }
    }

    private enum PendingCommandKind {
        case buy
        case sell
    }

    private func hasPendingCommand(
        kind: PendingCommandKind,
        symbolGeneration: OCRTradingSymbolGeneration
    ) -> Bool {
        state.pendingCommands.values.contains { pending in
            guard pending.command.symbolGeneration == symbolGeneration else {
                return false
            }

            switch (kind, pending.command.kind) {
            case (.buy, .buy), (.sell, .sell):
                return true
            case (.buy, _), (.sell, _):
                return false
            }
        }
    }

    private mutating func updateRetryableCooldown(
        for command: OCRTradingCommand,
        result: OCRTradingCommandResult
    ) {
        guard let key = retryKey(for: command) else {
            return
        }

        switch result {
        case let .retryableRejected(reason):
            state.recentRetryableRejections[key] = OCRTradingRetryCooldown(
                reason: reason,
                timestamp: timeProvider()
            )
        case .submitted, .intentionallyIgnored, .failed, .cancelled, .staleIgnored:
            state.recentRetryableRejections[key] = nil
        }
    }

    private mutating func isRetryableCooldownActive(
        kind: OCRTradingRetryKind,
        symbol: String,
        symbolGeneration: OCRTradingSymbolGeneration
    ) -> Bool {
        let key = OCRTradingRetryKey(
            kind: kind,
            symbol: symbol,
            symbolGeneration: symbolGeneration
        )
        guard let cooldown = state.recentRetryableRejections[key] else {
            return false
        }

        if timeProvider() - cooldown.timestamp < retryableCommandCooldownSeconds {
            return true
        }

        state.recentRetryableRejections[key] = nil
        return false
    }

    private func retryKey(for command: OCRTradingCommand) -> OCRTradingRetryKey? {
        let kind: OCRTradingRetryKind
        switch command.kind {
        case .buy:
            kind = .buy
        case .sell:
            kind = .sell
        case .subscribe:
            return nil
        }

        return OCRTradingRetryKey(
            kind: kind,
            symbol: command.symbol,
            symbolGeneration: command.symbolGeneration
        )
    }

    private func isSafeSellDecrease(currentValue: Int, peakValue: Int, confidence: Double) -> Bool {
        guard confidence >= manualCellSellMinimumConfidence else {
            return false
        }

        if currentValue == 0 {
            return true
        }

        let looksLikeDroppedDigit =
            digitCount(currentValue) < digitCount(peakValue) &&
            Double(currentValue) < Double(peakValue) * 0.5
        return !looksLikeDroppedDigit
    }

    private func digitCount(_ value: Int) -> Int {
        String(abs(value)).count
    }
}
