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
