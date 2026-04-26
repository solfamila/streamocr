import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

struct DisplayTarget: Equatable {
    let id: CGDirectDisplayID
    let title: String
    let width: Int
    let height: Int
}

final class DisplayCaptureController: NSObject, @unchecked Sendable {
    private let permissionManager: ScreenRecordingPermissionManager
    private let timingLogger: FrameTimingLogger
    private let pipeline: any FramePipeline
    private let messageSender: (any TradingMessageSending)?

    private var stream: SCStream?
    private let captureStateQueue = DispatchQueue(label: "capture-shell.capture-state")
    private var activeCaptureGeneration = 0
    private var activeStreamIdentity: ObjectIdentifier?
    private var isStoppingCapture = false
    private var displayByID: [CGDirectDisplayID: SCDisplay] = [:]
    private var activeRuntimeConfig: CaptureRuntimeConfig?
    private let runtimeConfigQueue = DispatchQueue(label: "capture-shell.runtime-config", attributes: .concurrent)

    private let sampleQueue = DispatchQueue(label: "capture-shell.samples", qos: .userInitiated)

    var onDisplaysUpdated: (([DisplayTarget]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCaptureStateChanged: ((Bool) -> Void)?

    init(
        permissionManager: ScreenRecordingPermissionManager,
        timingLogger: FrameTimingLogger,
        pipeline: any FramePipeline,
        messageSender: (any TradingMessageSending)? = nil
    ) {
        self.permissionManager = permissionManager
        self.timingLogger = timingLogger
        self.pipeline = pipeline
        self.messageSender = messageSender
    }

    @MainActor
    func setActiveRuntimeConfig(_ config: CaptureRuntimeConfig?) {
        runtimeConfigQueue.sync(flags: .barrier) {
            activeRuntimeConfig = config
        }
    }

    func requestScreenRecordingPermission() -> Bool {
        permissionManager.requestPermissionIfNeeded()
    }

    @MainActor
    func reloadDisplays() async {
        guard permissionManager.currentStatus() == .granted else {
            onStatus?("Screen Recording permission is required before loading displays.")
            onDisplaysUpdated?([])
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displays = content.displays.sorted { lhs, rhs in
                lhs.displayID < rhs.displayID
            }

            displayByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })

            let targets = displays.map { display in
                DisplayTarget(
                    id: display.displayID,
                    title: "Display \(display.displayID) (\(display.width)x\(display.height))",
                    width: display.width,
                    height: display.height
                )
            }

            onDisplaysUpdated?(targets)
        } catch {
            onDisplaysUpdated?([])
            onStatus?("Failed to fetch shareable displays: \(error.localizedDescription)")
        }
    }

    @MainActor
    func startCapture(displayID: CGDirectDisplayID) async {
        guard permissionManager.currentStatus() == .granted else {
            onStatus?("Screen Recording permission is required before starting capture.")
            return
        }

        guard let display = displayByID[displayID] else {
            onStatus?("Selected display is unavailable. Refresh the display list.")
            return
        }

        if stream != nil {
            await stopCapture()
        }

        do {
            timingLogger.reset()
            messageSender?.beginMessageSession()
            pipeline.reset()

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            activateCaptureStream(stream)

            onCaptureStateChanged?(true)
            onStatus?("Capturing display \(displayID). \(runtimeConfigStatus(for: displayID))")
        } catch {
            onStatus?("Failed to start capture: \(error.localizedDescription)")
            onCaptureStateChanged?(false)
        }
    }

    @MainActor
    func stopCapture() async {
        guard !isStoppingCapture else {
            onStatus?("Capture is already stopping and draining pending OCR trading actions.")
            return
        }

        guard let stream else {
            onCaptureStateChanged?(false)
            return
        }

        isStoppingCapture = true
        let stoppedGeneration = deactivateCaptureStream(stream)
        messageSender?.cancelPendingMessages(reason: "Display capture stopped before pending OCR trading actions completed.")
        onStatus?("Stopping capture and draining pending OCR trading actions...")

        do {
            try await stream.stopCapture()
        } catch {
            onStatus?("Capture stop error: \(error.localizedDescription)")
        }

        self.stream = nil
        pipeline.reset()
        let drained = await drainPendingMessages(timeout: 2)
        guard stoppedGeneration.map(isInactiveCaptureGenerationCurrent(_:)) ?? true else {
            isStoppingCapture = false
            return
        }
        onCaptureStateChanged?(false)
        onStatus?(drained ? "Capture stopped." : "Capture stopped. Pending OCR trading actions did not finish before timeout.")
        isStoppingCapture = false
    }

}

extension DisplayCaptureController: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else {
            return
        }
        guard isActiveCaptureStream(stream) else {
            return
        }

        timingLogger.log(sampleBuffer: sampleBuffer)
        guard let frame = VideoFrame(sampleBuffer: sampleBuffer) else {
            return
        }
        pipeline.process(frame, runtimeConfig: activeRuntimeConfigSnapshot())
    }
}

extension DisplayCaptureController: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = "Capture stopped with stream error: \(error.localizedDescription)"
        guard let stoppedGeneration = deactivateCaptureStream(stream) else {
            return
        }
        messageSender?.cancelPendingMessages(reason: "Display capture stream stopped before pending OCR trading actions completed.")
        Task { @MainActor [weak self] in
            await self?.finishStreamStoppedWithError(message: message, generation: stoppedGeneration)
        }
    }
}

private extension DisplayCaptureController {
    @discardableResult
    func activateCaptureStream(_ stream: SCStream) -> Int {
        captureStateQueue.sync {
            activeCaptureGeneration += 1
            activeStreamIdentity = ObjectIdentifier(stream)
            return activeCaptureGeneration
        }
    }

    func deactivateCaptureStream(_ stream: SCStream) -> Int? {
        let streamIdentity = ObjectIdentifier(stream)
        return captureStateQueue.sync {
            guard activeStreamIdentity == streamIdentity else {
                return nil
            }
            activeStreamIdentity = nil
            return activeCaptureGeneration
        }
    }

    func isActiveCaptureStream(_ stream: SCStream) -> Bool {
        let streamIdentity = ObjectIdentifier(stream)
        return captureStateQueue.sync {
            activeStreamIdentity == streamIdentity
        }
    }

    func isInactiveCaptureGenerationCurrent(_ generation: Int) -> Bool {
        captureStateQueue.sync {
            activeCaptureGeneration == generation && activeStreamIdentity == nil
        }
    }

    @MainActor
    func finishStreamStoppedWithError(message: String, generation: Int) async {
        guard isInactiveCaptureGenerationCurrent(generation) else {
            return
        }

        isStoppingCapture = true
        self.stream = nil
        pipeline.reset()
        let drained = await drainPendingMessages(timeout: 2)
        guard isInactiveCaptureGenerationCurrent(generation) else {
            isStoppingCapture = false
            return
        }

        onCaptureStateChanged?(false)
        let suffix = drained ? "" : " Pending OCR trading actions did not finish before timeout."
        onStatus?(message + suffix)
        isStoppingCapture = false
    }

    @MainActor
    func drainPendingMessages(timeout: TimeInterval) async -> Bool {
        guard let messageSender else {
            return true
        }

        return await Task.detached(priority: .userInitiated) {
            messageSender.waitForPendingMessages(timeout: timeout)
        }.value
    }

    func activeRuntimeConfigSnapshot() -> CaptureRuntimeConfig? {
        runtimeConfigQueue.sync {
            activeRuntimeConfig
        }
    }

    func runtimeConfigStatus(for displayID: CGDirectDisplayID) -> String {
        guard let activeRuntimeConfig = activeRuntimeConfigSnapshot() else {
            return "No runtime ROI config is active yet."
        }

        guard activeRuntimeConfig.displayID == UInt32(displayID) else {
            return "Runtime ROI config belongs to display \(activeRuntimeConfig.displayID); current capture display is \(displayID)."
        }

        return "Using runtime regions: \(activeRuntimeConfig.runtimeSummary)"
    }
}
