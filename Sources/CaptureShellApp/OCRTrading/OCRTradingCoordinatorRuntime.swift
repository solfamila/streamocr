import Foundation

final class OCRTradingCoordinatorRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private let executor: any OCRTradingCommandExecuting
    private let eventHandler: OCRPipelineEventHandler?
    private let emitsTransportOutcomes: Bool
    private var coordinator: OCRTradingCoordinator
    private var triggerEventsByCommandID: [OCRTradingCommandID: OCRPipelineEvent] = [:]
    private var inFlightCommandCount = 0

    init(
        coordinator: OCRTradingCoordinator = OCRTradingCoordinator(),
        executor: any OCRTradingCommandExecuting,
        eventHandler: OCRPipelineEventHandler? = nil,
        emitsTransportOutcomes: Bool = false
    ) {
        self.coordinator = coordinator
        self.executor = executor
        self.eventHandler = eventHandler
        self.emitsTransportOutcomes = emitsTransportOutcomes
    }

    var stateSnapshot: OCRTradingState {
        lock.lock()
        defer { lock.unlock() }
        return coordinator.state
    }

    func beginSession(_ generation: OCRTradingSessionGeneration) {
        executor.beginCommandSession()
        let commands = reduce(.sessionStarted(generation))
        dispatch(commands, observation: nil)
    }

    func handle(_ observation: OCRTradingFrameObservation) {
        let commands = reduce(.frame(observation))
        dispatch(commands, observation: observation)
    }

    func stop(reason: String) {
        let commands = reduce(.sessionStopping(reason: reason))
        executor.cancelPendingCommands(reason: reason)
        dispatch(commands, observation: nil)
    }

    @discardableResult
    func waitForPendingCommands(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if isIdle() && executor.waitForPendingCommands(timeout: 0) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        return isIdle() && executor.waitForPendingCommands(timeout: 0)
    }

    private func reduce(_ event: OCRTradingEvent) -> [OCRTradingCommand] {
        lock.lock()
        defer { lock.unlock() }
        return coordinator.reduce(event)
    }

    private func dispatch(
        _ commands: [OCRTradingCommand],
        observation: OCRTradingFrameObservation?
    ) {
        for command in commands {
            let triggerEvent = makeTriggerEvent(command: command, observation: observation)
            lock.lock()
            triggerEventsByCommandID[command.id] = triggerEvent
            inFlightCommandCount += 1
            lock.unlock()
            eventHandler?(triggerEvent)

            Task { [weak self] in
                guard let self else {
                    return
                }
                let result = await executor.execute(command)
                complete(commandID: command.id, result: result)
            }
        }
    }

    private func complete(
        commandID: OCRTradingCommandID,
        result: OCRTradingCommandResult
    ) {
        let triggerEvent: OCRPipelineEvent?
        let shouldEmitTransportOutcome: Bool
        lock.lock()
        _ = coordinator.reduce(.commandCompleted(commandID, result))
        triggerEvent = triggerEventsByCommandID.removeValue(forKey: commandID)
        shouldEmitTransportOutcome = emitsTransportOutcomes && triggerEvent != nil
        if !shouldEmitTransportOutcome {
            finishInFlightCommandLocked()
        }
        lock.unlock()

        guard shouldEmitTransportOutcome, let triggerEvent else {
            return
        }

        eventHandler?(transportOutcomeEvent(from: triggerEvent, result: result))
        lock.lock()
        finishInFlightCommandLocked()
        lock.unlock()
    }

    private func makeTriggerEvent(
        command: OCRTradingCommand,
        observation: OCRTradingFrameObservation?
    ) -> OCRPipelineEvent {
        switch command.kind {
        case .subscribe:
            let recognition = observation?.symbol?.recognition
            return OCRPipelineEvent(
                kind: .trigger,
                frameNumber: command.originatingFrame,
                region: OCRRegionKind.manualSymbolCell.rawValue,
                action: "subscribe_triggered",
                rawText: recognition?.rawText ?? command.symbol,
                normalizedText: recognition?.normalizedText ?? command.symbol,
                confidence: recognition?.confidence ?? 0,
                symbol: command.symbol,
                parsedInteger: nil,
                isDuplicate: nil,
                isZeroOrEmpty: nil,
                presentationTimeSeconds: command.originatingMediaTime
            )
        case let .buy(ocrQuantity, _):
            let recognition = observation?.manualCell?.recognition
            return OCRPipelineEvent(
                kind: .trigger,
                frameNumber: command.originatingFrame,
                region: OCRRegionKind.manualCell.rawValue,
                action: "buy_triggered",
                rawText: recognition?.rawText ?? String(ocrQuantity),
                normalizedText: recognition?.normalizedText ?? String(ocrQuantity),
                confidence: recognition?.confidence ?? 0,
                symbol: command.symbol,
                parsedInteger: ocrQuantity,
                isDuplicate: nil,
                isZeroOrEmpty: false,
                presentationTimeSeconds: command.originatingMediaTime
            )
        case let .sell(_, currentOCRQuantity):
            let recognition = observation?.manualCell?.recognition
            return OCRPipelineEvent(
                kind: .trigger,
                frameNumber: command.originatingFrame,
                region: OCRRegionKind.manualCell.rawValue,
                action: "sell_triggered",
                rawText: recognition?.rawText ?? currentOCRQuantity.map(String.init) ?? "",
                normalizedText: recognition?.normalizedText ?? currentOCRQuantity.map(String.init) ?? "",
                confidence: recognition?.confidence ?? 0,
                symbol: command.symbol,
                parsedInteger: currentOCRQuantity,
                isDuplicate: nil,
                isZeroOrEmpty: currentOCRQuantity == 0,
                presentationTimeSeconds: command.originatingMediaTime
            )
        }
    }

    private func transportOutcomeEvent(
        from triggerEvent: OCRPipelineEvent,
        result: OCRTradingCommandResult
    ) -> OCRPipelineEvent {
        OCRPipelineEvent(
            kind: .trigger,
            frameNumber: triggerEvent.frameNumber,
            region: triggerEvent.region,
            action: transportAction(triggerAction: triggerEvent.action, result: result),
            rawText: triggerEvent.rawText,
            normalizedText: triggerEvent.normalizedText,
            confidence: triggerEvent.confidence,
            symbol: triggerEvent.symbol,
            parsedInteger: triggerEvent.parsedInteger,
            isDuplicate: triggerEvent.isDuplicate,
            isZeroOrEmpty: triggerEvent.isZeroOrEmpty,
            presentationTimeSeconds: triggerEvent.presentationTimeSeconds
        )
    }

    private func transportAction(
        triggerAction: String,
        result: OCRTradingCommandResult
    ) -> String {
        let prefix: String
        if triggerAction.hasPrefix("buy_") {
            prefix = "buy"
        } else if triggerAction.hasPrefix("sell_") {
            prefix = "sell"
        } else if triggerAction.hasPrefix("subscribe_") {
            prefix = "subscribe"
        } else {
            prefix = "command"
        }

        switch result {
        case .submitted, .intentionallyIgnored:
            return "\(prefix)_transport_succeeded"
        case .retryableRejected, .failed, .cancelled, .staleIgnored:
            return "\(prefix)_transport_failed"
        }
    }

    private func isIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlightCommandCount == 0
    }

    private func finishInFlightCommandLocked() {
        inFlightCommandCount = max(0, inFlightCommandCount - 1)
    }
}
