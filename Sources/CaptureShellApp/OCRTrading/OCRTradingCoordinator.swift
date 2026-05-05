import Foundation

struct OCRTradingCoordinator: Sendable {
    private(set) var state: OCRTradingState
    private let manualCellRearmConfirmationFrames: Int
    private let manualCellTriggerConfirmationFrames: Int
    private let manualCellSellMinimumConfidence: Double
    private let manualSymbolTriggerConfirmationFrames: Int
    private let manualSymbolChangedSymbolMinimumConfidence: Double

    init(
        state: OCRTradingState = OCRTradingState(),
        manualCellRearmConfirmationFrames: Int = 1,
        manualCellTriggerConfirmationFrames: Int = 1,
        manualCellSellMinimumConfidence: Double = 0.70,
        manualSymbolTriggerConfirmationFrames: Int = 1,
        manualSymbolChangedSymbolMinimumConfidence: Double = 0.80
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
    }

    static func liveTradingDefaults() -> OCRTradingCoordinator {
        OCRTradingCoordinator(
            manualCellRearmConfirmationFrames: 12,
            manualCellTriggerConfirmationFrames: 2,
            manualSymbolTriggerConfirmationFrames: 2
        )
    }

    mutating func reduce(_ event: OCRTradingEvent) -> [OCRTradingCommand] {
        switch event {
        case let .sessionStarted(generation):
            startSession(generation)
            return []
        case let .sessionStopping(reason):
            cancelPendingCommands(reason: reason)
            return []
        case let .frame(frame):
            return reduce(frame)
        case let .commandCompleted(id, result):
            completeCommand(id: id, result: result)
            return []
        case .brokerSnapshot:
            return []
        }
    }

    private mutating func startSession(_ generation: OCRTradingSessionGeneration) {
        cancelPendingCommands(reason: "OCR trading session generation changed.")
        state.sessionGeneration = generation
        state.symbol = .unknown
        state.symbolStableSinceFrame = nil
        state.manual = OCRTradingManualPositionState()
        state.recentRetryableRejections.removeAll(keepingCapacity: true)
        state.nextSymbolGeneration = 1
    }

    private mutating func reduce(_ frame: OCRTradingFrameObservation) -> [OCRTradingCommand] {
        var commands: [OCRTradingCommand] = []
        updateSymbolState(from: frame, commands: &commands)

        guard
            let stableSymbol = state.symbol.stableSymbol,
            let symbolGeneration = state.symbol.stableGeneration,
            !hasPendingSubscribe(forDifferentSymbolThan: stableSymbol),
            symbolWasStableBeforeFrame(frame.frameNumber)
        else {
            return commands
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
                commands: &commands
            )
        }

        return commands
    }

    private mutating func updateSymbolState(
        from frame: OCRTradingFrameObservation,
        commands: inout [OCRTradingCommand]
    ) {
        guard let symbolObservation = frame.symbol else {
            return
        }

        switch symbolObservation.recognitionState {
        case .notConfigured:
            state.symbol = .unknown
            state.symbolStableSinceFrame = nil
        case .unchanged:
            return
        case .changedFingerprintPendingOCR, .ocrPending:
            markSymbolUncertainIfNeeded(
                fingerprint: symbolObservation.fingerprint,
                reason: symbolObservation.recognitionState == .ocrPending ? .ocrPending : .fingerprintChanged
            )
        case .recognized:
            recognizeSymbol(from: symbolObservation, frame: frame, commands: &commands)
        }
    }

    private mutating func markSymbolUncertainIfNeeded(
        fingerprint: UInt64?,
        reason: OCRTradingSymbolUncertaintyReason
    ) {
        switch state.symbol {
        case let .stable(symbol, _, stableFingerprint):
            if fingerprint == nil || stableFingerprint == nil || fingerprint != stableFingerprint {
                state.symbol = .uncertain(previous: symbol, reason: reason)
                state.symbolStableSinceFrame = nil
            }
        case .unknown, .candidate, .subscribing, .uncertain:
            return
        }
    }

    private mutating func recognizeSymbol(
        from observation: OCRTradingSymbolObservation,
        frame: OCRTradingFrameObservation,
        commands: inout [OCRTradingCommand]
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
                return
            }

            setSymbolCandidate(
                normalizedSymbol,
                previous: symbol,
                fingerprint: observation.fingerprint,
                frame: frame,
                commands: &commands
            )
        case let .candidate(symbol, confirmations, required, previous, _):
            if normalizedSymbol == symbol {
                let nextConfirmations = confirmations + 1
                if nextConfirmations >= required {
                    commands.append(makeSubscribeCommand(
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
                    commands: &commands
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
                    commands: &commands
                )
            }
        case .unknown:
            setSymbolCandidate(
                normalizedSymbol,
                previous: nil,
                fingerprint: observation.fingerprint,
                frame: frame,
                commands: &commands
            )
        case .subscribing:
            return
        }
    }

    private mutating func setSymbolCandidate(
        _ symbol: String,
        previous: String?,
        fingerprint: UInt64?,
        frame: OCRTradingFrameObservation,
        commands: inout [OCRTradingCommand]
    ) {
        if manualSymbolTriggerConfirmationFrames <= 1 {
            commands.append(makeSubscribeCommand(symbol: symbol, frame: frame))
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
        commands: inout [OCRTradingCommand]
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
            integerValue != nil &&
            !isZeroOrEmpty &&
            confirmationProgress >= manualCellTriggerConfirmationFrames

        if shouldRearm {
            state.manual.resetForSymbolGeneration(symbolGeneration)
        }

        if state.manual.lastText != text {
            state.manual.lastText = text
        }

        if shouldTriggerSell,
           !hasPendingCommand(kind: .sell, symbolGeneration: symbolGeneration),
           let sellCommand = makeSellCommand(
            symbol: stableSymbol,
            symbolGeneration: symbolGeneration,
            previousOCRQuantity: openPositionPeakBeforeUpdate,
            currentOCRQuantity: integerValue,
            frame: frame
           ) {
            commands.append(sellCommand)
            return
        }

        if shouldTriggerBuy,
           !hasPendingCommand(kind: .buy, symbolGeneration: symbolGeneration),
           let integerValue {
            commands.append(makeBuyCommand(
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
    ) {
        guard let pending = state.pendingCommands.removeValue(forKey: id) else {
            state.terminalResults[id] = .staleIgnored(reason: "Command is no longer pending.")
            return
        }

        let command = pending.command
        guard command.sessionGeneration == state.sessionGeneration else {
            state.terminalResults[id] = .staleIgnored(reason: "Command belongs to an old OCR session.")
            return
        }

        guard commandStillBelongsToCurrentSymbolWorld(command) else {
            state.terminalResults[id] = .staleIgnored(reason: "Command belongs to an old OCR symbol generation.")
            return
        }

        state.terminalResults[id] = result
        if case .subscribe = command.kind, !result.commitsTradingState {
            state.symbol = .uncertain(previous: pending.previousSymbol, reason: .ocrPending)
            state.symbolStableSinceFrame = nil
        }

        guard result.commitsTradingState else {
            return
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
            cancelManualCommands(except: id, reason: "Symbol generation changed.")
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

    private mutating func cancelPendingCommands(reason: String) {
        for id in state.pendingCommands.keys {
            state.terminalResults[id] = .cancelled(reason: reason)
        }
        state.pendingCommands.removeAll(keepingCapacity: true)
    }

    private mutating func cancelManualCommands(except idToKeep: OCRTradingCommandID, reason: String) {
        for (id, pending) in state.pendingCommands {
            guard id != idToKeep else { continue }
            switch pending.command.kind {
            case .buy, .sell:
                state.pendingCommands[id] = nil
                state.terminalResults[id] = .cancelled(reason: reason)
            case .subscribe:
                continue
            }
        }
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
