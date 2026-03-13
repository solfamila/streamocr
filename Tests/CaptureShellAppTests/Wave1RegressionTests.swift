import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CaptureShellApp

struct TradingWebSocketContractTests {
    @Test
    func buyMessageMatchesContract() {
        #expect(TradingWebSocketContract.buyMessage == #"{"action":"BUY"}"#)
    }

    @Test
    func subscribeMessageTrimsAndUppercasesSymbol() {
        #expect(
            TradingWebSocketContract.subscribeMessage(symbol: "  msft\n") == #"{"subscribe":"MSFT"}"#
        )
    }

    @Test
    func subscribeMessageKeepsLettersOnly() {
        #expect(
            TradingWebSocketContract.subscribeMessage(symbol: " m s-f.t 1 ") == #"{"subscribe":"MSFT"}"#
        )
    }
}

struct FrameTimingPolicyTests {
    @Test
    func deltaMillisecondsIsZeroWhenNoPreviousPTS() {
        let currentPTS = CMTime(value: 90, timescale: 60)
        #expect(FrameTimingPolicy.deltaMilliseconds(currentPTS: currentPTS, previousPTS: nil) == 0)
    }

    @Test
    func deltaMillisecondsCalculatesFromPTSDelta() {
        let previousPTS = CMTime(value: 120, timescale: 60)
        let currentPTS = CMTime(value: 123, timescale: 60)
        let delta = FrameTimingPolicy.deltaMilliseconds(currentPTS: currentPTS, previousPTS: previousPTS)

        #expect(abs(delta - 50) < 0.001)
    }

    @Test
    func deltaMillisecondsClampsNegativeDeltaToZero() {
        let previousPTS = CMTime(value: 123, timescale: 60)
        let currentPTS = CMTime(value: 120, timescale: 60)

        #expect(FrameTimingPolicy.deltaMilliseconds(currentPTS: currentPTS, previousPTS: previousPTS) == 0)
    }

    @Test
    func shouldLogMatchesFrameCadence() {
        #expect(FrameTimingPolicy.shouldLog(frameCount: 1))
        #expect(!FrameTimingPolicy.shouldLog(frameCount: 2))
        #expect(!FrameTimingPolicy.shouldLog(frameCount: 29))
        #expect(FrameTimingPolicy.shouldLog(frameCount: 30))
        #expect(FrameTimingPolicy.shouldLog(frameCount: 60))
    }
}

struct OCRNormalizationPolicyTests {
    @Test
    func manualCellNormalizationCollapsesWhitespaceAndRemovesSpaces() {
        let normalized = OCRNormalizationPolicy.normalize("  12  34\n", for: .manualCell)
        #expect(normalized == "1234")
    }

    @Test
    func manualSymbolNormalizationUppercasesAndTrims() {
        let normalized = OCRNormalizationPolicy.normalize("  ms ft \n", for: .manualSymbolCell)
        #expect(normalized == "MS FT")
    }
}

struct TradingTriggerStateMachineTests {
    @Test
    func manualCellFiresOnlyOnceUntilRearmed() {
        let stateMachine = TradingTriggerStateMachine()

        let first = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(!first.shouldSendBuy)
        #expect(first.isArmedAfter)

        let second = stateMachine.evaluateManualCell(normalizedText: "0")
        #expect(!second.shouldSendBuy)
        #expect(second.isArmedAfter)

        let third = stateMachine.evaluateManualCell(normalizedText: "42")
        #expect(third.shouldSendBuy)
        #expect(!third.isArmedAfter)

        let fourth = stateMachine.evaluateManualCell(normalizedText: "42")
        #expect(!fourth.shouldSendBuy)
        #expect(fourth.isDuplicate)
        #expect(!fourth.isArmedAfter)

        let fifth = stateMachine.evaluateManualCell(normalizedText: "99")
        #expect(!fifth.shouldSendBuy)
        #expect(!fifth.isArmedAfter)

        let sixth = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(!sixth.shouldSendBuy)
        #expect(sixth.isArmedAfter)

        let seventh = stateMachine.evaluateManualCell(normalizedText: "7")
        #expect(seventh.shouldSendBuy)
        #expect(!seventh.isArmedAfter)
    }

    @Test
    func manualCellTreatsNonIntegerAsEmptyForArming() {
        let stateMachine = TradingTriggerStateMachine()

        _ = stateMachine.evaluateManualCell(normalizedText: "11")
        let nonInteger = stateMachine.evaluateManualCell(normalizedText: "ABCD")
        #expect(nonInteger.isZeroOrEmpty)
        #expect(nonInteger.isArmedAfter)

        let retrigger = stateMachine.evaluateManualCell(normalizedText: "5")
        #expect(retrigger.shouldSendBuy)
    }

    @Test
    func manualSymbolSubscribesOnlyWhenNormalizedSymbolChanges() {
        let stateMachine = TradingTriggerStateMachine()

        let first = stateMachine.evaluateManualSymbol(normalizedText: "ms ft")
        #expect(first.shouldSendSubscribe)
        #expect(first.normalizedSymbol == "MSFT")

        let second = stateMachine.evaluateManualSymbol(normalizedText: "m.s-f t")
        #expect(!second.shouldSendSubscribe)
        #expect(second.isDuplicate)
        #expect(second.normalizedSymbol == "MSFT")

        let third = stateMachine.evaluateManualSymbol(normalizedText: "aapl")
        #expect(third.shouldSendSubscribe)
        #expect(third.normalizedSymbol == "AAPL")

        let fourth = stateMachine.evaluateManualSymbol(normalizedText: "")
        #expect(!fourth.shouldSendSubscribe)
        #expect(fourth.normalizedSymbol.isEmpty)
        #expect(!fourth.isDuplicate)
    }
}

struct TriggerPipelineVerificationHarnessTests {
    @Test
    func manualCellTransitionsEmitSingleBuyUntilRearm() {
        let sender = CapturingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(messageSender: sender, beep: {})

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "0", normalizedText: "0", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "16", normalizedText: "16", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "16", normalizedText: "16", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "9", normalizedText: "9", confidence: 0.9)

        #expect(
            sender.messages == [
                TradingWebSocketContract.buyMessage,
                TradingWebSocketContract.buyMessage
            ]
        )
    }

    @Test
    func manualSymbolTransitionsEmitSubscribeOnlyOnChange() {
        let sender = CapturingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(messageSender: sender, beep: {})

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "ms ft",
            normalizedText: "MS FT",
            confidence: 0.8
        )
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "m.s-f t",
            normalizedText: "M.S-F T",
            confidence: 0.8
        )
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "aapl",
            normalizedText: "AAPL",
            confidence: 0.8
        )

        #expect(
            sender.messages == [
                #"{"subscribe":"MSFT"}"#,
                #"{"subscribe":"AAPL"}"#
            ]
        )
    }

    private final class CapturingMessageSender: TradingMessageSending, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var messages: [String] = []

        func send(_ payload: String, event _: String) {
            lock.lock()
            messages.append(payload)
            lock.unlock()
        }
    }
}

struct OCRFingerprintPolicyTests {
    @Test
    func fingerprintIsStableForSamePixelBuffer() {
        let pixelBuffer = makePixelBuffer(fillValue: 42)
        let first = OCRFingerprintPolicy.fingerprint(pixelBuffer: pixelBuffer)
        let second = OCRFingerprintPolicy.fingerprint(pixelBuffer: pixelBuffer)

        #expect(first == second)
    }

    @Test
    func fingerprintChangesWhenPixelContentChanges() {
        let pixelBuffer = makePixelBuffer(fillValue: 90)
        let first = OCRFingerprintPolicy.fingerprint(pixelBuffer: pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress?.assumingMemoryBound(to: UInt8.self)
        pointer?[bytesPerRow + 8] = 11
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let second = OCRFingerprintPolicy.fingerprint(pixelBuffer: pixelBuffer)
        #expect(first != second)
    }

    private func makePixelBuffer(fillValue: UInt8) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        #expect(status == kCVReturnSuccess)
        guard let pixelBuffer else {
            fatalError("Failed to allocate test pixel buffer.")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = pointer.advanced(by: y * bytesPerRow)
                for x in stride(from: 0, to: bytesPerRow, by: 4) {
                    row[x] = fillValue
                    row[x + 1] = fillValue
                    row[x + 2] = fillValue
                    row[x + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return pixelBuffer
    }
}
