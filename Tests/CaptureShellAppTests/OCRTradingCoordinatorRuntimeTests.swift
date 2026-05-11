import Foundation
import Testing
@testable import CaptureShellApp

struct OCRTradingCoordinatorRuntimeTests {
    @Test
    func runtimeExecutesSubscribeThenBuyFromFrameObservations() {
        let executor = RuntimeControllableExecutor()
        let events = RuntimeEventCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            eventHandler: events.handle(_:)
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            mediaTime: 1,
            symbol: symbol("PLRZ", fingerprint: 10)
        ))
        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.submitted)
        waitUntil { runtime.stateSnapshot.symbol.stableSymbol == "PLRZ" }

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 2,
            mediaTime: 2,
            manualCell: manualCell("10000")
        ))
        waitUntil { executor.pendingCommands.count == 2 }
        executor.completeNext(.submitted)
        waitUntil { runtime.stateSnapshot.manual.openPositionPeakValue == 10000 }

        #expect(executor.pendingCommands.map(\.kind) == [
            .subscribe,
            .buy(ocrQuantity: 10000, submittedQuantity: 10000)
        ])
        #expect(events.actions == ["subscribe_triggered", "buy_triggered"])
        #expect(events.events.map(\.symbol) == ["PLRZ", "PLRZ"])
    }

    @Test
    func runtimeSuppressesManualCommandsOnSymbolFingerprintChangeUntilSubscribeCompletes() {
        let executor = RuntimeControllableExecutor()
        let events = RuntimeEventCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            eventHandler: events.handle(_:)
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))
        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.submitted)
        waitUntil { runtime.stateSnapshot.symbol.stableSymbol == "SPY" }

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 20,
                recognitionState: .changedFingerprintPendingOCR
            ),
            manualCell: manualCell("10000")
        ))

        #expect(executor.pendingCommands.count == 1)
        #expect(runtime.stateSnapshot.symbol.stableSymbol == nil)

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: symbol("NEXR", fingerprint: 20),
            manualCell: manualCell("10000")
        ))

        waitUntil { executor.pendingCommands.count == 2 }
        #expect(executor.pendingCommands.map(\.kind) == [.subscribe, .subscribe])
        #expect(events.actions == ["subscribe_triggered", "subscribe_triggered"])
        #expect(events.events.map(\.symbol) == ["SPY", "NEXR"])

        executor.completeNext(.submitted)
        waitUntil { runtime.stateSnapshot.symbol.stableSymbol == "NEXR" }

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 4,
            manualCell: manualCell("10000")
        ))
        waitUntil { executor.pendingCommands.count == 3 }
        #expect(executor.pendingCommands.last?.kind == .buy(ocrQuantity: 10000, submittedQuantity: 10000))
        #expect(executor.pendingCommands.last?.symbol == "NEXR")
    }

    @Test
    func runtimeCancelsPendingSubscribeWhenSymbolChangesBeforeCompletion() {
        let executor = RuntimeControllableExecutor()
        let events = RuntimeEventCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            eventHandler: events.handle(_:)
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))
        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.submitted)
        waitUntil { runtime.stateSnapshot.symbol.stableSymbol == "SPY" }

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: symbol("NEXR", fingerprint: 20)
        ))
        waitUntil { executor.pendingCommands.count == 2 }
        let nexrSubscribeID = executor.pendingCommands[1].id

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: symbol("WAI", fingerprint: 30)
        ))

        waitUntil {
            executor.cancelledCommandIDs.contains(nexrSubscribeID) &&
                executor.pendingCommands.count == 3
        }
        #expect(executor.pendingCommands.map(\.symbol) == ["SPY", "NEXR", "WAI"])
        #expect(executor.pendingCommands.last?.kind == .subscribe)
        #expect(runtime.stateSnapshot.terminalResults[nexrSubscribeID] == .cancelled(reason: "Symbol changed before subscribe completed."))
        #expect(events.events.map(\.symbol) == ["SPY", "NEXR", "WAI"])
    }

    @Test
    func runtimeCancelsPendingManualCommandWhenSymbolBecomesUncertain() {
        let executor = RuntimeControllableExecutor()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))
        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.submitted)
        waitUntil { runtime.stateSnapshot.symbol.stableSymbol == "SPY" }

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))
        waitUntil { executor.pendingCommands.count == 2 }
        let buyID = executor.pendingCommands[1].id

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 20,
                recognitionState: .changedFingerprintPendingOCR
            )
        ))

        waitUntil { executor.cancelledCommandIDs.contains(buyID) }
        waitUntil { runtime.waitForPendingCommands(timeout: 0) }
        #expect(runtime.stateSnapshot.terminalResults[buyID] == .cancelled(reason: "Symbol became uncertain."))
    }

    @Test
    func runtimeCanEmitTransportOutcomeEvents() {
        let executor = RuntimeControllableExecutor()
        let events = RuntimeEventCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            eventHandler: events.handle(_:),
            emitsTransportOutcomes: true
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 10)
        ))
        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.retryableRejected(reason: "TWS not ready"))
        waitUntil { events.actions.contains("subscribe_transport_failed") }

        #expect(events.actions == ["subscribe_triggered", "subscribe_transport_failed"])
    }

    @Test
    func intentionallyIgnoredCommandEmitsTruthfulOutcomeEvent() {
        let executor = RuntimeControllableExecutor()
        let events = RuntimeEventCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            eventHandler: events.handle(_:),
            emitsTransportOutcomes: true
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 10)
        ))
        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.submitted)
        waitUntil { events.actions.contains("subscribe_transport_succeeded") }

        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))
        waitUntil { executor.pendingCommands.count == 2 }
        executor.completeNext(.intentionallyIgnored(reason: "Controller trading is not armed."))
        waitUntil { events.actions.contains("buy_intentionally_ignored") }

        #expect(events.actions == [
            "subscribe_triggered",
            "subscribe_transport_succeeded",
            "buy_triggered",
            "buy_intentionally_ignored"
        ])
    }

    @Test
    func waitForPendingCommandsWaitsForRuntimeCompletion() {
        let executor = RuntimeControllableExecutor()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 10)
        ))

        waitUntil { executor.pendingCommands.count == 1 }
        #expect(!runtime.waitForPendingCommands(timeout: 0.03))

        executor.completeNext(.submitted)
        waitUntil { runtime.stateSnapshot.symbol.stableSymbol == "PLRZ" }
        #expect(runtime.waitForPendingCommands(timeout: 0.5))
    }

    @Test
    func waitForPendingCommandsWaitsForTransportOutcomeHandler() {
        let executor = RuntimeControllableExecutor()
        let events = RuntimeEventCapture(blockingAction: "subscribe_transport_succeeded")
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            eventHandler: events.handle(_:),
            emitsTransportOutcomes: true
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 10)
        ))

        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.submitted)
        #expect(events.waitForBlockedEvent(timeout: 1.0))
        #expect(!runtime.waitForPendingCommands(timeout: 0.03))

        events.unblock()
        waitUntil { events.actions.contains("subscribe_transport_succeeded") }
        #expect(runtime.waitForPendingCommands(timeout: 0.5))
    }

    @Test
    func runtimeEmitsTypedCommandAuditEvents() {
        let executor = RuntimeControllableExecutor()
        let audits = RuntimeCommandAuditCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            commandAuditHandler: audits.handle(_:)
        )

        runtime.beginSession(9)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 41,
            mediaTime: 12.5,
            symbol: symbol("ODYS", fingerprint: 10)
        ))

        waitUntil { executor.pendingCommands.count == 1 }
        executor.completeNext(.submitted)
        waitUntil { audits.events.count == 2 }

        #expect(audits.events.map(\.phase) == [.started, .completed])
        #expect(audits.events.map(\.command.id) == [1, 1])
        #expect(audits.events.first?.command.symbol == "ODYS")
        #expect(audits.events.first?.command.symbolGeneration == 1)
        #expect(audits.events.first?.command.sessionGeneration == 9)
        #expect(audits.events.first?.command.originatingFrame == 41)
        #expect(audits.events.last?.result == .submitted)
        #expect(audits.events.last?.coordinatorResult == .submitted)
    }

    @Test
    func stopMarksPendingCommandsStaleBeforeExecutorCallbacksCanComplete() {
        let executor = RuntimeControllableExecutor()
        executor.resultOnCancel = .submitted
        let audits = RuntimeCommandAuditCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            commandAuditHandler: audits.handle(_:)
        )

        runtime.beginSession(1)
        runtime.handle(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 10)
        ))
        waitUntil { executor.pendingCommands.count == 1 }

        runtime.stop(reason: "test stop")
        waitUntil { runtime.waitForPendingCommands(timeout: 0) }

        #expect(runtime.stateSnapshot.symbol.stableSymbol == nil)
        #expect(runtime.stateSnapshot.terminalResults[1] == .cancelled(reason: "test stop"))

        let phases = audits.events.map(\.phase)
        #expect(phases == [.started, .cancellationRequested, .completed])
        #expect(audits.events[1].result == .cancelled(reason: "test stop"))
        #expect(audits.events[1].coordinatorResult == .cancelled(reason: "test stop"))
        #expect(audits.events[2].result == .submitted)
        #expect(audits.events[2].coordinatorResult == .cancelled(reason: "test stop"))
    }

    private func symbol(
        _ text: String,
        fingerprint: UInt64,
        confidence: Double = 0.9
    ) -> OCRTradingSymbolObservation {
        OCRTradingSymbolObservation(
            fingerprint: fingerprint,
            recognition: OCRTradingTextObservation(
                rawText: text,
                normalizedText: text,
                confidence: confidence
            ),
            recognitionState: .recognized
        )
    }

    private func manualCell(
        _ text: String,
        confidence: Double = 0.9
    ) -> OCRTradingManualCellObservation {
        OCRTradingManualCellObservation(
            rawText: text,
            normalizedText: text,
            confidence: confidence
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(condition())
    }

    private final class RuntimeEventCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let blockingAction: String?
        private let blockedEventSemaphore = DispatchSemaphore(value: 0)
        private let unblockSemaphore = DispatchSemaphore(value: 0)
        private(set) var events: [OCRPipelineEvent] = []

        init(blockingAction: String? = nil) {
            self.blockingAction = blockingAction
        }

        var actions: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events.map(\.action)
        }

        func handle(_ event: OCRPipelineEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
            guard event.action == blockingAction else {
                return
            }
            blockedEventSemaphore.signal()
            unblockSemaphore.wait()
        }

        func waitForBlockedEvent(timeout: TimeInterval) -> Bool {
            blockedEventSemaphore.wait(timeout: .now() + timeout) == .success
        }

        func unblock() {
            unblockSemaphore.signal()
        }
    }

    private final class RuntimeCommandAuditCapture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [OCRTradingCommandAuditEvent] = []

        func handle(_ event: OCRTradingCommandAuditEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
    }

    private final class RuntimeControllableExecutor: OCRTradingCommandExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var continuationsByCommandID: [OCRTradingCommandID: CheckedContinuation<OCRTradingCommandResult, Never>] = [:]
        private var cancellationReasonsByCommandID: [OCRTradingCommandID: String] = [:]
        private(set) var pendingCommands: [OCRTradingCommand] = []
        private(set) var cancelledCommandIDs: [OCRTradingCommandID] = []
        var resultOnCancel: OCRTradingCommandResult?

        func execute(_ command: OCRTradingCommand) async -> OCRTradingCommandResult {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let reason = cancellationReasonsByCommandID[command.id] {
                    lock.unlock()
                    continuation.resume(returning: .cancelled(reason: reason))
                    return
                }
                pendingCommands.append(command)
                continuationsByCommandID[command.id] = continuation
                lock.unlock()
            }
        }

        func completeNext(_ result: OCRTradingCommandResult) {
            let continuation: CheckedContinuation<OCRTradingCommandResult, Never>?
            lock.lock()
            let id = pendingCommands
                .map(\.id)
                .first { continuationsByCommandID[$0] != nil }
            continuation = id.flatMap { continuationsByCommandID.removeValue(forKey: $0) }
            lock.unlock()
            continuation?.resume(returning: result)
        }

        func cancelPendingCommand(id: OCRTradingCommandID, reason: String) {
            let continuation: CheckedContinuation<OCRTradingCommandResult, Never>?
            let result: OCRTradingCommandResult
            lock.lock()
            cancellationReasonsByCommandID[id] = reason
            cancelledCommandIDs.append(id)
            continuation = continuationsByCommandID.removeValue(forKey: id)
            result = resultOnCancel ?? .cancelled(reason: reason)
            lock.unlock()
            continuation?.resume(returning: result)
        }

        func cancelPendingCommands(reason _: String) {
            let continuationsToResume: [CheckedContinuation<OCRTradingCommandResult, Never>]
            lock.lock()
            continuationsToResume = Array(continuationsByCommandID.values)
            continuationsByCommandID.removeAll()
            lock.unlock()
            guard let resultOnCancel else {
                return
            }
            for continuation in continuationsToResume {
                continuation.resume(returning: resultOnCancel)
            }
        }
    }
}
