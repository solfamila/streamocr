import CoreMedia

protocol FramePipeline: Sendable {
    func reset()
    func process(_ frame: VideoFrame, runtimeConfig: CaptureRuntimeConfig?)
}

struct NoOpFramePipeline: FramePipeline {
    func reset() {}

    func process(_ frame: VideoFrame, runtimeConfig: CaptureRuntimeConfig?) {
        // Wave 1 intentionally forwards frames without OCR or trigger logic.
        _ = frame
        _ = runtimeConfig
    }
}
