import Foundation
import Testing
@testable import CaptureShellApp

struct OCRTradingCoordinatorTests {
    @Test
    func noManualTradeIsEmittedWithoutCommittedSymbol() {
        var coordinator = OCRTradingCoordinator()
        _ = coordinator.reduce(.sessionStarted(1))

        let commands = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            manualCell: manualCell("10000")
        )))

        #expect(commands.isEmpty)
        #expect(coordinator.state.pendingCommands.isEmpty)
    }

    @Test
    func missingSymbolConfigurationClearsStableSymbolAndSuppressesManualTrades() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 10)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(subscribe.id, .submitted))
        #expect(coordinator.state.symbol.stableSymbol == "PLRZ")

        let commands = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: OCRTradingSymbolObservation(recognitionState: .notConfigured),
            manualCell: manualCell("10000")
        )))

        #expect(commands.isEmpty)
        #expect(coordinator.state.symbol.stableSymbol == nil)
    }

    @Test
    func fingerprintChangeSuppressesManualTradesUntilSymbolSubscribeCommits() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let initialSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 100)
        ))).first)
        #expect(initialSubscribe.kind == .subscribe)
        _ = coordinator.reduce(.commandCompleted(initialSubscribe.id, .submitted))
        #expect(coordinator.state.symbol.stableSymbol == "SPY")

        let suppressedDuringUncertainty = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 200,
                recognitionState: .changedFingerprintPendingOCR
            ),
            manualCell: manualCell("10000")
        )))
        #expect(suppressedDuringUncertainty.isEmpty)
        #expect(!coordinator.state.symbol.isStable)

        let nexrSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: symbol("NEXR", fingerprint: 200),
            manualCell: manualCell("10000")
        ))).first)
        #expect(nexrSubscribe.kind == .subscribe)
        #expect(nexrSubscribe.symbol == "NEXR")

        let suppressedWhileSubscribing = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 4,
            manualCell: manualCell("10000")
        )))
        #expect(suppressedWhileSubscribing.isEmpty)

        _ = coordinator.reduce(.commandCompleted(nexrSubscribe.id, .submitted))
        let buyCommands = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 5,
            manualCell: manualCell("10000")
        )))

        #expect(buyCommands.count == 1)
        #expect(buyCommands.first?.kind == .buy(ocrQuantity: 10000, submittedQuantity: 10000))
        #expect(buyCommands.first?.symbol == "NEXR")
        #expect(buyCommands.first?.symbolGeneration == nexrSubscribe.symbolGeneration)
    }

    @Test
    func fingerprintChangeCancelsPendingSubscribeBeforeItCanCommit() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let spySubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(spySubscribe.id, .submitted))

        let nexrSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: symbol("NEXR", fingerprint: 20)
        ))).first)

        let uncertainty = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 30,
                recognitionState: .changedFingerprintPendingOCR
            )
        )))

        #expect(uncertainty.commandIDsToCancel == [nexrSubscribe.id])
        #expect(coordinator.state.terminalResults[nexrSubscribe.id] == .cancelled(reason: "Symbol changed before subscribe completed."))
        #expect(coordinator.state.symbol == .uncertain(
            previous: previousWorld("SPY", generation: 1, fingerprint: 10),
            reason: .fingerprintChanged
        ))

        _ = coordinator.reduce(.commandCompleted(nexrSubscribe.id, .submitted))
        #expect(coordinator.state.symbol == .uncertain(
            previous: previousWorld("SPY", generation: 1, fingerprint: 10),
            reason: .fingerprintChanged
        ))
        #expect(coordinator.state.terminalResults[nexrSubscribe.id] == .cancelled(reason: "Symbol changed before subscribe completed."))

        let waiSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 4,
            symbol: symbol("WAI", fingerprint: 30)
        ))).first)
        #expect(waiSubscribe.kind == .subscribe)
        #expect(waiSubscribe.symbol == "WAI")
    }

    @Test
    func returningPreviousSymbolCancelsPendingSubscribeAndRestoresPreviousGenerationAndPeak() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let spySubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(spySubscribe.id, .submitted))

        let spyBuy = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))).first)
        _ = coordinator.reduce(.commandCompleted(spyBuy.id, .submitted))
        _ = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            manualCell: manualCell("30000")
        )))
        #expect(coordinator.state.manual.openPositionPeakValue == 30000)

        let nexrSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 4,
            symbol: symbol("NEXR", fingerprint: 20)
        ))).first)
        #expect(nexrSubscribe.symbol == "NEXR")
        #expect(nexrSubscribe.symbolGeneration == 2)

        let restoredPrevious = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 5,
            symbol: symbol("SPY", fingerprint: 10)
        )))

        #expect(restoredPrevious.isEmpty)
        #expect(restoredPrevious.commandIDsToCancel == [nexrSubscribe.id])
        #expect(coordinator.state.symbol == .stable(symbol: "SPY", generation: 1, fingerprint: 10))
        #expect(coordinator.state.manual.symbolGeneration == 1)
        #expect(coordinator.state.manual.openPositionPeakValue == 30000)

        _ = coordinator.reduce(.commandCompleted(nexrSubscribe.id, .submitted))
        #expect(coordinator.state.symbol == .stable(symbol: "SPY", generation: 1, fingerprint: 10))
        #expect(coordinator.state.terminalResults[nexrSubscribe.id] == .cancelled(reason: "Symbol changed before subscribe completed."))

        let sell = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 6,
            manualCell: manualCell("25000")
        ))).first)
        #expect(sell.symbol == "SPY")
        #expect(sell.symbolGeneration == 1)
        #expect(sell.kind == .sell(previousOCRQuantity: 30000, currentOCRQuantity: 25000))
    }

    @Test
    func recognizedDifferentSymbolCancelsPendingSubscribeAndStartsReplacement() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let spySubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(spySubscribe.id, .submitted))

        let nexrSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: symbol("NEXR", fingerprint: 20)
        ))).first)

        let replacement = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: symbol("WAI", fingerprint: 30)
        )))

        #expect(replacement.commandIDsToCancel == [nexrSubscribe.id])
        let waiSubscribe = try #require(replacement.first)
        #expect(waiSubscribe.kind == .subscribe)
        #expect(waiSubscribe.symbol == "WAI")
        #expect(coordinator.state.terminalResults[nexrSubscribe.id] == .cancelled(reason: "Symbol changed before subscribe completed."))
    }

    @Test
    func repeatedLowConfidenceAlternateSymbolCanSubscribeAfterExtraConfirmations() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let initialSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 100)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(initialSubscribe.id, .submitted))

        let suppressedDuringUncertainty = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 200,
                recognitionState: .changedFingerprintPendingOCR
            )
        )))
        #expect(suppressedDuringUncertainty.isEmpty)

        let lowConfidenceAlternate = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: symbol("PLPZ", fingerprint: 200, confidence: 0.77),
            manualCell: manualCell("10000")
        )))

        #expect(lowConfidenceAlternate.isEmpty)
        #expect(coordinator.state.symbol == .candidate(
            symbol: "PLPZ",
            confirmations: 1,
            required: 4,
            previous: previousWorld("PLRZ", generation: 1, fingerprint: 100),
            fingerprint: 200
        ))

        for frameNumber in 4...5 {
            let confirmation = coordinator.reduce(.frame(OCRTradingFrameObservation(
                frameNumber: frameNumber,
                symbol: symbol("PLPZ", fingerprint: 200, confidence: 0.77)
            )))
            #expect(confirmation.isEmpty)
        }

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 6,
            symbol: symbol("PLPZ", fingerprint: 200, confidence: 0.77)
        ))).first)
        #expect(subscribe.kind == .subscribe)
        #expect(subscribe.symbol == "PLPZ")
    }

    @Test
    func previousSymbolRecoveryDuringCandidateRestoresStableWorld() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let initialSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 100)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(initialSubscribe.id, .submitted))

        _ = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 200,
                recognitionState: .changedFingerprintPendingOCR
            )
        )))
        _ = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: symbol("PLPZ", fingerprint: 200, confidence: 0.77),
            manualCell: manualCell("10000")
        )))

        let previousSymbolRecovered = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 4,
            symbol: symbol("PLRZ", fingerprint: 201, confidence: 0.79),
            manualCell: manualCell("10000")
        )))

        #expect(previousSymbolRecovered.isEmpty)
        #expect(coordinator.state.symbol.stableSymbol == "PLRZ")
    }

    @Test
    func subscribeCompletionDoesNotAllowManualTradeInOriginatingFrame() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 100)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(subscribe.id, .submitted))

        let sameFrameManualCommands = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            manualCell: manualCell("10000")
        )))
        #expect(sameFrameManualCommands.isEmpty)

        let nextFrameManualCommands = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        )))
        #expect(nextFrameManualCommands.count == 1)
        #expect(nextFrameManualCommands.first?.kind == .buy(ocrQuantity: 10000, submittedQuantity: 10000))
    }

    @Test
    func symbolGenerationChangeClearsManualPeakSoNewSymbolDoesNotSellOldPosition() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let spySubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(spySubscribe.id, .submitted))

        let spyBuy = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))).first)
        _ = coordinator.reduce(.commandCompleted(spyBuy.id, .submitted))
        _ = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            manualCell: manualCell("30000")
        )))
        #expect(coordinator.state.manual.openPositionPeakValue == 30000)

        _ = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 4,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 20,
                recognitionState: .changedFingerprintPendingOCR
            )
        )))
        let nexrSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 5,
            symbol: symbol("NEXR", fingerprint: 20)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(nexrSubscribe.id, .submitted))

        #expect(coordinator.state.manual.openPositionPeakValue == nil)
        #expect(coordinator.state.manual.isArmed)

        let newSymbolCommand = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 6,
            manualCell: manualCell("25000")
        ))).first)

        #expect(newSymbolCommand.kind == .buy(ocrQuantity: 25000, submittedQuantity: 25000))
        #expect(newSymbolCommand.symbol == "NEXR")
    }

    @Test
    func staleBuyCompletionCannotMutateManualStateAfterSymbolGenerationChanges() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let spySubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("SPY", fingerprint: 10)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(spySubscribe.id, .submitted))

        let staleBuy = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))).first)

        let symbolUncertaintyEffects = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: OCRTradingSymbolObservation(
                fingerprint: 20,
                recognitionState: .changedFingerprintPendingOCR
            )
        )))
        #expect(symbolUncertaintyEffects.commandIDsToCancel == [staleBuy.id])
        let nexrSubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 4,
            symbol: symbol("NEXR", fingerprint: 20)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(nexrSubscribe.id, .submitted))
        _ = coordinator.reduce(.commandCompleted(staleBuy.id, .submitted))

        #expect(coordinator.state.terminalResults[staleBuy.id] == .cancelled(reason: "Symbol became uncertain."))
        #expect(coordinator.state.manual.openPositionPeakValue == nil)
        #expect(coordinator.state.manual.isArmed)
    }

    @Test
    func retryableBuyFailureSuppressesRepeatBuyUntilCooldownExpires() throws {
        let clock = TestClock(now: 100)
        var coordinator = OCRTradingCoordinator(
            manualSymbolTriggerConfirmationFrames: 1,
            retryableCommandCooldownSeconds: 1.0,
            timeProvider: { clock.now }
        )
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 42)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(subscribe.id, .submitted))

        let buy = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))).first)
        _ = coordinator.reduce(.commandCompleted(buy.id, .retryableRejected(reason: "Waiting for a fresh quote.")))

        let suppressedRetry = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            manualCell: manualCell("10000")
        )))
        #expect(suppressedRetry.isEmpty)

        clock.advance(by: 1.1)
        let retriedBuy = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 4,
            manualCell: manualCell("10000")
        ))).first)

        #expect(retriedBuy.id != buy.id)
        #expect(retriedBuy.kind == .buy(ocrQuantity: 10000, submittedQuantity: 10000))
    }

    @Test
    func retryableSellFailureSurvivesZeroLikeBuyRearm() throws {
        let clock = TestClock(now: 100)
        var coordinator = OCRTradingCoordinator(
            manualCellRearmConfirmationFrames: 3,
            manualSymbolTriggerConfirmationFrames: 1,
            retryableCommandCooldownSeconds: 1.0,
            timeProvider: { clock.now }
        )
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 42)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(subscribe.id, .submitted))

        let buy = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))).first)
        _ = coordinator.reduce(.commandCompleted(buy.id, .submitted))

        let sell = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            manualCell: manualCell("0")
        ))).first)
        #expect(sell.kind == .sell(previousOCRQuantity: 10000, currentOCRQuantity: 0))
        _ = coordinator.reduce(.commandCompleted(sell.id, .retryableRejected(reason: "Close is not currently available.")))

        #expect(coordinator.state.manual.openPositionPeakValue == 10000)

        let coolingDownAfterZeroRearm = [
            coordinator.reduce(.frame(OCRTradingFrameObservation(frameNumber: 4, manualCell: manualCell("0")))),
            coordinator.reduce(.frame(OCRTradingFrameObservation(frameNumber: 5, manualCell: manualCell("0")))),
            coordinator.reduce(.frame(OCRTradingFrameObservation(frameNumber: 6, manualCell: manualCell("0"))))
        ]
        #expect(coolingDownAfterZeroRearm[0].isEmpty)
        #expect(coolingDownAfterZeroRearm[1].isEmpty)
        #expect(coolingDownAfterZeroRearm[2].isEmpty)
        #expect(coordinator.state.manual.isArmed)
        #expect(coordinator.state.manual.openPositionPeakValue == 10000)

        let unresolvedOpenPositionDoesNotBuyAgain = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 7,
            manualCell: manualCell("12000")
        )))
        #expect(unresolvedOpenPositionDoesNotBuyAgain.isEmpty)
        #expect(coordinator.state.manual.openPositionPeakValue == 12000)

        clock.advance(by: 1.1)
        let retriedSell = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 8,
            manualCell: manualCell("0")
        ))).first)

        #expect(retriedSell.id != sell.id)
        #expect(retriedSell.kind == .sell(previousOCRQuantity: 12000, currentOCRQuantity: 0))
    }

    @Test
    func sessionGenerationChangeCancelsPendingCommands() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 42)
        ))).first)

        _ = coordinator.reduce(.sessionStarted(2))

        #expect(coordinator.state.pendingCommands.isEmpty)
        #expect(coordinator.state.terminalResults[subscribe.id] == .cancelled(reason: "OCR trading session generation changed."))
        #expect(coordinator.state.sessionGeneration == 2)
        #expect(coordinator.state.symbol == .unknown)
    }

    @Test
    func retryableSubscribeFailureLeavesSymbolUncertainAndRetryable() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 42)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(subscribe.id, .retryableRejected(reason: "TWS not ready")))

        #expect(coordinator.state.symbol == .uncertain(previous: nil, reason: .ocrPending))

        let suppressedManual = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        )))
        #expect(suppressedManual.isEmpty)

        let retrySubscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            symbol: symbol("PLRZ", fingerprint: 42)
        ))).first)
        #expect(retrySubscribe.kind == .subscribe)
        #expect(retrySubscribe.id != subscribe.id)
    }

    @Test
    func intentionallyIgnoredBuyDoesNotCreateOpenManualPosition() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 42)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(subscribe.id, .submitted))

        let buy = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("10000")
        ))).first)
        _ = coordinator.reduce(.commandCompleted(buy.id, .intentionallyIgnored(reason: "controller disarmed")))

        #expect(!coordinator.state.manual.isArmed)
        #expect(coordinator.state.manual.openPositionPeakValue == nil)

        let noSellFromIgnoredBuy = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 3,
            manualCell: manualCell("9000")
        )))
        #expect(noSellFromIgnoredBuy.isEmpty)
    }

    @Test
    func sellRequiresOpenPositionForSameStableSymbolGeneration() throws {
        var coordinator = OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1)
        _ = coordinator.reduce(.sessionStarted(1))

        let subscribe = try #require(coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 1,
            symbol: symbol("PLRZ", fingerprint: 42)
        ))).first)
        _ = coordinator.reduce(.commandCompleted(subscribe.id, .submitted))

        let sellWithoutOpenPosition = coordinator.reduce(.frame(OCRTradingFrameObservation(
            frameNumber: 2,
            manualCell: manualCell("5000")
        )))

        #expect(sellWithoutOpenPosition.first?.kind == .buy(ocrQuantity: 5000, submittedQuantity: 5000))
        _ = coordinator.reduce(.commandCompleted(sellWithoutOpenPosition[0].id, .retryableRejected(reason: "not ready")))
        #expect(coordinator.state.manual.openPositionPeakValue == nil)
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

    private func previousWorld(
        _ symbol: String,
        generation: OCRTradingSymbolGeneration,
        fingerprint: UInt64?
    ) -> OCRTradingPreviousSymbolWorld {
        OCRTradingPreviousSymbolWorld(
            symbol: symbol,
            generation: generation,
            fingerprint: fingerprint
        )
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double

        init(now: Double) {
            value = now
        }

        var now: Double {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(by delta: Double) {
            lock.lock()
            value += delta
            lock.unlock()
        }
    }
}
