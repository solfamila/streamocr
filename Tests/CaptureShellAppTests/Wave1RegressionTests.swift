import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CaptureShellApp

struct TradingMessageContractTests {
    @Test
    func buyMessageMatchesContract() {
        #expect(TradingMessageContract.buyMessage(ocrQuantity: nil) == #"{"action":"BUY"}"#)
        #expect(TradingMessageContract.buyMessage(ocrQuantity: 10000) == #"{"action":"BUY","ocrQuantity":10000}"#)
        #expect(TradingMessageContract.buyMessage(ocrQuantity: 10000, symbol: "PLRZ") == #"{"action":"BUY","symbol":"PLRZ","ocrQuantity":10000}"#)

        let parsed = try? TradingMessageContract.parseBuyMessage(#"{"action":"BUY","ocrQuantity":10000}"#)
        #expect(parsed == OCRBuyMessage(ocrQuantity: 10000, symbol: nil))
        let parsedWithSymbol = try? TradingMessageContract.parseBuyMessage(#"{"action":"BUY","symbol":"PLRZ","ocrQuantity":10000}"#)
        #expect(parsedWithSymbol == OCRBuyMessage(ocrQuantity: 10000, symbol: "PLRZ"))
    }

    @Test
    func sellMessageMatchesContract() {
        let payload = TradingMessageContract.sellMessage(ocrQuantity: 25000, previousOCRQuantity: 30000)
        #expect(payload == #"{"action":"SELL","ocrQuantity":25000,"previousOCRQuantity":30000}"#)
        let symbolPayload = TradingMessageContract.sellMessage(ocrQuantity: 25000, previousOCRQuantity: 30000, symbol: "PLRZ")
        #expect(symbolPayload == #"{"action":"SELL","symbol":"PLRZ","ocrQuantity":25000,"previousOCRQuantity":30000}"#)

        let parsed = try? TradingMessageContract.parseSellMessage(payload)
        #expect(parsed == OCRSellMessage(ocrQuantity: 25000, previousOCRQuantity: 30000, symbol: nil))
        let parsedWithSymbol = try? TradingMessageContract.parseSellMessage(symbolPayload)
        #expect(parsedWithSymbol == OCRSellMessage(ocrQuantity: 25000, previousOCRQuantity: 30000, symbol: "PLRZ"))
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
    func derivesPlayablePlaylistCandidatesFromNanoplayerEmbedURL() throws {
        let seed = try #require(URL(string: "https://demo.nanocosmos.de/nanoplayer/release/nanoplayer.html?entry.rtmp.streamname=wptPV-dvBBZ&security.jwtoken=test-jwt"))

        let candidates = try NanocosmosStreamResolver.derivePlaylistCandidates(seedURL: seed)

        #expect(
            candidates.map(\.absoluteString).contains(
                "https://bintu-play.nanocosmos.de/h5live/http/playlist.m3u8?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Fbintu-play.nanocosmos.de%2Fplay&jwtoken=test-jwt"
            )
        )
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
    func derivesDirectPlaybackCandidatesFromNanoplayerEmbedURL() throws {
        let seed = try #require(URL(string: "https://demo.nanocosmos.de/nanoplayer/release/nanoplayer.html?entry.rtmp.streamname=wptPV-dvBBZ&security.jwtoken=test-jwt"))

        let candidates = try NanocosmosStreamResolver.deriveDirectPlaybackCandidates(seedURL: seed)

        #expect(
            candidates.map(\.absoluteString).contains(
                "https://bintu-play.nanocosmos.de/h5live/http/stream.mp4?stream=wptPV-dvBBZ&jwtoken=test-jwt"
            )
        )
        #expect(
            candidates.map(\.absoluteString).contains(
                "https://bintu-play.nanocosmos.de/h5live/http/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Fbintu-play.nanocosmos.de%2Fplay&jwtoken=test-jwt"
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

struct NanocosmosWebSocketFrameSourceTests {
    @Test
    func normalizedWebSocketURLRemovesCheckAndCloseFlag() throws {
        let seedURL = try #require(URL(string: "wss://bintu-h5live.nanocosmos.de:443/h5live/stream/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay&flags=checkandclose"))

        let webSocketURL = try #require(NanocosmosWebSocketFrameSource.normalizedWebSocketURL(from: seedURL))

        #expect(webSocketURL.scheme == "wss")
        #expect(webSocketURL.path == "/h5live/stream/stream.mp4")
        #expect(webSocketURL.absoluteString.contains("stream=wptPV-dvBBZ"))
        #expect(webSocketURL.absoluteString.contains("url=rtmp://localhost:1935/play"))
        #expect(!webSocketURL.absoluteString.contains("checkandclose"))
    }

    @Test
    func normalizedWebSocketURLConvertsHTTPPlaybackPath() throws {
        let seedURL = try #require(URL(string: "https://bintu-h5live.nanocosmos.de/h5live/http/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Flocalhost%3A1935%2Fplay"))

        let webSocketURL = try #require(NanocosmosWebSocketFrameSource.normalizedWebSocketURL(from: seedURL))

        #expect(webSocketURL.scheme == "wss")
        #expect(webSocketURL.host == "bintu-h5live.nanocosmos.de")
        #expect(webSocketURL.path == "/h5live/stream/stream.mp4")
        #expect(webSocketURL.absoluteString.contains("stream=wptPV-dvBBZ"))
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
    func preferredRecordingSourceURLUsesOriginalStyleCandidateForNanoplayerEmbedSeed() throws {
        let seedURL = try #require(URL(string: "https://demo.nanocosmos.de/nanoplayer/release/nanoplayer.html?entry.rtmp.streamname=wptPV-dvBBZ&security.jwtoken=test-jwt"))

        let recordingURL = LiveMediaCaptureCoordinator.preferredRecordingSourceURL(seedURL: seedURL)

        #expect(recordingURL.absoluteString == "https://bintu-play.nanocosmos.de/h5live/http/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Fbintu-play.nanocosmos.de%2Fplay&jwtoken=test-jwt")
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

    @Test
    func recordingOutputURLIncludesUniqueSuffixToAvoidSameSecondCollisions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamocr-recording-url-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let firstURL = try LiveRecordingSessionController.makeRecordingOutputURL(
            directory: directory,
            date: date,
            uniqueID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        )
        let secondURL = try LiveRecordingSessionController.makeRecordingOutputURL(
            directory: directory,
            date: date,
            uniqueID: try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        )

        #expect(firstURL.deletingLastPathComponent() == directory)
        #expect(secondURL.deletingLastPathComponent() == directory)
        #expect(firstURL.lastPathComponent != secondURL.lastPathComponent)
        #expect(firstURL.lastPathComponent.hasPrefix("live-recording-"))
        #expect(firstURL.lastPathComponent.hasSuffix("-00000000.mp4"))
        #expect(secondURL.lastPathComponent.hasSuffix("-11111111.mp4"))
    }
}

struct LiveRecordingSessionControllerTests {
    @Test
    func concurrentStartIsRejectedWhileFirstStartIsReserved() throws {
        let fakeRecorder = FakeLiveSourceRecording(blockStartUntilReleased: true)
        let outputURL = try makeTemporaryRecordingOutputURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }
        let controller = makeController(outputURL: outputURL, recorder: fakeRecorder)
        let startFinished = DispatchSemaphore(value: 0)
        let firstStartError = CapturedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try controller.start(seedURLText: Self.supportedRecordingSeedURL.absoluteString)
            } catch {
                firstStartError.set(error)
            }
            startFinished.signal()
        }

        #expect(fakeRecorder.waitForStart(timeout: 2))

        do {
            try controller.start(seedURLText: Self.supportedRecordingSeedURL.absoluteString)
            #expect(Bool(false))
        } catch LiveRecordingSessionControllerError.alreadyRecording {
        } catch {
            #expect(Bool(false))
        }

        fakeRecorder.releaseStart()
        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(firstStartError.value == nil)
        #expect(fakeRecorder.startCallCount == 1)

        _ = controller.stopAndFinishSynchronously(timeout: 2)
    }

    @Test
    func doubleStopOnlyFinalizesRecorderOnce() throws {
        let fakeRecorder = FakeLiveSourceRecording(blockFinishUntilReleased: true)
        let outputURL = try makeTemporaryRecordingOutputURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }
        let controller = makeController(outputURL: outputURL, recorder: fakeRecorder)

        try controller.start(seedURLText: Self.supportedRecordingSeedURL.absoluteString)
        controller.stop()
        #expect(fakeRecorder.waitForFinish(timeout: 2))

        controller.stop()
        #expect(fakeRecorder.finishCallCount == 1)

        fakeRecorder.releaseFinish()
        #expect(waitUntil(timeout: 2) {
            controller.currentStatusSnapshot().state == .off
        })
        #expect(fakeRecorder.finishCallCount == 1)
    }

    @Test
    func stopDuringStartingStopsAndFinalizesInsteadOfRecording() throws {
        let fakeRecorder = FakeLiveSourceRecording(blockStartUntilReleased: true)
        let outputURL = try makeTemporaryRecordingOutputURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }
        let controller = makeController(outputURL: outputURL, recorder: fakeRecorder)
        let startFinished = DispatchSemaphore(value: 0)
        let firstStartError = CapturedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try controller.start(seedURLText: Self.supportedRecordingSeedURL.absoluteString)
            } catch {
                firstStartError.set(error)
            }
            startFinished.signal()
        }

        #expect(fakeRecorder.waitForStart(timeout: 2))
        controller.stop()
        #expect(controller.currentStatusSnapshot().state == .stopping)

        fakeRecorder.releaseStart()

        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(waitUntil(timeout: 2) {
            controller.currentStatusSnapshot().state == .off
        })
        #expect(firstStartError.value == nil)
        #expect(fakeRecorder.startCallCount == 1)
        #expect(fakeRecorder.stopCallCount == 1)
        #expect(fakeRecorder.finishCallCount == 1)
    }

    @Test
    func stopAndFinishSynchronouslyWaitsForStartingRecorderToFinalize() throws {
        let fakeRecorder = FakeLiveSourceRecording(blockStartUntilReleased: true)
        let outputURL = try makeTemporaryRecordingOutputURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }
        let controller = makeController(outputURL: outputURL, recorder: fakeRecorder)
        let startFinished = DispatchSemaphore(value: 0)
        let syncFinished = DispatchSemaphore(value: 0)
        let firstStartError = CapturedErrorBox()
        let statusBox = CapturedRecordingStatusBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try controller.start(seedURLText: Self.supportedRecordingSeedURL.absoluteString)
            } catch {
                firstStartError.set(error)
            }
            startFinished.signal()
        }

        #expect(fakeRecorder.waitForStart(timeout: 2))

        DispatchQueue.global(qos: .userInitiated).async {
            let status = controller.stopAndFinishSynchronously(timeout: 2)
            statusBox.set(status)
            syncFinished.signal()
        }

        #expect(syncFinished.wait(timeout: .now() + 0.05) == .timedOut)
        fakeRecorder.releaseStart()

        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(syncFinished.wait(timeout: .now() + 2) == .success)
        #expect(firstStartError.value == nil)
        #expect(statusBox.value?.state == .off)
        #expect(controller.currentStatusSnapshot().state == .off)
        #expect(fakeRecorder.startCallCount == 1)
        #expect(fakeRecorder.stopCallCount == 1)
        #expect(fakeRecorder.finishCallCount == 1)
    }

    @Test
    func finishTimeoutKeepsControllerInStoppingUntilFinalizerCompletes() throws {
        let fakeRecorder = FakeLiveSourceRecording(blockFinishUntilReleased: true)
        let outputURL = try makeTemporaryRecordingOutputURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }
        let controller = makeController(outputURL: outputURL, recorder: fakeRecorder)

        try controller.start(seedURLText: Self.supportedRecordingSeedURL.absoluteString)
        controller.stop()
        #expect(fakeRecorder.waitForFinish(timeout: 2))

        let timedOutStatus = controller.stopAndFinishSynchronously(timeout: 0.01)
        #expect(timedOutStatus.state == .stopping)
        #expect(controller.currentStatusSnapshot().state == .stopping)

        do {
            try controller.start(seedURLText: Self.supportedRecordingSeedURL.absoluteString)
            #expect(Bool(false))
        } catch LiveRecordingSessionControllerError.alreadyRecording {
        } catch {
            #expect(Bool(false))
        }

        fakeRecorder.releaseFinish()
        #expect(waitUntil(timeout: 2) {
            controller.currentStatusSnapshot().state == .off
        })
    }

    private static let supportedRecordingSeedURL = URL(
        string: "https://bintu-play.nanocosmos.de/h5live/http/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Flocalhost%2Fplay"
    )!

    private func makeController(
        outputURL: URL,
        recorder: FakeLiveSourceRecording
    ) -> LiveRecordingSessionController {
        LiveRecordingSessionController(
            sourceURLResolver: { _ in Self.supportedRecordingSeedURL },
            outputURLProvider: { outputURL },
            recorderFactory: { _, _ in recorder }
        )
    }

    private func makeTemporaryRecordingOutputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamocr-recording-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("recording.mp4")
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    private final class FakeLiveSourceRecording: LiveSourceRecording, @unchecked Sendable {
        private let lock = NSLock()
        private let startEntered = DispatchSemaphore(value: 0)
        private let finishEntered = DispatchSemaphore(value: 0)
        private let startGate: DispatchSemaphore?
        private let finishGate: DispatchSemaphore?

        private var _startCallCount = 0
        private var _stopCallCount = 0
        private var _finishCallCount = 0

        init(
            blockStartUntilReleased: Bool = false,
            blockFinishUntilReleased: Bool = false
        ) {
            startGate = blockStartUntilReleased ? DispatchSemaphore(value: 0) : nil
            finishGate = blockFinishUntilReleased ? DispatchSemaphore(value: 0) : nil
        }

        var startCallCount: Int {
            locked { _startCallCount }
        }

        var finishCallCount: Int {
            locked { _finishCallCount }
        }

        var stopCallCount: Int {
            locked { _stopCallCount }
        }

        func start(sourceURL _: URL, runSeconds _: Double) throws {
            lock.lock()
            _startCallCount += 1
            lock.unlock()

            startEntered.signal()
            startGate?.wait()
        }

        func stop() {
            lock.lock()
            _stopCallCount += 1
            lock.unlock()
        }

        func finish(timeout _: TimeInterval) throws -> LiveRecordingSummary? {
            lock.lock()
            _finishCallCount += 1
            lock.unlock()

            finishEntered.signal()
            finishGate?.wait()
            return LiveRecordingSummary(
                outputPath: "/tmp/streamocr-fake-recording.mp4",
                frameCount: 1,
                droppedFrameCount: 0,
                width: 1,
                height: 1,
                firstPresentationTimeSeconds: 0,
                lastPresentationTimeSeconds: 0,
                durationSeconds: 0,
                fileSizeBytes: 1
            )
        }

        func waitForStart(timeout: TimeInterval) -> Bool {
            startEntered.wait(timeout: .now() + timeout) == .success
        }

        func waitForFinish(timeout: TimeInterval) -> Bool {
            finishEntered.wait(timeout: .now() + timeout) == .success
        }

        func releaseStart() {
            startGate?.signal()
        }

        func releaseFinish() {
            finishGate?.signal()
        }

        private func locked<Value>(_ body: () -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private final class CapturedErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        var value: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func set(_ error: Error) {
            lock.lock()
            storedError = error
            lock.unlock()
        }
    }

    private final class CapturedRecordingStatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedStatus: LiveRecordingStatusSnapshot?

        var value: LiveRecordingStatusSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return storedStatus
        }

        func set(_ status: LiveRecordingStatusSnapshot) {
            lock.lock()
            storedStatus = status
            lock.unlock()
        }
    }
}

struct LiveOCRSessionControllerTests {
    @Test
    func workspaceCreationFailureClearsActiveSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamocr-live-ocr-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let nonDirectoryWorkspace = directory.appendingPathComponent("not-a-directory")
        try Data("not a directory".utf8).write(to: nonDirectoryWorkspace)

        let controller = LiveOCRSessionController(
            manager: TradingRuntimeManager(),
            temporaryDirectoryProvider: { _ in nonDirectoryWorkspace }
        )

        try controller.start(
            seedURLText: "wss://bintu-play.nanocosmos.de/h5live/stream/stream.mp4?stream=wptPV-dvBBZ&url=rtmp%3A%2F%2Flocalhost%2Fplay"
        )

        #expect(waitUntil(timeout: 2) {
            controller.currentStatusSnapshot().state == .error
        })

        let drainedStatus = controller.stopAndDrain(timeout: 0.05)
        #expect(drainedStatus.state == .error)
        #expect(controller.currentStatusSnapshot().state == .error)
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
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

    @Test
    func manualCellIntegerParserRejectsAmbiguousSentinel() {
        #expect(ManualCellIntegerPolicy.parseInteger("?") == nil)
    }
}

struct FontTemplateMatcherSafetyTests {
    @Test
    func unsafeFiveSixNearTieIsRejectedForManualCellReads() {
        let decoded = FontTemplateMatcher.Decoded(
            characters: ["6"],
            perGlyphConfidences: [0.82],
            perGlyphRunnerUpCharacters: ["5"],
            perGlyphConfidenceMargins: [0.01]
        )

        #expect(decoded.hasUnsafeConfusableGlyph(minimumMargin: 0.035))
    }

    @Test
    func clearFiveSixWinnerIsAllowedForManualCellReads() {
        let decoded = FontTemplateMatcher.Decoded(
            characters: ["6"],
            perGlyphConfidences: [0.82],
            perGlyphRunnerUpCharacters: ["5"],
            perGlyphConfidenceMargins: [0.08]
        )

        #expect(!decoded.hasUnsafeConfusableGlyph(minimumMargin: 0.035))
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
    func manualCellAmbiguousReadDoesNotRearmCommittedBuy() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        let firstTrigger = stateMachine.evaluateManualCell(normalizedText: "11")
        #expect(firstTrigger.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess()

        let firstAmbiguous = stateMachine.evaluateManualCell(normalizedText: "?")
        #expect(!firstAmbiguous.isZeroOrEmpty)
        #expect(!firstAmbiguous.isArmedAfter)

        let secondAmbiguous = stateMachine.evaluateManualCell(normalizedText: "?")
        #expect(!secondAmbiguous.isZeroOrEmpty)
        #expect(!secondAmbiguous.isArmedAfter)

        let thirdAmbiguous = stateMachine.evaluateManualCell(normalizedText: "?")
        #expect(!thirdAmbiguous.isZeroOrEmpty)
        #expect(!thirdAmbiguous.isArmedAfter)

        let laterNonzero = stateMachine.evaluateManualCell(normalizedText: "22")
        #expect(!laterNonzero.shouldTriggerBuy)
        #expect(!laterNonzero.isArmedAfter)
    }

    @Test
    func manualCellTriggersSellWhenOpenPositionStartsDecreasing() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        let buy = stateMachine.evaluateManualCell(normalizedText: "10000")
        #expect(buy.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess(openPositionIntegerValue: buy.integerValue)

        let growth = stateMachine.evaluateManualCell(normalizedText: "29672")
        #expect(!growth.shouldTriggerSell)
        #expect(growth.openPositionPeakValue == 10000)

        let firstDecrease = stateMachine.evaluateManualCell(normalizedText: "25950")
        #expect(firstDecrease.shouldTriggerSell)
        #expect(firstDecrease.openPositionPeakValue == 29672)

        stateMachine.commitManualCellSellSuccess()
        let lowerAgain = stateMachine.evaluateManualCell(normalizedText: "20000")
        #expect(!lowerAgain.shouldTriggerSell)
        #expect(!lowerAgain.shouldTriggerBuy)
    }

    @Test
    func manualCellAmbiguousReadDoesNotTriggerSellFromOpenPosition() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        let buy = stateMachine.evaluateManualCell(normalizedText: "10000")
        #expect(buy.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess(openPositionIntegerValue: buy.integerValue)

        let growth = stateMachine.evaluateManualCell(normalizedText: "29672")
        #expect(!growth.shouldTriggerSell)

        let ambiguous = stateMachine.evaluateManualCell(normalizedText: "?")
        #expect(!ambiguous.shouldTriggerSell)
        #expect(!ambiguous.isZeroOrEmpty)
        #expect(!ambiguous.isArmedAfter)

        let nextSafeGrowth = stateMachine.evaluateManualCell(normalizedText: "30000")
        #expect(!nextSafeGrowth.shouldTriggerSell)

        let firstSafeDecrease = stateMachine.evaluateManualCell(normalizedText: "29999")
        #expect(firstSafeDecrease.shouldTriggerSell)
        #expect(firstSafeDecrease.openPositionPeakValue == 30000)
    }

    @Test
    func manualCellLowConfidenceDecreaseDoesNotTriggerSell() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        let buy = stateMachine.evaluateManualCell(normalizedText: "10000", confidence: 0.9)
        #expect(buy.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess(openPositionIntegerValue: buy.integerValue)

        let growth = stateMachine.evaluateManualCell(normalizedText: "29672", confidence: 0.9)
        #expect(!growth.shouldTriggerSell)

        let lowConfidenceDecrease = stateMachine.evaluateManualCell(normalizedText: "28842", confidence: 0.4)
        #expect(!lowConfidenceDecrease.shouldTriggerSell)

        let safeDecrease = stateMachine.evaluateManualCell(normalizedText: "28842", confidence: 0.8)
        #expect(safeDecrease.shouldTriggerSell)
    }

    @Test
    func manualCellDroppedDigitDecreaseDoesNotTriggerSell() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        let buy = stateMachine.evaluateManualCell(normalizedText: "10000", confidence: 0.9)
        #expect(buy.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess(openPositionIntegerValue: buy.integerValue)

        let growth = stateMachine.evaluateManualCell(normalizedText: "29672", confidence: 0.9)
        #expect(!growth.shouldTriggerSell)

        let droppedDigit = stateMachine.evaluateManualCell(normalizedText: "2947", confidence: 0.9)
        #expect(!droppedDigit.shouldTriggerSell)

        let safeDecrease = stateMachine.evaluateManualCell(normalizedText: "28842", confidence: 0.8)
        #expect(safeDecrease.shouldTriggerSell)
    }

    @Test
    func manualCellDirectDropToZeroTriggersSellBeforeRearm() {
        let stateMachine = TradingTriggerStateMachine(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1
        )

        let buy = stateMachine.evaluateManualCell(normalizedText: "10000")
        #expect(buy.shouldTriggerBuy)
        stateMachine.commitManualCellTriggerSuccess(openPositionIntegerValue: buy.integerValue)

        let zero = stateMachine.evaluateManualCell(normalizedText: "0")
        #expect(zero.shouldTriggerSell)
        #expect(zero.isZeroOrEmpty)
        #expect(!zero.isArmedAfter)
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
    func manualSymbolAllowsConfirmedChangedSymbolWithoutManualCellRearm() {
        let stateMachine = TradingTriggerStateMachine()

        let first = stateMachine.evaluateManualSymbol(normalizedText: "ms ft", confidence: 0.82)
        #expect(first.shouldTriggerSubscribe)
        #expect(first.normalizedSymbol == "MSFT")
        stateMachine.commitManualSymbolTriggerSuccess(symbol: first.normalizedSymbol)

        let second = stateMachine.evaluateManualSymbol(normalizedText: "m.s-f t", confidence: 0.82)
        #expect(!second.shouldTriggerSubscribe)
        #expect(second.isDuplicate)
        #expect(second.normalizedSymbol == "MSFT")

        let third = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.82)
        #expect(third.shouldTriggerSubscribe)
        #expect(!third.isChangedSymbolSuppressed)
        #expect(third.normalizedSymbol == "AAPL")

        stateMachine.commitManualSymbolTriggerSuccess(symbol: third.normalizedSymbol)
        let fourth = stateMachine.evaluateManualSymbol(normalizedText: "aapl", confidence: 0.82)
        #expect(!fourth.shouldTriggerSubscribe)
        #expect(fourth.isDuplicate)
    }

    @Test
    func manualSymbolChangedSymbolRequiresHigherConfidence() {
        let stateMachine = TradingTriggerStateMachine(manualSymbolTriggerConfirmationFrames: 1)

        let first = stateMachine.evaluateManualSymbol(normalizedText: "plrz", confidence: 0.82)
        #expect(first.shouldTriggerSubscribe)
        stateMachine.commitManualSymbolTriggerSuccess(symbol: first.normalizedSymbol)

        let lowConfidenceChange = stateMachine.evaluateManualSymbol(normalizedText: "plpz", confidence: 0.77)
        #expect(!lowConfidenceChange.shouldTriggerSubscribe)
        #expect(lowConfidenceChange.isChangedSymbolSuppressed)

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
                TradingMessageContract.buyMessage(ocrQuantity: 15),
                TradingMessageContract.buyMessage(ocrQuantity: 9)
            ]
        )
    }

    @Test
    func manualSymbolTransitionsEmitSubscribeForConfirmedChangedSymbol() {
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

        #expect(
            sender.messages == [
                #"{"subscribe":"MSFT"}"#,
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

        #expect(sender.messages == [TradingMessageContract.buyMessage(ocrQuantity: 15)])
        #expect(eventCollector.events.map(\.action) == ["buy_triggered"])

        sender.succeedNext()
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_succeeded"])

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "15", normalizedText: "15", confidence: 0.9)
        #expect(sender.messages == [TradingMessageContract.buyMessage(ocrQuantity: 15)])
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
        #expect(
            sender.messages == [
                TradingMessageContract.buyMessage(ocrQuantity: 15),
                TradingMessageContract.buyMessage(ocrQuantity: 15)
            ]
        )
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_failed", "buy_triggered"])

        sender.succeedNext()
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_failed", "buy_triggered", "buy_transport_succeeded"])
    }

    @Test
    func sellTriggersWhenPositionDecreasesAfterCommittedBuy() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "10000", normalizedText: "10000", confidence: 0.9)
        sender.succeedNext()
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "30000", normalizedText: "30000", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "25950", normalizedText: "25950", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "25950", normalizedText: "25950", confidence: 0.9)

        #expect(
            sender.messages == [
                TradingMessageContract.buyMessage(ocrQuantity: 10000),
                TradingMessageContract.sellMessage(ocrQuantity: 25950, previousOCRQuantity: 30000)
            ]
        )
        #expect(
            eventCollector.events.map(\.action) == [
                "buy_triggered",
                "buy_transport_succeeded",
                "sell_triggered"
            ]
        )

        sender.succeedNext()
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "20000", normalizedText: "20000", confidence: 0.9)
        #expect(
            eventCollector.events.map(\.action) == [
                "buy_triggered",
                "buy_transport_succeeded",
                "sell_triggered",
                "sell_transport_succeeded"
            ]
        )
    }

    @Test
    func sellIgnoresDroppedDigitDecreaseAndWaitsForSafeDecrease() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "10000", normalizedText: "10000", confidence: 0.9)
        sender.succeedNext()
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "29672", normalizedText: "29672", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "2947", normalizedText: "2947", confidence: 0.9)
        #expect(sender.messages == [TradingMessageContract.buyMessage(ocrQuantity: 10000)])

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "28842", normalizedText: "28842", confidence: 0.8)
        #expect(
            sender.messages == [
                TradingMessageContract.buyMessage(ocrQuantity: 10000),
                TradingMessageContract.sellMessage(ocrQuantity: 28842, previousOCRQuantity: 29672)
            ]
        )
        #expect(
            eventCollector.events.map(\.action) == [
                "buy_triggered",
                "buy_transport_succeeded",
                "sell_triggered"
            ]
        )
    }

    @Test
    func sellTransportFailureLeavesSellRetryable() {
        let sender = ControlledTransportMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 3,
            manualCellTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:)
        )

        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "10000", normalizedText: "10000", confidence: 0.9)
        sender.succeedNext()
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "30000", normalizedText: "30000", confidence: 0.9)
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "25950", normalizedText: "25950", confidence: 0.9)
        sender.failNext()
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "25950", normalizedText: "25950", confidence: 0.9)

        #expect(
            sender.messages == [
                TradingMessageContract.buyMessage(ocrQuantity: 10000),
                TradingMessageContract.sellMessage(ocrQuantity: 25950, previousOCRQuantity: 30000),
                TradingMessageContract.sellMessage(ocrQuantity: 25950, previousOCRQuantity: 30000)
            ]
        )
        #expect(
            eventCollector.events.map(\.action) == [
                "buy_triggered",
                "buy_transport_succeeded",
                "sell_triggered",
                "sell_transport_failed",
                "sell_triggered"
            ]
        )
    }

    @Test
    func firstPendingBuyWinsUntilRearmEvenIfLaterNonzeroReadsDiffer() {
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

        #expect(sender.messages == [TradingMessageContract.buyMessage(ocrQuantity: 15)])
        #expect(eventCollector.events.map(\.action) == ["buy_triggered", "buy_transport_succeeded"])
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

        #expect(sender.messages == [TradingMessageContract.buyMessage(ocrQuantity: 15)])
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
        sender.succeedNext(matchingPayload: TradingMessageContract.buyMessage(ocrQuantity: 15))
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
                TradingMessageContract.buyMessage(ocrQuantity: 15),
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
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "aapl",
            normalizedText: "AAPL",
            confidence: 0.9
        )

        #expect(sender.messages == [#"{"subscribe":"PLRZ"}"#, #"{"subscribe":"AAPL"}"#])
        #expect(
            eventCollector.events.map(\.action) == [
                "subscribe_triggered",
                "subscribe_transport_succeeded",
                "subscribe_triggered"
            ]
        )
    }

    @Test
    func committedSymbolChangeClearsManualCellPeakBeforeSellEvaluation() {
        let sender = ControlledTransportMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {}
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "spy",
            normalizedText: "SPY",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"SPY"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "30000",
            normalizedText: "30000",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: TradingMessageContract.buyMessage(ocrQuantity: 30000, symbol: "SPY"))

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "nexr",
            normalizedText: "NEXR",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"NEXR"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "25000",
            normalizedText: "25000",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: TradingMessageContract.buyMessage(ocrQuantity: 25000, symbol: "NEXR"))

        #expect(
            sender.messages == [
                #"{"subscribe":"SPY"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 30000, symbol: "SPY"),
                #"{"subscribe":"NEXR"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 25000, symbol: "NEXR")
            ]
        )
    }

    @Test
    func pendingBuyIsStaledWhenDifferentSymbolSubscribeCommits() {
        let sender = ControlledTransportMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {}
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "spy",
            normalizedText: "SPY",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"SPY"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "10000",
            normalizedText: "10000",
            confidence: 0.9
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "nexr",
            normalizedText: "NEXR",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"NEXR"}"#)
        sender.succeedNext(matchingPayload: TradingMessageContract.buyMessage(ocrQuantity: 10000, symbol: "SPY"))
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "9000",
            normalizedText: "9000",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: TradingMessageContract.buyMessage(ocrQuantity: 9000, symbol: "NEXR"))

        #expect(
            sender.messages == [
                #"{"subscribe":"SPY"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 10000, symbol: "SPY"),
                #"{"subscribe":"NEXR"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 9000, symbol: "NEXR")
            ]
        )
    }

    @Test
    func pendingSellIsStaledWhenDifferentSymbolSubscribeCommits() {
        let sender = ControlledTransportMessageSender()
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {}
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "spy",
            normalizedText: "SPY",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"SPY"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "30000",
            normalizedText: "30000",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: TradingMessageContract.buyMessage(ocrQuantity: 30000, symbol: "SPY"))
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "25000",
            normalizedText: "25000",
            confidence: 0.9
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "nexr",
            normalizedText: "NEXR",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"NEXR"}"#)
        sender.succeedNext(
            matchingPayload: TradingMessageContract.sellMessage(
                ocrQuantity: 25000,
                previousOCRQuantity: 30000,
                symbol: "SPY"
            )
        )
        pipeline.processTriggerEventForTesting(region: .manualCell, rawText: "", normalizedText: "", confidence: 0.9)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "5000",
            normalizedText: "5000",
            confidence: 0.9
        )

        #expect(
            sender.messages == [
                #"{"subscribe":"SPY"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 30000, symbol: "SPY"),
                TradingMessageContract.sellMessage(ocrQuantity: 25000, previousOCRQuantity: 30000, symbol: "SPY"),
                #"{"subscribe":"NEXR"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 5000, symbol: "NEXR")
            ]
        )
    }

    @Test
    func boundManualCellTradeRequiresCommittedOCRSymbol() {
        let sender = ControlledTransportMessageSender()
        sender.requiresCommittedOCRSymbolForManualCellTrades = true
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {}
        )

        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "10000",
            normalizedText: "10000",
            confidence: 0.9
        )
        #expect(sender.messages.isEmpty)

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "plrz",
            normalizedText: "PLRZ",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"PLRZ"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "10000",
            normalizedText: "10000",
            confidence: 0.9
        )

        #expect(
            sender.messages == [
                #"{"subscribe":"PLRZ"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 10000, symbol: "PLRZ")
            ]
        )
    }

    @Test
    func pendingSymbolSubscribeSuppressesOldSymbolManualCellTrades() {
        let sender = ControlledTransportMessageSender()
        sender.requiresCommittedOCRSymbolForManualCellTrades = true
        let pipeline = LowLatencyOCRFramePipeline(
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            messageSender: sender,
            beep: {}
        )

        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "spy",
            normalizedText: "SPY",
            confidence: 0.9
        )
        sender.succeedNext(matchingPayload: #"{"subscribe":"SPY"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualSymbolCell,
            rawText: "nexr",
            normalizedText: "NEXR",
            confidence: 0.9
        )
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "10000",
            normalizedText: "10000",
            confidence: 0.9
        )

        #expect(sender.messages == [#"{"subscribe":"SPY"}"#, #"{"subscribe":"NEXR"}"#])

        sender.succeedNext(matchingPayload: #"{"subscribe":"NEXR"}"#)
        pipeline.processTriggerEventForTesting(
            region: .manualCell,
            rawText: "10000",
            normalizedText: "10000",
            confidence: 0.9
        )

        #expect(
            sender.messages == [
                #"{"subscribe":"SPY"}"#,
                #"{"subscribe":"NEXR"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 10000, symbol: "NEXR")
            ]
        )
    }

    @Test
    func frameProcessesSymbolBeforeManualCellForBoundTrades() {
        let sender = CapturingMessageSender()
        sender.requiresCommittedOCRSymbolForManualCellTrades = true
        let recognizer = RegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "10000", confidence: 0.9),
                .manualSymbolCell: OCRTextRecognition(rawText: "PLRZ", confidence: 0.9)
            ]
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            messageSender: sender,
            beep: {}
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

        pipeline.process(VideoFrame(pixelBuffer: pixelBuffer), runtimeConfig: runtimeConfig)

        #expect(
            sender.messages == [
                #"{"subscribe":"PLRZ"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 10000, symbol: "PLRZ")
            ]
        )
    }

    @Test
    func asyncSymbolRefreshDefersManualCellForBoundTrades() {
        let sender = CapturingMessageSender()
        sender.requiresCommittedOCRSymbolForManualCellTrades = true
        let recognizer = RegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "10000", confidence: 0.9),
                .manualSymbolCell: OCRTextRecognition(rawText: "PLRZ", confidence: 0.9)
            ]
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 1,
            manualSymbolTriggerConfirmationFrames: 1,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: true,
            messageSender: sender,
            beep: {}
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

        pipeline.process(VideoFrame(pixelBuffer: pixelBuffer), runtimeConfig: runtimeConfig)

        #expect(recognizer.callCount(for: .manualCell) == 0)
        waitUntil(timeout: 1.0) {
            sender.messages == [#"{"subscribe":"PLRZ"}"#]
        }

        pipeline.process(VideoFrame(pixelBuffer: pixelBuffer), runtimeConfig: runtimeConfig)

        #expect(
            sender.messages == [
                #"{"subscribe":"PLRZ"}"#,
                TradingMessageContract.buyMessage(ocrQuantity: 10000, symbol: "PLRZ")
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

        #expect(sender.messages == [TradingMessageContract.buyMessage(ocrQuantity: 10000)])
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
        #expect(sender.messages == [TradingMessageContract.buyMessage(ocrQuantity: 10000)])
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

    @Test
    func manualSymbolForcesFreshOCRAfterMediaTimeIntervalEvenWhenFingerprintIsUnchanged() {
        let clock = TestClock(now: 0)
        let sender = CapturingMessageSender()
        let eventCollector = CapturingPipelineEventHandler()
        let recognizer = RegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "", confidence: 1.0),
                .manualSymbolCell: OCRTextRecognition(rawText: "SKLZ", confidence: 0.9)
            ]
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2,
            manualSymbolSamplingIntervalFrames: 10_000,
            manualSymbolFreshOCRIntervalSeconds: 10,
            manualSymbolTriggerConfirmationFrames: 1,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            messageSender: sender,
            beep: {},
            eventHandler: eventCollector.handle(_:),
            timeProvider: clock.current
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

        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )
        #expect(recognizer.callCount(for: .manualSymbolCell) == 1)
        #expect(sender.messages == [#"{"subscribe":"SKLZ"}"#])

        recognizer.setResult(OCRTextRecognition(rawText: "GLND", confidence: 0.9), for: .manualSymbolCell)
        clock.set(0)
        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 9.9, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )
        #expect(recognizer.callCount(for: .manualSymbolCell) == 1)

        clock.set(0)
        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 10.1, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )

        #expect(recognizer.callCount(for: .manualSymbolCell) == 2)
        #expect(sender.messages == [#"{"subscribe":"SKLZ"}"#, #"{"subscribe":"GLND"}"#])
        #expect(eventCollector.events.map(\.action).contains("ocr_resampled"))
        #expect(eventCollector.events.map(\.action).contains("subscribe_triggered"))
    }

    @Test
    func manualSymbolForcesFreshOCRWhenPresentationTimeMovesBackward() {
        let clock = TestClock(now: 0)
        let sender = CapturingMessageSender()
        let recognizer = RegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "", confidence: 1.0),
                .manualSymbolCell: OCRTextRecognition(rawText: "SKLZ", confidence: 0.9)
            ]
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualCellRearmConfirmationFrames: 1,
            manualCellTriggerConfirmationFrames: 2,
            manualSymbolSamplingIntervalFrames: 10_000,
            manualSymbolFreshOCRIntervalSeconds: 10,
            manualSymbolTriggerConfirmationFrames: 1,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            messageSender: sender,
            beep: {},
            timeProvider: clock.current
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

        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 20, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )
        #expect(recognizer.callCount(for: .manualSymbolCell) == 1)

        recognizer.setResult(OCRTextRecognition(rawText: "GLND", confidence: 0.9), for: .manualSymbolCell)
        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 5, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )

        #expect(recognizer.callCount(for: .manualSymbolCell) == 2)
        #expect(sender.messages == [#"{"subscribe":"SKLZ"}"#, #"{"subscribe":"GLND"}"#])
    }

    private final class CapturingMessageSender: TradingMessageSending, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var messages: [String] = []
        var requiresCommittedOCRSymbolForManualCellTrades = false

        func send(
            _ payload: String,
            event _: String,
            completion: @escaping @Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void
        ) {
            lock.lock()
            messages.append(payload)
            lock.unlock()
            completion(.success(.submitted))
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: CFAbsoluteTime

        init(now: CFAbsoluteTime) {
            self.now = now
        }

        func current() -> CFAbsoluteTime {
            lock.lock()
            defer { lock.unlock() }
            return now
        }

        func set(_ now: CFAbsoluteTime) {
            lock.lock()
            self.now = now
            lock.unlock()
        }
    }

    private final class ControlledTransportMessageSender: TradingMessageSending, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var messages: [String] = []
        private var pendingMessages: [PendingMessage] = []

        var reportsTransportOutcomes: Bool { true }
        var requiresCommittedOCRSymbolForManualCellTrades = false

        private struct PendingMessage {
            let payload: String
            let completion: @Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void
        }

        func send(
            _ payload: String,
            event _: String,
            completion: @escaping @Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void
        ) {
            lock.lock()
            messages.append(payload)
            pendingMessages.append(PendingMessage(payload: payload, completion: completion))
            lock.unlock()
        }

        func succeedNext() {
            resolveNext(with: .success(.submitted))
        }

        func succeedNext(matchingPayload payload: String) {
            resolveNext(matchingPayload: payload, with: .success(.submitted))
        }

        func failNext() {
            resolveNext(with: .failure(TestTransportError.sendFailed))
        }

        private func resolveNext(with result: Result<TradingMessageSendOutcome, any Error>) {
            let completion: (@Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void)?
            lock.lock()
            completion = pendingMessages.isEmpty ? nil : pendingMessages.removeFirst().completion
            lock.unlock()
            completion?(result)
        }

        private func resolveNext(matchingPayload payload: String, with result: Result<TradingMessageSendOutcome, any Error>) {
            let completion: (@Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void)?
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
        private var results: [OCRRegionKind: OCRTextRecognition]
        private var calls: [OCRRegionKind: Int] = [:]

        init(results: [OCRRegionKind: OCRTextRecognition]) {
            self.results = results
        }

        func callCount(for region: OCRRegionKind) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return calls[region, default: 0]
        }

        func setResult(_ result: OCRTextRecognition, for region: OCRRegionKind) {
            lock.lock()
            results[region] = result
            lock.unlock()
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

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(condition())
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

struct SymbolTemplateMetalMatcherTests {
    private enum StopAfterEnoughRealCrops: Error {
        case done
    }

    @Test
    func metalSymbolDecoderMatchesCPUDecoderForSyntheticSymbols() throws {
        guard let matcher = SymbolTemplateMetalMatcher.make() else {
            return
        }
        let templates = try #require(FontTemplateSet.make(targetHeight: 88, options: .symbolCell))

        for symbol in ["PLRZ", "PLPZ"] {
            let mask = try makeSymbolMask(symbol, templates: templates)
            let cpu = FontTemplateMatcher.decode(mask: mask, templates: templates, options: .symbolCell)
            let metal = try #require(
                FontTemplateMatcher.decodeSymbolWithMetal(
                    mask: mask,
                    templates: templates,
                    options: .symbolCell,
                    matcher: matcher
                )
            )

            #expect(String(cpu.characters) == symbol)
            #expect(String(metal.characters) == String(cpu.characters))
            #expect(metal.perGlyphConfidences.count == cpu.perGlyphConfidences.count)
            for index in cpu.perGlyphConfidences.indices {
                #expect(abs(cpu.perGlyphConfidences[index] - metal.perGlyphConfidences[index]) < 0.0001)
            }
        }

        let blank = BinaryMask(
            width: 64,
            height: templates.bitmapHeight,
            pixels: Array(repeating: 0, count: 64 * templates.bitmapHeight)
        )
        let cpuBlank = FontTemplateMatcher.decode(mask: blank, templates: templates, options: .symbolCell)
        let metalBlank = try #require(
            FontTemplateMatcher.decodeSymbolWithMetal(
                mask: blank,
                templates: templates,
                options: .symbolCell,
                matcher: matcher
            )
        )
        #expect(cpuBlank.characters.isEmpty)
        #expect(metalBlank.characters.isEmpty)
    }

    @Test
    func symbolRecognizerFallsBackToCPUWhenMetalMatcherIsUnavailable() throws {
        let templates = try #require(FontTemplateSet.make(targetHeight: 88, options: .symbolCell))
        let mask = try makeSymbolMask("PLRZ", templates: templates)
        let pixelBuffer = try makePixelBuffer(from: mask)

        let recognizer = FontTemplateTextRecognizer(symbolMetalMatcher: nil)
        let recognition = recognizer.recognizeText(in: pixelBuffer, region: .manualSymbolCell)

        #expect(recognition.rawText == "PLRZ")
        #expect(recognition.confidence > 0.75)
    }

    @Test
    func metalSymbolRecognizerMatchesCPUOnDistortedSymbolCrops() throws {
        guard let matcher = SymbolTemplateMetalMatcher.make() else {
            return
        }
        let templates = try #require(FontTemplateSet.make(targetHeight: 88, options: .symbolCell))
        let base = try makeSymbolMask("PLRZ", templates: templates)
        let shifted = embedMask(base, paddingX: 7, paddingY: 5, offsetX: 4, offsetY: 3)
        let scaled = embedMask(
            resizeMask(base, width: Int(Double(base.width) * 1.08), height: Int(Double(base.height) * 0.96)),
            paddingX: 5,
            paddingY: 7,
            offsetX: 2,
            offsetY: 4
        )

        let cases: [(String, CVPixelBuffer)] = [
            ("shifted", try makePixelBuffer(from: shifted)),
            ("scaled", try makePixelBuffer(from: scaled)),
            (
                "subthreshold-background-noise",
                try makePixelBuffer(from: shifted, foregroundValue: 185, backgroundValue: 38, backgroundNoiseValue: 124)
            ),
            ("low-contrast", try makePixelBuffer(from: shifted, foregroundValue: 178, backgroundValue: 44))
        ]
        let cpuRecognizer = FontTemplateTextRecognizer(symbolMetalMatcher: nil)
        let metalRecognizer = FontTemplateTextRecognizer(symbolMetalMatcher: matcher)

        for (name, pixelBuffer) in cases {
            let cpu = cpuRecognizer.recognizeText(in: pixelBuffer, region: .manualSymbolCell)
            let metal = metalRecognizer.recognizeText(in: pixelBuffer, region: .manualSymbolCell)

            #expect(cpu.rawText == "PLRZ", "CPU failed distorted symbol case \(name)")
            #expect(metal.rawText == cpu.rawText, "Metal diverged from CPU for distorted symbol case \(name)")
            #expect(abs(cpu.confidence - metal.confidence) < 0.15, "Metal confidence diverged for \(name)")
        }
    }

    @Test
    func metalSymbolRecognizerMatchesCPUOnRealPLRZVideoCropsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["OCR_REAL_CROP_PARITY"] == "1" else {
            return
        }
        guard let videoPath = ProcessInfo.processInfo.environment["OCR_REAL_CROP_VIDEO"],
              !videoPath.isEmpty else {
            #expect(Bool(false), "Set OCR_REAL_CROP_VIDEO to run OCR_REAL_CROP_PARITY=1.")
            return
        }
        let videoURL = URL(fileURLWithPath: videoPath)
        #expect(FileManager.default.fileExists(atPath: videoURL.path), "Missing real PLRZ video fixture at \(videoURL.path)")
        guard FileManager.default.fileExists(atPath: videoURL.path),
              let matcher = SymbolTemplateMetalMatcher.make() else {
            return
        }

        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/offline/runtime-config.plrz-positions.json")
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(CaptureRuntimeConfig.self, from: data)
        let preprocessor = OCRRegionPreprocessor(ciContext: CIContext(options: [.cacheIntermediates: false]))
        let cpuRecognizer = FontTemplateTextRecognizer(symbolMetalMatcher: nil)
        let metalRecognizer = FontTemplateTextRecognizer(symbolMetalMatcher: matcher)
        var checkedCrops = 0

        do {
            _ = try LocalVideoFrameDecoder().decode(
                videoURL: videoURL,
                maximumFrameCount: 600,
                allowsPartialDecode: true
            ) { frame in
                let adjusted = config.adjustedForFrameSize(width: frame.width, height: frame.height)
                guard let roi = adjusted.manualSymbolCellROI,
                      let crop = preprocessor.preprocess(
                        sourcePixelBuffer: frame.pixelBuffer,
                        roi: roi,
                        region: .manualSymbolCell
                      )
                else {
                    return
                }

                let cpu = cpuRecognizer.recognizeText(in: crop.pixelBuffer, region: .manualSymbolCell)
                guard cpu.rawText == "PLRZ" || cpu.rawText == "PLPZ" else {
                    return
                }
                let metal = metalRecognizer.recognizeText(in: crop.pixelBuffer, region: .manualSymbolCell)

                #expect(metal.rawText == cpu.rawText, "Metal diverged from CPU on real PLRZ crop")
                #expect(abs(cpu.confidence - metal.confidence) < 0.15, "Metal confidence diverged on real PLRZ crop")
                checkedCrops += 1
                if checkedCrops >= 12 {
                    throw StopAfterEnoughRealCrops.done
                }
            }
        } catch StopAfterEnoughRealCrops.done {
        }

        #expect(checkedCrops > 0, "No recognizable PLRZ/PLPZ symbol crops found in real video fixture.")
    }

    @Test
    func benchmarkSymbolRecognitionCPUVersusMetalWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["OCR_SYMBOL_BENCHMARK"] == "1" else {
            return
        }
        guard let matcher = SymbolTemplateMetalMatcher.make() else {
            print("[benchmark] Symbol Metal matcher unavailable; skipping CPU-vs-Metal comparison.")
            return
        }

        let templates = try #require(FontTemplateSet.make(targetHeight: 88, options: .symbolCell))
        let mask = try makeSymbolMask("PLRZ", templates: templates)
        let pixelBuffer = try makePixelBuffer(from: mask)
        let iterations = max(
            1,
            Int(ProcessInfo.processInfo.environment["OCR_SYMBOL_BENCHMARK_ITERATIONS"] ?? "") ?? 500
        )
        let cpuRecognizer = FontTemplateTextRecognizer(symbolMetalMatcher: nil)
        let metalRecognizer = FontTemplateTextRecognizer(symbolMetalMatcher: matcher)

        _ = cpuRecognizer.recognizeText(in: pixelBuffer, region: .manualSymbolCell)
        _ = metalRecognizer.recognizeText(in: pixelBuffer, region: .manualSymbolCell)

        var cpuLast = ""
        let cpuStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            cpuLast = cpuRecognizer.recognizeText(in: pixelBuffer, region: .manualSymbolCell).rawText
        }
        let cpuElapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - cpuStart) / 1_000_000_000

        var metalLast = ""
        let metalStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            metalLast = metalRecognizer.recognizeText(in: pixelBuffer, region: .manualSymbolCell).rawText
        }
        let metalElapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - metalStart) / 1_000_000_000

        #expect(cpuLast == "PLRZ")
        #expect(metalLast == cpuLast)
        print(
            String(
                format: "[benchmark] manualSymbolCell iterations=%d cpu=%.1f recognitions/sec metal=%.1f recognitions/sec",
                iterations,
                Double(iterations) / max(cpuElapsedSeconds, .leastNonzeroMagnitude),
                Double(iterations) / max(metalElapsedSeconds, .leastNonzeroMagnitude)
            )
        )
    }

    private func makeSymbolMask(_ symbol: String, templates: FontTemplateSet) throws -> BinaryMask {
        let glyphs = try symbol.map { character in
            try #require(templates.glyphTemplates[character])
        }
        let gap = 2
        let width = glyphs.reduce(0) { $0 + $1.width } + max(0, glyphs.count - 1) * gap
        let height = templates.bitmapHeight
        var pixels = Array(repeating: UInt8(0), count: width * height)
        var xOffset = 0

        for glyph in glyphs {
            for y in 0..<glyph.height {
                let targetY = glyph.yOffset + y
                guard targetY >= 0, targetY < height else {
                    continue
                }
                for x in 0..<glyph.width where glyph.mask[y * glyph.width + x] == 1 {
                    pixels[targetY * width + xOffset + x] = 1
                }
            }
            xOffset += glyph.width + gap
        }

        return BinaryMask(width: width, height: height, pixels: pixels)
    }

    private func embedMask(
        _ mask: BinaryMask,
        paddingX: Int,
        paddingY: Int,
        offsetX: Int,
        offsetY: Int
    ) -> BinaryMask {
        let width = mask.width + paddingX * 2
        let height = mask.height + paddingY * 2
        var pixels = Array(repeating: UInt8(0), count: width * height)
        for y in 0..<mask.height {
            let targetY = paddingY + offsetY + y
            guard targetY >= 0, targetY < height else {
                continue
            }
            for x in 0..<mask.width where mask.pixels[y * mask.width + x] == 1 {
                let targetX = paddingX + offsetX + x
                guard targetX >= 0, targetX < width else {
                    continue
                }
                pixels[targetY * width + targetX] = 1
            }
        }
        return BinaryMask(width: width, height: height, pixels: pixels)
    }

    private func resizeMask(_ mask: BinaryMask, width: Int, height: Int) -> BinaryMask {
        let width = max(1, width)
        let height = max(1, height)
        var pixels = Array(repeating: UInt8(0), count: width * height)
        for y in 0..<height {
            let sourceY = min(mask.height - 1, Int((Double(y) / Double(height)) * Double(mask.height)))
            for x in 0..<width {
                let sourceX = min(mask.width - 1, Int((Double(x) / Double(width)) * Double(mask.width)))
                pixels[y * width + x] = mask.pixels[sourceY * mask.width + sourceX]
            }
        }
        return BinaryMask(width: width, height: height, pixels: pixels)
    }

    private func makePixelBuffer(
        from mask: BinaryMask,
        foregroundValue: UInt8 = 255,
        backgroundValue: UInt8 = 0,
        backgroundNoiseValue: UInt8? = nil
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            mask.width,
            mask.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let unwrapped = try #require(pixelBuffer)

        CVPixelBufferLockBaseAddress(unwrapped, [])
        defer { CVPixelBufferUnlockBaseAddress(unwrapped, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(unwrapped)
        let pointer = try #require(CVPixelBufferGetBaseAddress(unwrapped)?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<mask.height {
            let row = pointer.advanced(by: y * bytesPerRow)
            for x in 0..<mask.width {
                let isForeground = mask.pixels[y * mask.width + x] == 1
                let isNoisePixel = (x + y * 3).isMultiple(of: 23)
                let value: UInt8 = if isForeground {
                    foregroundValue
                } else if let backgroundNoiseValue, isNoisePixel {
                    backgroundNoiseValue
                } else {
                    backgroundValue
                }
                row[x * 4] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 255
            }
        }

        return unwrapped
    }
}
