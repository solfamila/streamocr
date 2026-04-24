import Foundation

struct TriggerStageTimings: Sendable {
    let frameIngressTimestamp: CFAbsoluteTime
    let regionStartTimestamp: CFAbsoluteTime
    let ocrDetectedTimestamp: CFAbsoluteTime
    let presentationTimeSeconds: Double?
    let cropMilliseconds: Double
    let metalMilliseconds: Double
    let fingerprintMilliseconds: Double
    let gatingMilliseconds: Double
    let ocrMilliseconds: Double
}

struct TriggerDispatchDecision {
    let action: String
    let shouldDispatchTrigger: Bool
}

private struct PendingBuyTransport {
    let integerValue: Int?
    let triggerEvent: OCRPipelineEvent
    let timings: TriggerStageTimings?
    let triggerEvaluationMilliseconds: Double
    let buyDecisionMilliseconds: Double
    var isStale = false

    func matches(integerValue: Int?) -> Bool {
        self.integerValue == integerValue
    }
}

private struct PendingSubscribeTransport {
    let symbol: String
    let triggerEvent: OCRPipelineEvent
    let timings: TriggerStageTimings?
    let triggerEvaluationMilliseconds: Double
    let decisionMilliseconds: Double
    var isStale = false

    func matches(symbol: String) -> Bool {
        self.symbol == symbol
    }
}

final class TriggerDispatcher: @unchecked Sendable {
    private static let latencySummarySampleCount = 10

    private let withPipelineState: (@escaping () -> Void) -> Void
    private let assertPipelineStateHeld: () -> Void
    private let loggingEnabled: Bool
    private let messageSender: any TradingMessageSending
    private let eventHandler: OCRPipelineEventHandler?
    private let triggerStateMachine: TradingTriggerStateMachine

    private var pendingBuyTransport: PendingBuyTransport?
    private var pendingSubscribeTransport: PendingSubscribeTransport?
    private var timingSamplesByEvent: [String: [TriggerPathTimingSample]] = [:]

    init(
        withPipelineState: @escaping (@escaping () -> Void) -> Void,
        assertPipelineStateHeld: @escaping () -> Void,
        loggingEnabled: Bool,
        messageSender: any TradingMessageSending,
        eventHandler: OCRPipelineEventHandler?,
        triggerStateMachine: TradingTriggerStateMachine
    ) {
        self.withPipelineState = withPipelineState
        self.assertPipelineStateHeld = assertPipelineStateHeld
        self.loggingEnabled = loggingEnabled
        self.messageSender = messageSender
        self.eventHandler = eventHandler
        self.triggerStateMachine = triggerStateMachine
    }

    /// Caller must hold the pipeline's state lock while invoking synchronous dispatcher methods.
    func reset() {
        assertPipelineStateHeld()
        pendingBuyTransport = nil
        pendingSubscribeTransport = nil
        timingSamplesByEvent.removeAll(keepingCapacity: true)
    }

    func buyDispatchDecision(for evaluation: ManualCellTriggerEvaluation) -> TriggerDispatchDecision {
        assertPipelineStateHeld()
        if evaluation.shouldTriggerBuy {
            if let pendingBuyTransport {
                if pendingBuyTransport.matches(integerValue: evaluation.integerValue) {
                    return TriggerDispatchDecision(
                        action: "transport_pending_duplicate_suppressed",
                        shouldDispatchTrigger: false
                    )
                }
                return TriggerDispatchDecision(
                    action: "transport_pending_suppressed",
                    shouldDispatchTrigger: false
                )
            }

            return TriggerDispatchDecision(action: "buy_triggered", shouldDispatchTrigger: true)
        }

        if evaluation.isZeroOrEmpty {
            return TriggerDispatchDecision(action: "armed", shouldDispatchTrigger: false)
        }

        if evaluation.isAwaitingConfirmation {
            return TriggerDispatchDecision(action: "confirmation_pending", shouldDispatchTrigger: false)
        }

        if evaluation.isDuplicate {
            return TriggerDispatchDecision(action: "duplicate_suppressed", shouldDispatchTrigger: false)
        }

        return TriggerDispatchDecision(
            action: "already_triggered_waiting_for_rearm",
            shouldDispatchTrigger: false
        )
    }

    func subscribeDispatchDecision(for evaluation: ManualSymbolTriggerEvaluation) -> TriggerDispatchDecision {
        assertPipelineStateHeld()
        if evaluation.shouldTriggerSubscribe {
            if let pendingSubscribeTransport {
                if pendingSubscribeTransport.matches(symbol: evaluation.normalizedSymbol) {
                    return TriggerDispatchDecision(
                        action: "transport_pending_duplicate_suppressed",
                        shouldDispatchTrigger: false
                    )
                }
                return TriggerDispatchDecision(
                    action: "transport_pending_suppressed",
                    shouldDispatchTrigger: false
                )
            }

            return TriggerDispatchDecision(action: "subscribe_triggered", shouldDispatchTrigger: true)
        }

        if evaluation.isDuplicate {
            return TriggerDispatchDecision(action: "duplicate_suppressed", shouldDispatchTrigger: false)
        }

        if evaluation.isChangeLocked {
            return TriggerDispatchDecision(action: "locked_waiting_for_rearm", shouldDispatchTrigger: false)
        }

        if evaluation.isAwaitingConfirmation {
            return TriggerDispatchDecision(action: "confirmation_pending", shouldDispatchTrigger: false)
        }

        return TriggerDispatchDecision(action: "symbol_empty_no_subscribe", shouldDispatchTrigger: false)
    }

    func dispatchBuy(
        triggerEvent: OCRPipelineEvent,
        integerValue: Int?,
        timings: TriggerStageTimings?,
        triggerEvaluationMilliseconds: Double,
        buyDecisionMilliseconds: Double
    ) {
        assertPipelineStateHeld()
        pendingBuyTransport = PendingBuyTransport(
            integerValue: integerValue,
            triggerEvent: triggerEvent,
            timings: timings,
            triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
            buyDecisionMilliseconds: buyDecisionMilliseconds
        )

        messageSender.send(TradingMessageContract.buyMessage(ocrQuantity: integerValue), event: "BUY") { [weak self] result in
            self?.withPipelineState { [weak self] in
                self?.handleBuyTransportResult(result)
            }
        }
    }

    func dispatchSubscribe(
        triggerEvent: OCRPipelineEvent,
        symbol: String,
        timings: TriggerStageTimings?,
        triggerEvaluationMilliseconds: Double,
        decisionMilliseconds: Double
    ) {
        assertPipelineStateHeld()
        pendingSubscribeTransport = PendingSubscribeTransport(
            symbol: symbol,
            triggerEvent: triggerEvent,
            timings: timings,
            triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
            decisionMilliseconds: decisionMilliseconds
        )
        guard let message = TradingMessageContract.subscribeMessage(symbol: symbol) else {
            handleSubscribeTransportResult(.failure(TradingMessageContractError.invalidSymbol(symbol)))
            return
        }
        messageSender.send(message, event: "SUBSCRIBE") { [weak self] result in
            self?.withPipelineState { [weak self] in
                self?.handleSubscribeTransportResult(result)
            }
        }
    }

    func invalidatePendingBuyIfNeeded(evaluation: ManualCellTriggerEvaluation) {
        assertPipelineStateHeld()
        guard var pendingBuyTransport, !pendingBuyTransport.isStale else {
            return
        }

        let didGenuinelyRearm = !evaluation.wasArmed && evaluation.isArmedAfter

        guard didGenuinelyRearm else {
            return
        }

        pendingBuyTransport.isStale = true
        self.pendingBuyTransport = pendingBuyTransport
    }

    func invalidatePendingSubscribeIfNeeded(evaluation: ManualSymbolTriggerEvaluation) {
        assertPipelineStateHeld()
        guard var pendingSubscribeTransport, !pendingSubscribeTransport.isStale else {
            return
        }

        guard
            evaluation.shouldTriggerSubscribe,
            !pendingSubscribeTransport.matches(symbol: evaluation.normalizedSymbol)
        else {
            return
        }

        pendingSubscribeTransport.isStale = true
        self.pendingSubscribeTransport = pendingSubscribeTransport
    }

    func invalidatePendingSubscribeAfterManualCellRearm(_ manualCellEvaluation: ManualCellTriggerEvaluation) {
        assertPipelineStateHeld()
        guard var pendingSubscribeTransport, !pendingSubscribeTransport.isStale else {
            return
        }

        guard !manualCellEvaluation.wasArmed, manualCellEvaluation.isArmedAfter else {
            return
        }

        pendingSubscribeTransport.isStale = true
        self.pendingSubscribeTransport = pendingSubscribeTransport
    }

    private func handleBuyTransportResult(_ result: Result<Void, any Error>) {
        assertPipelineStateHeld()
        guard let pendingBuyTransport else {
            return
        }
        self.pendingBuyTransport = nil

        if messageSender.reportsTransportOutcomes {
            let action = transportAction(
                for: result,
                success: "buy_transport_succeeded",
                failure: "buy_transport_failed"
            )
            eventHandler?(transportOutcomeEvent(from: pendingBuyTransport.triggerEvent, action: action))
        }

        if let timings = pendingBuyTransport.timings {
            let sample = timingSample(
                timings: timings,
                triggerEvaluationMilliseconds: pendingBuyTransport.triggerEvaluationMilliseconds,
                decisionMilliseconds: pendingBuyTransport.buyDecisionMilliseconds,
                sendCompletionTimestamp: CFAbsoluteTimeGetCurrent(),
                result: result
            )
            logLatency(
                frameNumber: pendingBuyTransport.triggerEvent.frameNumber,
                eventName: "BUY",
                decisionLabel: "buy_decision_ms",
                sample: sample,
                result: result
            )
        }

        if case .success = result, !pendingBuyTransport.isStale {
            triggerStateMachine.commitManualCellTriggerSuccess()
        }
    }

    private func handleSubscribeTransportResult(_ result: Result<Void, any Error>) {
        assertPipelineStateHeld()
        guard let pendingSubscribeTransport else {
            return
        }
        self.pendingSubscribeTransport = nil

        if messageSender.reportsTransportOutcomes {
            let action = transportAction(
                for: result,
                success: "subscribe_transport_succeeded",
                failure: "subscribe_transport_failed"
            )
            eventHandler?(transportOutcomeEvent(from: pendingSubscribeTransport.triggerEvent, action: action))
        }

        if let timings = pendingSubscribeTransport.timings {
            let sample = timingSample(
                timings: timings,
                triggerEvaluationMilliseconds: pendingSubscribeTransport.triggerEvaluationMilliseconds,
                decisionMilliseconds: pendingSubscribeTransport.decisionMilliseconds,
                sendCompletionTimestamp: CFAbsoluteTimeGetCurrent(),
                result: result
            )
            logLatency(
                frameNumber: pendingSubscribeTransport.triggerEvent.frameNumber,
                eventName: "SUBSCRIBE",
                decisionLabel: "subscribe_decision_ms",
                sample: sample,
                result: result
            )
        }

        if case .success = result, !pendingSubscribeTransport.isStale {
            triggerStateMachine.commitManualSymbolTriggerSuccess(symbol: pendingSubscribeTransport.symbol)
        }
    }

    private func transportOutcomeEvent(from triggerEvent: OCRPipelineEvent, action: String) -> OCRPipelineEvent {
        OCRPipelineEvent(
            kind: .trigger,
            frameNumber: triggerEvent.frameNumber,
            region: triggerEvent.region,
            action: action,
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
        for result: Result<Void, any Error>,
        success: String,
        failure: String
    ) -> String {
        switch result {
        case .success:
            success
        case .failure:
            failure
        }
    }

    private func transportResultLabel(for result: Result<Void, any Error>) -> String {
        switch result {
        case .success:
            "success"
        case .failure:
            "failure"
        }
    }

    private func transportErrorSuffix(for result: Result<Void, any Error>) -> String {
        switch result {
        case .success:
            ""
        case let .failure(error):
            " send_error=\"\(escapedForLog(error.localizedDescription))\""
        }
    }

    private func timingSample(
        timings: TriggerStageTimings,
        triggerEvaluationMilliseconds: Double,
        decisionMilliseconds: Double,
        sendCompletionTimestamp: CFAbsoluteTime,
        result: Result<Void, any Error>
    ) -> TriggerPathTimingSample {
        let frameIngressToRegionMilliseconds = max(
            0,
            (timings.regionStartTimestamp - timings.frameIngressTimestamp) * 1_000
        )
        let transportCompletionMilliseconds = max(
            0,
            (sendCompletionTimestamp - timings.frameIngressTimestamp) * 1_000
        )
        let ocrToCompletionMilliseconds = max(
            0,
            (sendCompletionTimestamp - timings.ocrDetectedTimestamp) * 1_000
        )
        let preprocessMilliseconds =
            timings.cropMilliseconds +
            timings.metalMilliseconds +
            timings.fingerprintMilliseconds +
            timings.gatingMilliseconds

        let succeeded: Bool
        switch result {
        case .success:
            succeeded = true
        case .failure:
            succeeded = false
        }

        return TriggerPathTimingSample(
            frameIngressToRegionMilliseconds: frameIngressToRegionMilliseconds,
            preprocessMilliseconds: preprocessMilliseconds,
            cropMilliseconds: timings.cropMilliseconds,
            metalMilliseconds: timings.metalMilliseconds,
            fingerprintMilliseconds: timings.fingerprintMilliseconds,
            gatingMilliseconds: timings.gatingMilliseconds,
            ocrMilliseconds: timings.ocrMilliseconds,
            triggerEvaluationMilliseconds: triggerEvaluationMilliseconds,
            decisionMilliseconds: decisionMilliseconds,
            transportCompletionMilliseconds: transportCompletionMilliseconds,
            ocrToCompletionMilliseconds: ocrToCompletionMilliseconds,
            totalEndToEndMilliseconds: transportCompletionMilliseconds,
            succeeded: succeeded
        )
    }

    private func logLatency(
        frameNumber: Int,
        eventName: String,
        decisionLabel: String,
        sample: TriggerPathTimingSample,
        result: Result<Void, any Error>
    ) {
        guard loggingEnabled else {
            return
        }

        let sendResult = transportResultLabel(for: result)
        let sendErrorSuffix = transportErrorSuffix(for: result)
        print(
            "[latency] frame=\(frameNumber) event=\(eventName) send_result=\(sendResult) " +
                "frame_ingress_to_region_ms=\(format(sample.frameIngressToRegionMilliseconds)) " +
                "preprocess_ms=\(format(sample.preprocessMilliseconds)) " +
                "crop_ms=\(format(sample.cropMilliseconds)) metal_ms=\(format(sample.metalMilliseconds)) " +
                "fingerprint_ms=\(format(sample.fingerprintMilliseconds)) " +
                "gating_ms=\(format(sample.gatingMilliseconds)) ocr_ms=\(format(sample.ocrMilliseconds)) " +
                "trigger_eval_ms=\(format(sample.triggerEvaluationMilliseconds)) " +
                "\(decisionLabel)=\(format(sample.decisionMilliseconds)) " +
                "transport_completion_ms=\(format(sample.transportCompletionMilliseconds)) " +
                "ocr_to_completion_ms=\(format(sample.ocrToCompletionMilliseconds)) " +
                "total_end_to_end_ms=\(format(sample.totalEndToEndMilliseconds))\(sendErrorSuffix)"
        )

        recordLatencySummarySample(sample, for: eventName)
    }

    private func recordLatencySummarySample(_ sample: TriggerPathTimingSample, for eventName: String) {
        var samples = timingSamplesByEvent[eventName, default: []]
        samples.append(sample)

        // Flush exactly on the configured batch size so the summary cadence stays predictable.
        guard samples.count == Self.latencySummarySampleCount else {
            timingSamplesByEvent[eventName] = samples
            return
        }

        if let summary = PipelineTimingMetrics.summarizeTriggerPathSamples(samples) {
            print(
                "[latency-summary] event=\(eventName) samples=\(summary.sampleCount) " +
                    "success=\(summary.successCount) failure=\(summary.failureCount) " +
                    "avg_frame_ingress_to_region_ms=\(format(summary.averageFrameIngressToRegionMilliseconds)) " +
                    "avg_preprocess_ms=\(format(summary.averagePreprocessMilliseconds)) " +
                    "avg_ocr_ms=\(format(summary.averageOCRMilliseconds)) " +
                    "avg_trigger_eval_ms=\(format(summary.averageTriggerEvaluationMilliseconds)) " +
                    "avg_decision_ms=\(format(summary.averageDecisionMilliseconds)) " +
                    "avg_transport_completion_ms=\(format(summary.averageTransportCompletionMilliseconds)) " +
                    "avg_ocr_to_completion_ms=\(format(summary.averageOCRToCompletionMilliseconds)) " +
                    "avg_total_end_to_end_ms=\(format(summary.averageTotalEndToEndMilliseconds)) " +
                    "max_total_end_to_end_ms=\(format(summary.maximumTotalEndToEndMilliseconds))"
            )
        }

        timingSamplesByEvent[eventName] = []
    }

    private func format(_ value: Double, precision: Int = 2) -> String {
        String(format: "%.\(precision)f", value)
    }

    private func escapedForLog(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
