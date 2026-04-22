import CoreGraphics
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

struct NanocosmosStreamResolverTests {
    @Test
    func derivesPlayablePlaylistCandidatesFromSeedURL() throws {
        let seed = try #require(URL(string: "wss://bintu-h5live.nanocosmos.de/h5live/stream/stream.mp4?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=433201&pid=72860723635"))

        let candidates = try NanocosmosStreamResolver.derivePlaylistCandidates(seedURL: seed)

        #expect(candidates.map(\.absoluteString).contains("https://bintu-h5live.nanocosmos.de/h5live/http/playlist.m3u8?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=433201&pid=72860723635"))
    }

    @Test
    func resolvesRawNanocosmosSegmentLineToEncodedHTTPURL() throws {
        let playlistURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/playlist.m3u8?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=433201&pid=72860723635"))
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:1
        #EXTINF:1.0,
        stream.mp4?url=rtmp://localhost:1935/play&stream=COeCf-9jp1Q&cid=433201&pid=72860723635&h5pltc=4181112
        #EXT-X-ENDLIST
        """

        let streamURL = try NanocosmosStreamResolver.streamURL(fromPlaylist: playlist, playlistURL: playlistURL)

        #expect(streamURL.scheme == "https")
        #expect(streamURL.host == "bintu-h5live.nanocosmos.de")
        #expect(streamURL.path == "/h5live/http/stream.mp4")
        #expect(streamURL.absoluteString.contains("url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay"))
        #expect(streamURL.absoluteString.contains("stream=COeCf-9jp1Q"))
        #expect(streamURL.absoluteString.contains("h5pltc=4181112"))
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

    @Test
    func manualCellIntegerParserAcceptsPeriodThousandsSeparator() {
        #expect(ManualCellIntegerPolicy.parseInteger("10.000") == 10000)
    }

    @Test
    func manualCellIntegerParserAcceptsSingleAmbiguousDigitInsideNumericToken() {
        #expect(ManualCellIntegerPolicy.parseInteger("16A74") == 16474)
    }
}

struct TradingTriggerStateMachineTests {
    @Test
    func manualCellFiresOnlyOnceUntilRearmed() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1
        )

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
    func manualCellDoesNotRearmOnNonEmptyNonIntegerNoise() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1
        )

        _ = stateMachine.evaluateManualCell(normalizedText: "11")
        let nonInteger = stateMachine.evaluateManualCell(normalizedText: "ABCD")
        #expect(!nonInteger.isZeroOrEmpty)
        #expect(!nonInteger.isArmedAfter)

        let retrigger = stateMachine.evaluateManualCell(normalizedText: "5")
        #expect(!retrigger.shouldSendBuy)

        let rearmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(rearmed.isArmedAfter)

        let actualRetrigger = stateMachine.evaluateManualCell(normalizedText: "5")
        #expect(actualRetrigger.shouldSendBuy)
    }

    @Test
    func manualCellCanRequireMultipleZeroLikeFramesBeforeRearming() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        _ = stateMachine.evaluateManualCell(normalizedText: "11")
        let firstBlank = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(!firstBlank.isArmedAfter)

        let secondBlank = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(!secondBlank.isArmedAfter)

        let thirdBlank = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(thirdBlank.isArmedAfter)
    }

    @Test
    func manualCellCanRequireMultipleConfirmedReadsBeforeBuying() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2
        )

        let firstRead = stateMachine.evaluateManualCell(normalizedText: "10,000")
        #expect(!firstRead.shouldSendBuy)
        #expect(firstRead.isAwaitingConfirmation)
        #expect(firstRead.confirmationProgress == 1)

        let secondRead = stateMachine.evaluateManualCell(normalizedText: "10,000")
        #expect(secondRead.shouldSendBuy)
        #expect(secondRead.confirmationProgress == 2)
        #expect(!secondRead.isArmedAfter)
    }

    @Test
    func manualCellSingleFrameHallucinationDoesNotBuyWhenConfirmationRequired() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2
        )

        let noise = stateMachine.evaluateManualCell(normalizedText: "1,6.1")
        #expect(!noise.shouldSendBuy)
        #expect(noise.isAwaitingConfirmation)

        let cleared = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(!cleared.shouldSendBuy)
        #expect(cleared.isArmedAfter)

        let firstReal = stateMachine.evaluateManualCell(normalizedText: "10,000")
        #expect(!firstReal.shouldSendBuy)

        let secondReal = stateMachine.evaluateManualCell(normalizedText: "10,000")
        #expect(secondReal.shouldSendBuy)
    }

    @Test
    func manualSymbolLocksSymbolChangesUntilManualCellRearms() {
        let stateMachine = TradingTriggerStateMachine()

        let first = stateMachine.evaluateManualSymbol(normalizedText: "ms ft", confidence: 0.82)
        #expect(first.shouldSendSubscribe)
        #expect(first.normalizedSymbol == "MSFT")

        let second = stateMachine.evaluateManualSymbol(normalizedText: "m.s-f t", confidence: 0.82)
        #expect(!second.shouldSendSubscribe)
        #expect(second.isDuplicate)
        #expect(second.normalizedSymbol == "MSFT")

        let blankWhileAlreadyArmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(blankWhileAlreadyArmed.isArmedAfter)

        let third = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.82)
        #expect(!third.shouldSendSubscribe)
        #expect(third.isChangeLocked)
        #expect(third.normalizedSymbol == "AAPL")

        _ = stateMachine.evaluateManualCell(normalizedText: "15")
        let rearmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(rearmed.isArmedAfter)

        let fourth = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.82)
        #expect(fourth.shouldSendSubscribe)
        #expect(fourth.normalizedSymbol == "AAPL")
    }

    @Test
    func manualSymbolChangedSymbolRequiresHigherConfidenceAfterRearm() {
        let stateMachine = TradingTriggerStateMachine(manualSymbolTriggerConfirmationFrames: 1)

        let first = stateMachine.evaluateManualSymbol(normalizedText: "plrz", confidence: 0.82)
        #expect(first.shouldSendSubscribe)

        _ = stateMachine.evaluateManualCell(normalizedText: "15")
        let rearmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(rearmed.isArmedAfter)

        let lowConfidenceChange = stateMachine.evaluateManualSymbol(normalizedText: "plpz", confidence: 0.77)
        #expect(!lowConfidenceChange.shouldSendSubscribe)
        #expect(lowConfidenceChange.isChangeLocked)

        let highConfidenceChange = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.80)
        #expect(highConfidenceChange.shouldSendSubscribe)
        #expect(highConfidenceChange.normalizedSymbol == "AAPL")
    }
}

struct TriggerPipelineVerificationHarnessTests {
    @Test
    func manualCellTransitionsEmitSingleBuyUntilRearm() {
        let sender = CapturingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {}
        )

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
    func manualSymbolTransitionsEmitSubscribeOnlyAfterManualCellRearm() {
        let sender = CapturingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {}
        )

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
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.9)
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "aapl",
            normalizedText: "AAPL",
            confidence: 0.8
        )

        #expect(
            sender.messages == [
                #"{"subscribe":"MSFT"}"#,
                TradingWebSocketContract.buyMessage,
                #"{"subscribe":"AAPL"}"#
            ]
        )
    }

    @Test
    func manualSymbolRequiresConfirmationBeforeSubscribe() {
        let sender = CapturingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 2,
            messageSender: sender,
            beep: {}
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "plrz",
            normalizedText: "PLRZ",
            confidence: 0.8
        )
        #expect(sender.messages.isEmpty)

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "p l r z",
            normalizedText: "P L R Z",
            confidence: 0.8
        )
        #expect(sender.messages == [#"{"subscribe":"PLRZ"}"#])
    }

    @Test
    func eventHandlerReceivesOnlySignalEvents() {
        let sender = CapturingMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "0", normalizedText: "0", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualSymbolCell, rawText: "ms ft", normalizedText: "MS FT", confidence: 0.8)
        pipeline.processTriggerEventForTesting(region: .manualSymbolCell, rawText: "m.s-f t", normalizedText: "M.S-F T", confidence: 0.8)

        #expect(
            eventCollector.events == [
                OCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: 3,
                    region: "manual_cell",
                    action: "buy_sent",
                    rawText: "15",
                    normalizedText: "15",
                    confidence: 0.9,
                    symbol: nil,
                    parsedInteger: 15,
                    isDuplicate: false,
                    isZeroOrEmpty: false,
                    presentationTimeSeconds: nil
                ),
                OCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: 4,
                    region: "manual_symbol_cell",
                    action: "subscribe_sent",
                    rawText: "ms ft",
                    normalizedText: "MS FT",
                    confidence: 0.8,
                    symbol: "MSFT",
                    parsedInteger: nil,
                    isDuplicate: false,
                    isZeroOrEmpty: nil,
                    presentationTimeSeconds: nil
                )
            ]
        )
    }

    @Test
    func manualCellRequiresConfirmationBeforeSendingBuy() {
        let sender = CapturingMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2,
            messageSender: sender,
            beep: {}
        )

        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "1,6.1",
            normalizedText: "1,6.1",
            confidence: 0.3
        )
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.0)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "10,000",
            normalizedText: "10,000",
            confidence: 1.0
        )
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "10,000",
            normalizedText: "10,000",
            confidence: 1.0
        )

        #expect(sender.messages == [TradingWebSocketContract.buyMessage])
    }

    @Test
    func unchangedManualCellFrameConfirmsCachedRecognitionWithoutRerunningOCR() {
        let sender = CapturingMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let recognizer = CountingTextRecognizer(
            result: OCRTextRecognition(rawText: "10,000", confidence: 1.0)
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2,
            recognizer: recognizer,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )
        let pixelBuffer = makeSolidPixelBuffer(width: 48, height: 48, fillValue: 0)
        let runtimeConfig = CaptureRuntimeConfig(
            displayID: 0,
            displayWidth: 48,
            displayHeight: 48,
            baseROI: PixelRect(x: 0, y: 0, width: 48, height: 48),
            manualCellROI: PixelRect(x: 0, y: 0, width: 48, height: 48),
            symbolROI: nil,
            manualSymbolCellROI: nil
        )

        pipeline.process(VideoFrame(pixelBuffer: pixelBuffer), runtimeConfig: runtimeConfig)
        pipeline.process(VideoFrame(pixelBuffer: pixelBuffer), runtimeConfig: runtimeConfig)

        #expect(recognizer.callCount == 1)
        #expect(sender.messages == [TradingWebSocketContract.buyMessage])
        #expect(eventCollector.events.count == 2)
        #expect(eventCollector.events[0].kind == .recognition)
        #expect(eventCollector.events[1].kind == .trigger)
        #expect(eventCollector.events[1].frameNumber == 2)
        #expect(eventCollector.events[1].parsedInteger == 10000)
    }

    private final class CapturingMessageSender: TradingMessageSending, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var messages: [String] = []

        func send(
            _ payload: String,
            event _: String,
            completion: @escaping @Sendable (Result<Void, any Error>) -> Void
        ) {
            lock.lock()
            messages.append(payload)
            lock.unlock()
            completion(.success(()))
        }
    }

    private final class CapturingPipelineEventHandler: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [OCRPipelineEvent] = []

        func handle(_ event: OCRPipelineEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
    }

    private final class CountingTextRecognizer: OCRTextRecognizing, @unchecked Sendable {
        private let lock = NSLock()
        private let result: OCRTextRecognition
        private var calls = 0

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        init(result: OCRTextRecognition) {
            self.result = result
        }

        func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRTextRecognition {
            _ = pixelBuffer
            _ = region
            lock.lock()
            calls += 1
            lock.unlock()
            return result
        }
    }

    private func makeSolidPixelBuffer(width: Int, height: Int, fillValue: UInt8) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        #expect(status == kCVReturnSuccess)
        guard let pixelBuffer else {
            fatalError("Failed to allocate solid pixel buffer.")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            fatalError("Missing base address for solid pixel buffer.")
        }

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

        return pixelBuffer
    }
}

struct CaptureRuntimeConfigScalingTests {
    @Test
    func adjustedForFrameSizeScalesNestedROIs() {
        let config = CaptureRuntimeConfig(
            displayID: 7,
            displayWidth: 1920,
            displayHeight: 1080,
            baseROI: PixelRect(x: 100, y: 200, width: 400, height: 200),
            manualCellROI: PixelRect(x: 120, y: 220, width: 100, height: 50),
            symbolROI: PixelRect(x: 600, y: 100, width: 240, height: 120),
            manualSymbolCellROI: PixelRect(x: 620, y: 120, width: 80, height: 40)
        )

        let scaled = config.adjustedForFrameSize(width: 960, height: 540)

        #expect(scaled.displayID == 7)
        #expect(scaled.displayWidth == 960)
        #expect(scaled.displayHeight == 540)
        #expect(scaled.baseROI == PixelRect(x: 50, y: 100, width: 200, height: 100))
        #expect(scaled.manualCellROI == PixelRect(x: 60, y: 110, width: 50, height: 25))
        #expect(scaled.symbolROI == PixelRect(x: 300, y: 50, width: 120, height: 60))
        #expect(scaled.manualSymbolCellROI == PixelRect(x: 310, y: 60, width: 40, height: 20))
    }
}

struct OfflineVerificationEngineTests {
    @Test
    func verifyMatchesRecognitionAndTriggerSections() {
        let expected = OfflineExpectedOutput(
            recognitionEvents: [
                OfflineExpectedOCRPipelineEvent(
                    kind: .recognition,
                    frameNumber: 12,
                    region: "manual_cell",
                    action: "ocr_changed",
                    rawText: "15",
                    normalizedText: "15",
                    symbol: nil,
                    parsedInteger: 15,
                    presentationTimeSeconds: 1.0,
                    presentationTimeToleranceSeconds: 0.1
                )
            ],
            triggerEvents: [
                OfflineExpectedOCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: 12,
                    region: "manual_cell",
                    action: "buy_sent",
                    rawText: "15",
                    normalizedText: "15",
                    symbol: nil,
                    parsedInteger: 15,
                    presentationTimeSeconds: nil,
                    presentationTimeToleranceSeconds: nil
                )
            ]
        )

        let recognitionActual = [
            OCRPipelineEvent(
                kind: .recognition,
                frameNumber: 12,
                region: "manual_cell",
                action: "ocr_changed",
                rawText: "15",
                normalizedText: "15",
                confidence: 0.97,
                symbol: nil,
                parsedInteger: 15,
                isDuplicate: nil,
                isZeroOrEmpty: nil,
                presentationTimeSeconds: 1.04
            )
        ]
        let triggerActual = [
            OCRPipelineEvent(
                kind: .trigger,
                frameNumber: 12,
                region: "manual_cell",
                action: "buy_sent",
                rawText: "15",
                normalizedText: "15",
                confidence: 0.97,
                symbol: nil,
                parsedInteger: 15,
                isDuplicate: false,
                isZeroOrEmpty: false,
                presentationTimeSeconds: 1.04
            )
        ]

        let report = OfflineVerificationEngine.verify(
            expected: expected,
            actualRecognitionEvents: recognitionActual,
            actualTriggerEvents: triggerActual
        )

        #expect(report.matched)
        #expect(report.recognition?.matched == true)
        #expect(report.trigger?.matched == true)
        #expect(report.recognition?.mismatches.isEmpty == true)
        #expect(report.trigger?.mismatches.isEmpty == true)
    }

    @Test
    func verifyReportsRecognitionMismatchWithoutAffectingTriggerMatch() {
        let expected = OfflineExpectedOutput(
            recognitionEvents: [
                OfflineExpectedOCRPipelineEvent(
                    kind: .recognition,
                    frameNumber: nil,
                    region: "manual_symbol_cell",
                    action: "ocr_changed",
                    rawText: nil,
                    normalizedText: "AAPL",
                    symbol: "AAPL",
                    parsedInteger: nil,
                    presentationTimeSeconds: nil,
                    presentationTimeToleranceSeconds: nil
                )
            ],
            triggerEvents: [
                OfflineExpectedOCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: nil,
                    region: "manual_cell",
                    action: "buy_sent",
                    rawText: nil,
                    normalizedText: "15",
                    symbol: nil,
                    parsedInteger: 15,
                    presentationTimeSeconds: nil,
                    presentationTimeToleranceSeconds: nil
                )
            ]
        )

        let recognitionActual = [
            OCRPipelineEvent(
                kind: .recognition,
                frameNumber: 8,
                region: "manual_symbol_cell",
                action: "ocr_changed",
                rawText: "ms ft",
                normalizedText: "MS FT",
                confidence: 0.93,
                symbol: "MSFT",
                parsedInteger: nil,
                isDuplicate: nil,
                isZeroOrEmpty: nil,
                presentationTimeSeconds: 0.5
            )
        ]
        let triggerActual = [
            OCRPipelineEvent(
                kind: .trigger,
                frameNumber: 12,
                region: "manual_cell",
                action: "buy_sent",
                rawText: "15",
                normalizedText: "15",
                confidence: 0.98,
                symbol: nil,
                parsedInteger: 15,
                isDuplicate: false,
                isZeroOrEmpty: false,
                presentationTimeSeconds: 0.8
            )
        ]

        let report = OfflineVerificationEngine.verify(
            expected: expected,
            actualRecognitionEvents: recognitionActual,
            actualTriggerEvents: triggerActual
        )

        #expect(!report.matched)
        #expect(report.recognition?.matched == false)
        #expect(report.trigger?.matched == true)
        #expect(report.recognition?.mismatches.first?.reason == "normalized_text_mismatch")
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
