import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CaptureShellApp

struct TradingMessageContractTests {
    @Test
    func buyMessageMatchesContract() {
        #expect(TradingMessageContract.buyMessage == #"{"action":"BUY"}"#)
    }

    @Test
    func subscribeMessageTrimsAndUppercasesSymbol() {
        #expect(
            TradingMessageContract.subscribeMessage(symbol: "  msft\n") == #"{"subscribe":"MSFT"}"#
        )
    }

    @Test
    func subscribeMessageRejectsLaunderedSymbolInput() {
        #expect(TradingMessageContract.subscribeMessage(symbol: " m s-f.t 1 ") == nil)
    }

    @Test
    func subscribeMessageRejectsNonASCIILetters() {
        #expect(TradingMessageContract.subscribeMessage(symbol: "ÅAPL") == nil)

        let analysis = TradingMessageContract.analyzeSymbol("ÅAPL")
        #expect(analysis.normalized == "APL")
        #expect(analysis.droppedAlphanumericCount == 1)
        #expect(analysis.droppedDigitCount == 0)
        #expect(analysis.shouldRejectOCRCandidate)
    }

    @Test
    func normalizeSymbolRejectsDroppedAlphanumericOCRCandidates() {
        #expect(TradingMessageContract.normalizeSymbol("PLR2") == "")
        #expect(TradingMessageContract.normalizedOCRSymbol("P1LRZ") == nil)

        let analysis = TradingMessageContract.analyzeSymbol("P1LRZ")
        #expect(analysis.normalized == "PLRZ")
        #expect(analysis.droppedAlphanumericCount == 1)
        #expect(analysis.droppedDigitCount == 1)
        #expect(analysis.shouldRejectOCRCandidate)
    }
}

struct PipelineTimingMetricsTests {
    @Test
    func extractsBuySignalTimingsFromCollectedEvents() {
        let collectedEvents = [
            CollectedOCRPipelineEvent(
                event: OCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: 1,
                    region: "manual_cell",
                    action: "armed",
                    rawText: "",
                    normalizedText: "",
                    confidence: 0,
                    symbol: nil,
                    parsedInteger: nil,
                    isDuplicate: nil,
                    isZeroOrEmpty: true,
                    presentationTimeSeconds: 0.1
                ),
                analysisTimeSeconds: 0.03
            ),
            CollectedOCRPipelineEvent(
                event: OCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: 2,
                    region: "manual_cell",
                    action: "buy_triggered",
                    rawText: "10000",
                    normalizedText: "10000",
                    confidence: 0.99,
                    symbol: nil,
                    parsedInteger: 10000,
                    isDuplicate: false,
                    isZeroOrEmpty: false,
                    presentationTimeSeconds: 0.133
                ),
                analysisTimeSeconds: 0.045
            ),
            CollectedOCRPipelineEvent(
                event: OCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: 3,
                    region: "manual_cell",
                    action: "buy_transport_succeeded",
                    rawText: "10000",
                    normalizedText: "10000",
                    confidence: 0.99,
                    symbol: nil,
                    parsedInteger: 10000,
                    isDuplicate: false,
                    isZeroOrEmpty: false,
                    presentationTimeSeconds: 0.133
                ),
                analysisTimeSeconds: 0.049
            )
        ]

        #expect(
            PipelineTimingMetrics.buySignalTimings(from: collectedEvents) == [
                BuySignalTiming(
                    frameNumber: 2,
                    analysisTimeSeconds: 0.045,
                    presentationTimeSeconds: 0.133,
                    rawText: "10000",
                    normalizedText: "10000",
                    parsedInteger: 10000
                )
            ]
        )
    }

    @Test
    func summarizesTriggerPathSamples() {
        let samples = [
            TriggerPathTimingSample(
                frameIngressToRegionMilliseconds: 1,
                preprocessMilliseconds: 2,
                cropMilliseconds: 0.5,
                metalMilliseconds: 0.5,
                fingerprintMilliseconds: 0.5,
                gatingMilliseconds: 0.5,
                ocrMilliseconds: 3,
                triggerEvaluationMilliseconds: 4,
                decisionMilliseconds: 5,
                transportCompletionMilliseconds: 6,
                ocrToCompletionMilliseconds: 7,
                totalEndToEndMilliseconds: 6,
                succeeded: true
            ),
            TriggerPathTimingSample(
                frameIngressToRegionMilliseconds: 3,
                preprocessMilliseconds: 4,
                cropMilliseconds: 1,
                metalMilliseconds: 1,
                fingerprintMilliseconds: 1,
                gatingMilliseconds: 1,
                ocrMilliseconds: 5,
                triggerEvaluationMilliseconds: 6,
                decisionMilliseconds: 7,
                transportCompletionMilliseconds: 8,
                ocrToCompletionMilliseconds: 9,
                totalEndToEndMilliseconds: 8,
                succeeded: false
            )
        ]

        #expect(
            PipelineTimingMetrics.summarizeTriggerPathSamples(samples) ==
                TriggerPathTimingSummary(
                    sampleCount: 2,
                    successCount: 1,
                    failureCount: 1,
                    averageFrameIngressToRegionMilliseconds: 2,
                    averagePreprocessMilliseconds: 3,
                    averageOCRMilliseconds: 4,
                    averageTriggerEvaluationMilliseconds: 5,
                    averageDecisionMilliseconds: 6,
                    averageTransportCompletionMilliseconds: 7,
                    averageOCRToCompletionMilliseconds: 8,
                    averageTotalEndToEndMilliseconds: 7,
                    maximumTotalEndToEndMilliseconds: 8
                )
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
    func derivesDirectPlaybackCandidatesFromSeedURL() throws {
        let seed = try #require(URL(string: "wss://bintu-h5live.nanocosmos.de/h5live/stream/stream.mp4?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=433201&pid=72860723635"))

        let candidates = try NanocosmosStreamResolver.deriveDirectPlaybackCandidates(seedURL: seed)

        #expect(
            candidates.map(\.absoluteString).contains(
                "https://bintu-h5live.nanocosmos.de/h5live/http/stream.mp4?stream=COeCf-9jp1Q&cid=433201&pid=72860723635"
            )
        )
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

    @Test
    func finitePlaylistPrefersDirectPlaybackURL() throws {
        let playlistURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/playlist.m3u8?stream=COeCf-9jp1Q&cid=42674&pid=63178402599"))
        let streamURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/stream.mp4?stream=COeCf-9jp1Q&cid=42674&pid=63178402599&h5pltc=2425224"))
        let directCandidate = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/stream.mp4?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=42674&pid=63178402599"))
        let finitePlaylist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-TARGETDURATION:1
        #EXTINF:1.0,
        stream.mp4?stream=COeCf-9jp1Q&cid=42674&pid=63178402599&h5pltc=2425224
        #EXT-X-ENDLIST
        """

        let playbackURL = NanocosmosStreamResolver.preferredPlaybackURL(
            playlistText: finitePlaylist,
            playlistURL: playlistURL,
            streamURL: streamURL,
            directPlaybackCandidates: [directCandidate]
        )

        #expect(playbackURL == directCandidate)
    }

    @Test
    func rollingPlaylistKeepsPlaylistPlaybackURL() throws {
        let playlistURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/playlist.m3u8?stream=COeCf-9jp1Q&cid=42674&pid=63178402599"))
        let streamURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/stream.mp4?stream=COeCf-9jp1Q&cid=42674&pid=63178402599&h5pltc=2425224"))
        let rollingPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:1
        #EXTINF:1.0,
        stream.mp4?stream=COeCf-9jp1Q&cid=42674&pid=63178402599&h5pltc=2425224
        """

        let playbackURL = NanocosmosStreamResolver.preferredPlaybackURL(
            playlistText: rollingPlaylist,
            playlistURL: playlistURL,
            streamURL: streamURL,
            directPlaybackCandidates: []
        )

        #expect(playbackURL == playlistURL)
    }

    @Test
    func recordingSourceURLPrefersOriginalDirectSeedCandidate() throws {
        let seedURL = try #require(URL(string: "wss://bintu-h5live.nanocosmos.de/h5live/stream/stream.mp4?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=42674&pid=63178402599"))
        let playlistURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/playlist.m3u8?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=42674&pid=63178402599"))
        let streamURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/stream.mp4?stream=COeCf-9jp1Q&cid=42674&pid=63178402599&h5pltc=2425224"))
        let resolved = ResolvedLiveStream(
            seedURL: seedURL,
            playlistURL: playlistURL,
            playbackURL: playlistURL,
            alternatePlaybackURLs: [],
            streamURL: streamURL,
            playlistText: "#EXTM3U"
        )

        let recordingURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(seedURL: seedURL, resolved: resolved)

        #expect(recordingURL.absoluteString.contains("url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay"))
        #expect(recordingURL.path.lowercased().contains("/stream.mp4"))
    }
}

struct LiveMediaCaptureCoordinatorTests {
    @Test
    func preferredRecordingSourceURLUsesOriginalDirectCandidate() throws {
        let seedURL = try #require(URL(string: "wss://bintu-h5live.nanocosmos.de/h5live/stream/stream.mp4?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=42674&pid=63178402599"))

        let recordingURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(seedURL: seedURL)

        #expect(recordingURL.absoluteString == "https://bintu-h5live.nanocosmos.de/h5live/http/stream.mp4?url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&stream=COeCf-9jp1Q&cid=42674&pid=63178402599")
    }

    @Test
    func preferredRecordingSourceURLKeepsFirstDirectCandidateForBintuPlaySeed() throws {
        let seedURL = try #require(URL(string: "wss://bintu-play.nanocosmos.de/h5live/stream/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Flocalhost%2Fplay&flags=checkandclose"))

        let recordingURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(seedURL: seedURL)

        #expect(recordingURL.absoluteString == "https://bintu-play.nanocosmos.de/h5live/http/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Flocalhost%2Fplay&flags=checkandclose")
    }

    @Test
    func estimatedFrameCountUsesDurationAndNominalFrameRate() {
        #expect(
            LiveSourceStreamRecorder.estimatedFrameCount(
                nominalFrameRate: 30,
                durationSeconds: 7.8
            ) == 234
        )
        #expect(
            LiveSourceStreamRecorder.estimatedFrameCount(
                nominalFrameRate: 30000 / 1001,
                durationSeconds: 7.82
            ) == 234
        )
    }
}

struct NanocosmosStreamingChunkPullerTests {
    @Test
    func supportsStreamingMP4SourceURLs() throws {
        let streamURL = try #require(URL(string: "https://bintu-play.nanocosmos.de/h5live/http/stream.mp4?stream=wptPV-dvBBZ"))
        let playlistURL = try #require(URL(string: "https://bintu-play.nanocosmos.de/h5live/http/playlist.m3u8?stream=wptPV-dvBBZ"))

        #expect(NanocosmosStreamingChunkPuller.supports(sourceURL: streamURL))
        #expect(!NanocosmosStreamingChunkPuller.supports(sourceURL: playlistURL))
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
        #expect(!first.shouldTriggerBuy)
        #expect(first.isArmedAfter)

        let second = stateMachine.evaluateManualCell(normalizedText: "0")
        #expect(!second.shouldTriggerBuy)
        #expect(second.isArmedAfter)

        let third = stateMachine.evaluateManualCell(normalizedText: "42")
        #expect(third.shouldTriggerBuy)
        #expect(third.isArmedAfter)
        stateMachine.commitManualCellTriggerSuccess()

        let fourth = stateMachine.evaluateManualCell(normalizedText: "42")
        #expect(!fourth.shouldTriggerBuy)
        #expect(fourth.isDuplicate)
        #expect(!fourth.isArmedAfter)

        let fifth = stateMachine.evaluateManualCell(normalizedText: "99")
        #expect(!fifth.shouldTriggerBuy)
        #expect(!fifth.isArmedAfter)

        let sixth = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(!sixth.shouldTriggerBuy)
        #expect(sixth.isArmedAfter)

        let seventh = stateMachine.evaluateManualCell(normalizedText: "7")
        #expect(seventh.shouldTriggerBuy)
        #expect(seventh.isArmedAfter)
    }

    @Test
    func manualCellDoesNotRearmOnNonEmptyNonIntegerNoise() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1
        )

        let firstTrigger = stateMachine.evaluateManualCell(normalizedText: "11")
        #expect(firstTrigger.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess()
        let nonInteger = stateMachine.evaluateManualCell(normalizedText: "ABCD")
        #expect(!nonInteger.isZeroOrEmpty)
        #expect(!nonInteger.isArmedAfter)

        let retrigger = stateMachine.evaluateManualCell(normalizedText: "5")
        #expect(!retrigger.shouldTriggerBuy)

        let rearmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(rearmed.isArmedAfter)

        let actualRetrigger = stateMachine.evaluateManualCell(normalizedText: "5")
        #expect(actualRetrigger.shouldTriggerBuy)
    }

    @Test
    func manualCellCanRequireMultipleZeroLikeFramesBeforeRearming() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        let firstTrigger = stateMachine.evaluateManualCell(normalizedText: "11")
        #expect(firstTrigger.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess()
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
        #expect(!firstRead.shouldTriggerBuy)
        #expect(firstRead.isAwaitingConfirmation)
        #expect(firstRead.confirmationProgress == 1)

        let secondRead = stateMachine.evaluateManualCell(normalizedText: "10,000")
        #expect(secondRead.shouldTriggerBuy)
        #expect(secondRead.confirmationProgress == 2)
        #expect(secondRead.isArmedAfter)
    }

    @Test
    func manualCellSingleFrameHallucinationDoesNotBuyWhenConfirmationRequired() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2
        )

        let noise = stateMachine.evaluateManualCell(normalizedText: "1,6.1")
        #expect(!noise.shouldTriggerBuy)
        #expect(noise.isAwaitingConfirmation)

        let cleared = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(!cleared.shouldTriggerBuy)
        #expect(cleared.isArmedAfter)

        let firstReal = stateMachine.evaluateManualCell(normalizedText: "10,000")
        #expect(!firstReal.shouldTriggerBuy)

        let secondReal = stateMachine.evaluateManualCell(normalizedText: "10,000")
        #expect(secondReal.shouldTriggerBuy)
    }

    @Test
    func manualSymbolLocksSymbolChangesUntilManualCellRearms() {
        let stateMachine = TradingTriggerStateMachine()

        let first = stateMachine.evaluateManualSymbol(normalizedText: "ms ft", confidence: 0.82)
        #expect(first.shouldTriggerSubscribe)
        #expect(first.normalizedSymbol == "MSFT")
        stateMachine.commitManualSymbolTriggerSuccess(symbol: first.normalizedSymbol)

        let second = stateMachine.evaluateManualSymbol(normalizedText: "m.s-f t", confidence: 0.82)
        #expect(!second.shouldTriggerSubscribe)
        #expect(second.isDuplicate)
        #expect(second.normalizedSymbol == "MSFT")

        let blankWhileAlreadyArmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(blankWhileAlreadyArmed.isArmedAfter)

        let third = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.82)
        #expect(!third.shouldTriggerSubscribe)
        #expect(third.isChangeLocked)
        #expect(third.normalizedSymbol == "AAPL")

        let buy = stateMachine.evaluateManualCell(normalizedText: "15")
        #expect(buy.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess()
        let rearmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(rearmed.isArmedAfter)

        let fourth = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.82)
        #expect(fourth.shouldTriggerSubscribe)
        #expect(fourth.normalizedSymbol == "AAPL")
    }

    @Test
    func manualSymbolChangedSymbolRequiresHigherConfidenceAfterRearm() {
        let stateMachine = TradingTriggerStateMachine(manualSymbolTriggerConfirmationFrames: 1)

        let first = stateMachine.evaluateManualSymbol(normalizedText: "plrz", confidence: 0.82)
        #expect(first.shouldTriggerSubscribe)
        stateMachine.commitManualSymbolTriggerSuccess(symbol: first.normalizedSymbol)

        let buy = stateMachine.evaluateManualCell(normalizedText: "15")
        #expect(buy.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess()
        let rearmed = stateMachine.evaluateManualCell(normalizedText: "")
        #expect(rearmed.isArmedAfter)

        let lowConfidenceChange = stateMachine.evaluateManualSymbol(normalizedText: "plpz", confidence: 0.77)
        #expect(!lowConfidenceChange.shouldTriggerSubscribe)
        #expect(lowConfidenceChange.isChangeLocked)

        let highConfidenceChange = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.80)
        #expect(highConfidenceChange.shouldTriggerSubscribe)
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
                TradingMessageContract.buyMessage,
                TradingMessageContract.buyMessage
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
                TradingMessageContract.buyMessage,
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
                    action: "buy_triggered",
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
                    action: "subscribe_triggered",
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
    func buyTriggerQueuesTransportOutcomeAndCommitsOnlyOnSuccess() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)

        #expect(sender.messages == [TradingMessageContract.buyMessage])
        #expect(eventCollector.events.map(\.action) == ["buy_triggered"])

        sender.succeedNext()
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_succeeded"])

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        #expect(sender.messages == [TradingMessageContract.buyMessage])
    }

    @Test
    func buyTransportFailureLeavesTriggerRetryable() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        sender.failNext()

        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_failed"])

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        #expect(sender.messages == [TradingMessageContract.buyMessage, TradingMessageContract.buyMessage])
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_failed", "buy_triggered"])

        sender.succeedNext()
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_failed", "buy_triggered", "buy_transport_succeeded"])
    }

    @Test
    func staleBuyTransportSuccessDoesNotDisarmAfterConfirmedDifferentCandidate() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "20", normalizedText: "20", confidence: 0.9)
        sender.succeedNext()
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "20", normalizedText: "20", confidence: 0.9)

        #expect(sender.messages == [TradingMessageContract.buyMessage, TradingMessageContract.buyMessage])
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_succeeded", "buy_triggered"])
    }

    @Test
    func transientBlankDoesNotStalePendingBuyBeforeTrueRearm() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 12,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.9)
        sender.succeedNext()
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)

        #expect(sender.messages == [TradingMessageContract.buyMessage])
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_succeeded"])
    }

    @Test
    func subscribeTriggerQueuesTransportOutcomeAndCommitsOnlyOnSuccess() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "ms ft",
            normalizedText: "MS FT",
            confidence: 0.8
        )
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "ms ft",
            normalizedText: "MS FT",
            confidence: 0.8
        )

        #expect(sender.messages == [#"{"subscribe":"MSFT"}"#])
        #expect(eventCollector.events.map(\.action) == ["subscribe_triggered"])

        sender.succeedNext()
        #expect(eventCollector.events.map(\.action) == ["subscribe_triggered", "subscribe_transport_succeeded"])

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "ms ft",
            normalizedText: "MS FT",
            confidence: 0.8
        )
        #expect(sender.messages == [#"{"subscribe":"MSFT"}"#])
    }

    @Test
    func staleSubscribeTransportSuccessDoesNotRelockAfterManualCellRearm() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "plrz",
            normalizedText: "PLRZ",
            confidence: 0.9
        )
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "15",
            normalizedText: "15",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: TradingMessageContract.buyMessage)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.9)
        sender.succeedNext(matchingPayload: #"{"subscribe":"PLRZ"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "aapl",
            normalizedText: "AAPL",
            confidence: 0.9
        )

        #expect(
            sender.messages == [
                #"{"subscribe":"PLRZ"}"#,
                TradingMessageContract.buyMessage,
                #"{"subscribe":"AAPL"}"#
            ]
        )
        #expect(
            eventCollector.events.map(\.action) == [
                "subscribe_triggered",
                "buy_triggered",
                "buy_transport_succeeded",
                "subscribe_transport_succeeded",
                "subscribe_triggered"
            ]
        )
    }

    @Test
    func tentativeAlternateSymbolDoesNotStalePendingSubscribe() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 2,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "plrz",
            normalizedText: "PLRZ",
            confidence: 0.9
        )
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "plrz",
            normalizedText: "PLRZ",
            confidence: 0.9
        )
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "aapl",
            normalizedText: "AAPL",
            confidence: 0.9
        )
        sender.succeedNext()
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "aapl",
            normalizedText: "AAPL",
            confidence: 0.9
        )

        #expect(sender.messages == [#"{"subscribe":"PLRZ"}"#])
        #expect(
            eventCollector.events.map(\.action) == [
                "subscribe_triggered",
                "subscribe_transport_succeeded"
            ]
        )
    }

    @Test
    func manualSymbolTriggerRejectsDigitLaunderedOCRCandidate() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "PLR2",
            normalizedText: "PLR2",
            confidence: 0.95
        )

        #expect(sender.messages.isEmpty)
        #expect(eventCollector.events.isEmpty)
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

        #expect(sender.messages == [TradingMessageContract.buyMessage])
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
            symbolRecognizer: recognizer,
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
        #expect(sender.messages == [TradingMessageContract.buyMessage])
        #expect(eventCollector.events.count == 2)
        #expect(eventCollector.events[0].kind == .recognition)
        #expect(eventCollector.events[1].kind == .trigger)
        #expect(eventCollector.events[1].frameNumber == 2)
        #expect(eventCollector.events[1].parsedInteger == 10000)
    }

    @Test
    func unchangedManualSymbolSampledFrameConfirmsCachedRecognitionWithoutRerunningOCR() {
        let sender = CapturingMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let recognizer = RegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "", confidence: 1.0),
                .manualSymbolCell: OCRTextRecognition(rawText: "PLRZ", confidence: 0.9)
            ]
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2,
            manualSymbolSamplingIntervalFrames: 30,
            manualSymbolTriggerConfirmationFrames: 2,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
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
            symbolROI: PixelRect(x: 0, y: 0, width: 48, height: 48),
            manualSymbolCellROI: PixelRect(x: 0, y: 0, width: 48, height: 48)
        )

        for _ in 0..<30 {
            pipeline.process(VideoFrame(pixelBuffer: pixelBuffer), runtimeConfig: runtimeConfig)
        }

        #expect(recognizer.callCount(for: .manualCell) == 1)
        #expect(recognizer.callCount(for: .manualSymbolCell) == 1)
        #expect(sender.messages == [#"{"subscribe":"PLRZ"}"#])
        #expect(eventCollector.events.map(\.action).contains("subscribe_triggered"))
        #expect(eventCollector.events.last?.frameNumber == 30)
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

    private final class ControlledTransportMessageSender: TradingMessageSending, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var messages: [String] = []
        private var pendingMessages: [PendingMessage] = []

        var reportsTransportOutcomes: Bool { true }

        private struct PendingMessage {
            let payload: String
            let completion: @Sendable (Result<Void, any Error>) -> Void
        }

        func send(
            _ payload: String,
            event _: String,
            completion: @escaping @Sendable (Result<Void, any Error>) -> Void
        ) {
            lock.lock()
            messages.append(payload)
            pendingMessages.append(PendingMessage(payload: payload, completion: completion))
            lock.unlock()
        }

        func succeedNext() {
            resolveNext(with: .success(()))
        }

        func succeedNext(matchingPayload payload: String) {
            resolveNext(matchingPayload: payload, with: .success(()))
        }

        func failNext() {
            resolveNext(with: .failure(TestTransportError.sendFailed))
        }

        private func resolveNext(with result: Result<Void, any Error>) {
            let completion: (@Sendable (Result<Void, any Error>) -> Void)?
            lock.lock()
            completion = pendingMessages.isEmpty ? nil : pendingMessages.removeFirst().completion
            lock.unlock()
            completion?(result)
        }

        private func resolveNext(matchingPayload payload: String, with result: Result<Void, any Error>) {
            let completion: (@Sendable (Result<Void, any Error>) -> Void)?
            lock.lock()
            if let index = pendingMessages.firstIndex(where: { $0.payload == payload }) {
                completion = pendingMessages.remove(at: index).completion
            } else {
                completion = nil
            }
            lock.unlock()
            completion?(result)
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

    private final class RegionAwareCountingTextRecognizer: OCRTextRecognizing, @unchecked Sendable {
        private let lock = NSLock()
        private let results: [OCRRegionKind: OCRTextRecognition]
        private var calls: [OCRRegionKind: Int] = [:]

        init(results: [OCRRegionKind: OCRTextRecognition]) {
            self.results = results
        }

        func callCount(for region: OCRRegionKind) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return calls[region, default: 0]
        }

        func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRTextRecognition {
            _ = pixelBuffer
            lock.lock()
            calls[region, default: 0] += 1
            let result = results[region] ?? OCRTextRecognition(rawText: "", confidence: 0)
            lock.unlock()
            return result
        }
    }

    private enum TestTransportError: Error {
        case sendFailed
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
                    action: "buy_triggered",
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
                action: "buy_triggered",
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
                    action: "buy_triggered",
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
                action: "buy_triggered",
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

    @Test
    func verifyAllowsExtraActualTriggerEventsWhenExpectedOrderIsPreserved() {
        let expected = OfflineExpectedOutput(
            recognitionEvents: nil,
            triggerEvents: [
                OfflineExpectedOCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: nil,
                    region: "manual_cell",
                    action: "buy_triggered",
                    rawText: nil,
                    normalizedText: "15",
                    symbol: nil,
                    parsedInteger: 15,
                    presentationTimeSeconds: nil,
                    presentationTimeToleranceSeconds: nil
                )
            ]
        )

        let triggerActual = [
            OCRPipelineEvent(
                kind: .trigger,
                frameNumber: 12,
                region: "manual_cell",
                action: "buy_triggered",
                rawText: "15",
                normalizedText: "15",
                confidence: 0.98,
                symbol: nil,
                parsedInteger: 15,
                isDuplicate: false,
                isZeroOrEmpty: false,
                presentationTimeSeconds: 0.8
            ),
            OCRPipelineEvent(
                kind: .trigger,
                frameNumber: 12,
                region: "manual_cell",
                action: "buy_transport_succeeded",
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
            actualRecognitionEvents: [],
            actualTriggerEvents: triggerActual
        )

        #expect(report.matched)
        #expect(report.trigger?.matched == true)
        #expect(report.trigger?.mismatches.isEmpty == true)
    }

    @Test
    func verifyFailsWhenExpectedTriggerOrderDoesNotMatchActualOrder() {
        let expected = OfflineExpectedOutput(
            recognitionEvents: nil,
            triggerEvents: [
                OfflineExpectedOCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: nil,
                    region: "manual_cell",
                    action: "buy_transport_succeeded",
                    rawText: nil,
                    normalizedText: "15",
                    symbol: nil,
                    parsedInteger: 15,
                    presentationTimeSeconds: nil,
                    presentationTimeToleranceSeconds: nil
                ),
                OfflineExpectedOCRPipelineEvent(
                    kind: .trigger,
                    frameNumber: nil,
                    region: "manual_cell",
                    action: "buy_triggered",
                    rawText: nil,
                    normalizedText: "15",
                    symbol: nil,
                    parsedInteger: 15,
                    presentationTimeSeconds: nil,
                    presentationTimeToleranceSeconds: nil
                )
            ]
        )

        let triggerActual = [
            OCRPipelineEvent(
                kind: .trigger,
                frameNumber: 12,
                region: "manual_cell",
                action: "buy_triggered",
                rawText: "15",
                normalizedText: "15",
                confidence: 0.98,
                symbol: nil,
                parsedInteger: 15,
                isDuplicate: false,
                isZeroOrEmpty: false,
                presentationTimeSeconds: 0.8
            ),
            OCRPipelineEvent(
                kind: .trigger,
                frameNumber: 12,
                region: "manual_cell",
                action: "buy_transport_succeeded",
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
            actualRecognitionEvents: [],
            actualTriggerEvents: triggerActual
        )

        #expect(!report.matched)
        #expect(report.trigger?.matched == false)
        #expect(report.trigger?.mismatches.first?.reason == "missing_actual_event")
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
