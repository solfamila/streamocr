import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CaptureShellApp

struct LowLatencyOCRFramePipelineObservationTests {
    @Test
    func symbolFingerprintChangeStartsOCRBetweenSamplingFrames() {
        let recognizer = ObservationRegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "", confidence: 1.0),
                .manualSymbolCell: OCRTextRecognition(rawText: "SKLZ", confidence: 0.9)
            ]
        )
        let observations = ObservationCapture()
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualSymbolSamplingIntervalFrames: 10_000,
            manualSymbolFreshOCRIntervalSeconds: 999,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            frameObservationHandler: observations.handle(_:)
        )
        let runtimeConfig = observationRuntimeConfig(width: 48, height: 48)

        pipeline.process(
            VideoFrame(
                pixelBuffer: makeObservationSolidPixelBuffer(width: 48, height: 48, fillValue: 0),
                presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )

        recognizer.setResult(
            OCRTextRecognition(rawText: "GLND", confidence: 0.9),
            for: .manualSymbolCell
        )
        pipeline.process(
            VideoFrame(
                pixelBuffer: makeObservationSolidPixelBuffer(width: 48, height: 48, fillValue: 240),
                presentationTimeStamp: CMTime(seconds: 0.033, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )

        #expect(recognizer.callCount(for: .manualSymbolCell) == 2)
        #expect(observations.symbolStates(forFrame: 2) == [.recognized])
        #expect(observations.recognizedSymbols(forFrame: 2) == ["GLND"])
    }

    @Test
    func unchangedSymbolBetweenSamplingFramesDoesNotReplayCachedRecognitionEveryFrame() {
        let recognizer = ObservationRegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "", confidence: 1.0),
                .manualSymbolCell: OCRTextRecognition(rawText: "SKLZ", confidence: 0.9)
            ]
        )
        let observations = ObservationCapture()
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualSymbolSamplingIntervalFrames: 10_000,
            manualSymbolFreshOCRIntervalSeconds: 999,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            frameObservationHandler: observations.handle(_:)
        )
        let pixelBuffer = makeObservationSolidPixelBuffer(width: 48, height: 48, fillValue: 0)
        let runtimeConfig = observationRuntimeConfig(width: 48, height: 48)

        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )
        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 0.033, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )

        #expect(recognizer.callCount(for: .manualSymbolCell) == 1)
        #expect(observations.symbolStates(forFrame: 2) == [.unchanged])
        #expect(observations.recognizedSymbols(forFrame: 2).isEmpty)
    }

    @Test
    func missingSymbolROIEmitsNotConfiguredObservation() {
        let recognizer = ObservationRegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "10000", confidence: 0.9),
                .manualSymbolCell: OCRTextRecognition(rawText: "PLRZ", confidence: 0.9)
            ]
        )
        let observations = ObservationCapture()
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            frameObservationHandler: observations.handle(_:)
        )
        let runtimeConfig = CaptureRuntimeConfig(
            displayID: 0,
            displayWidth: 48,
            displayHeight: 48,
            baseROI: PixelRect(x: 0, y: 0, width: 48, height: 48),
            manualCellROI: PixelRect(x: 0, y: 0, width: 48, height: 48),
            symbolROI: nil,
            manualSymbolCellROI: nil
        )

        pipeline.process(
            VideoFrame(
                pixelBuffer: makeObservationSolidPixelBuffer(width: 48, height: 48, fillValue: 0),
                presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )

        #expect(observations.symbolStates(forFrame: 1) == [.notConfigured])
        #expect(recognizer.callCount(for: .manualSymbolCell) == 0)
    }

    @Test
    func pipelineFeedsCoordinatorRuntimeWithFrameObservations() {
        let executor = ObservationImmediateCommandExecutor()
        let runtimeEvents = ObservationPipelineEventCapture()
        let runtime = OCRTradingCoordinatorRuntime(
            coordinator: OCRTradingCoordinator(manualSymbolTriggerConfirmationFrames: 1),
            executor: executor,
            eventHandler: runtimeEvents.handle(_:)
        )
        let recognizer = ObservationRegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "10000", confidence: 0.9),
                .manualSymbolCell: OCRTextRecognition(rawText: "PLRZ", confidence: 0.9)
            ]
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualSymbolSamplingIntervalFrames: 10_000,
            manualSymbolFreshOCRIntervalSeconds: 999,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            frameObservationHandler: runtime.handle(_:)
        )
        runtime.beginSession(1)
        let pixelBuffer = makeObservationSolidPixelBuffer(width: 48, height: 48, fillValue: 0)
        let runtimeConfig = observationRuntimeConfig(width: 48, height: 48)

        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )
        waitUntil {
            executor.commandSnapshot.count == 1 &&
                runtime.stateSnapshot.symbol.stableSymbol == "PLRZ"
        }

        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 0.033, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )
        waitUntil {
            executor.commandSnapshot.count == 2 &&
                runtime.stateSnapshot.manual.openPositionPeakValue == 10000
        }

        #expect(executor.commandSnapshot.map(\.kind) == [
            .subscribe,
            .buy(ocrQuantity: 10000, submittedQuantity: 10000)
        ])
        #expect(runtimeEvents.actions == ["subscribe_triggered", "buy_triggered"])
    }

    @Test
    func defaultModeEmitsFrameObservations() {
        let observations = ObservationCapture()
        let recognizer = ObservationRegionAwareCountingTextRecognizer(
            results: [
                .manualCell: OCRTextRecognition(rawText: "10000", confidence: 0.9),
                .manualSymbolCell: OCRTextRecognition(rawText: "PLRZ", confidence: 0.9)
            ]
        )
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: false,
            frameObservationHandler: observations.handle(_:)
        )

        pipeline.process(
            VideoFrame(pixelBuffer: makeObservationSolidPixelBuffer(width: 48, height: 48, fillValue: 0)),
            runtimeConfig: observationRuntimeConfig(width: 48, height: 48)
        )

        #expect(observations.recognizedSymbols(forFrame: 1) == ["PLRZ"])
        #expect(observations.fullObservations(forFrame: 1).contains { observation in
            observation.symbol?.recognitionState == .recognized &&
                observation.manualCell?.recognition.normalizedText == "10000"
        })
    }

    @Test
    func asyncSymbolReplayEmitsDeferredFrameObservation() {
        let observations = ObservationCapture()
        let recognizer = ObservationBlockingSymbolRecognizer(symbolText: "PLRZ")
        let pipeline = LowLatencyOCRFramePipeline(
            loggingEnabled: false,
            manualSymbolSamplingIntervalFrames: 10_000,
            manualSymbolFreshOCRIntervalSeconds: 999,
            recognizer: recognizer,
            symbolRecognizer: recognizer,
            asyncSymbolRecognitionEnabled: true,
            frameObservationHandler: observations.handle(_:)
        )
        let pixelBuffer = makeObservationSolidPixelBuffer(width: 48, height: 48, fillValue: 0)
        let runtimeConfig = observationRuntimeConfig(width: 48, height: 48)

        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )
        #expect(recognizer.waitUntilSymbolRecognitionStarted(timeout: 1))

        pipeline.process(
            VideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(seconds: 0.033, preferredTimescale: 600)
            ),
            runtimeConfig: runtimeConfig
        )

        recognizer.releaseSymbolRecognition()
        waitUntil {
            observations.recognizedSymbols(forFrame: 2) == ["PLRZ"]
        }
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

    private final class ObservationCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [OCRTradingFrameObservation] = []

        func handle(_ observation: OCRTradingFrameObservation) {
            lock.lock()
            observations.append(observation)
            lock.unlock()
        }

        func symbolStates(forFrame frameNumber: Int) -> [OCRTradingRecognitionState] {
            lock.lock()
            defer { lock.unlock() }
            return observations.compactMap { observation in
                guard observation.frameNumber == frameNumber else {
                    return nil
                }
                return observation.symbol?.recognitionState
            }
        }

        func recognizedSymbols(forFrame frameNumber: Int) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return observations.compactMap { observation in
                guard
                    observation.frameNumber == frameNumber,
                    observation.symbol?.recognitionState == .recognized
                else {
                    return nil
                }
                return observation.symbol?.recognition?.normalizedText
            }
        }

        func fullObservations(forFrame frameNumber: Int) -> [OCRTradingFrameObservation] {
            lock.lock()
            defer { lock.unlock() }
            return observations.filter { $0.frameNumber == frameNumber }
        }
    }

    private final class ObservationPipelineEventCapture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [OCRPipelineEvent] = []

        var actions: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events.map(\.action)
        }

        func handle(_ event: OCRPipelineEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
    }

    private final class ObservationImmediateCommandExecutor: OCRTradingCommandExecuting, @unchecked Sendable {
        private let queue = DispatchQueue(label: "capture-shell.tests.observation-command-executor")
        private var commands: [OCRTradingCommand] = []

        var commandSnapshot: [OCRTradingCommand] {
            queue.sync { commands }
        }

        func execute(_ command: OCRTradingCommand) async -> OCRTradingCommandResult {
            queue.sync {
                commands.append(command)
            }
            return .submitted
        }
    }

    private final class ObservationRegionAwareCountingTextRecognizer: OCRTextRecognizing, @unchecked Sendable {
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

    private final class ObservationBlockingSymbolRecognizer: OCRTextRecognizing, @unchecked Sendable {
        private let symbolText: String
        private let started = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)

        init(symbolText: String) {
            self.symbolText = symbolText
        }

        func waitUntilSymbolRecognitionStarted(timeout: TimeInterval) -> Bool {
            started.wait(timeout: .now() + timeout) == .success
        }

        func releaseSymbolRecognition() {
            release.signal()
        }

        func recognizeText(in pixelBuffer: CVPixelBuffer, region: OCRRegionKind) -> OCRTextRecognition {
            _ = pixelBuffer
            switch region {
            case .manualCell:
                return OCRTextRecognition(rawText: "", confidence: 1)
            case .manualSymbolCell:
                started.signal()
                _ = release.wait(timeout: .now() + 1)
                return OCRTextRecognition(rawText: symbolText, confidence: 0.9)
            }
        }
    }
}

private func observationRuntimeConfig(width: Int, height: Int) -> CaptureRuntimeConfig {
    CaptureRuntimeConfig(
        displayID: 0,
        displayWidth: width,
        displayHeight: height,
        baseROI: PixelRect(x: 0, y: 0, width: width, height: height),
        manualCellROI: PixelRect(x: 0, y: 0, width: width, height: height),
        symbolROI: PixelRect(x: 0, y: 0, width: width, height: height),
        manualSymbolCellROI: PixelRect(x: 0, y: 0, width: width, height: height)
    )
}

private func makeObservationSolidPixelBuffer(width: Int, height: Int, fillValue: UInt8) -> CVPixelBuffer {
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
