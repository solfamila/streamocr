import CoreMedia

protocol FramePipeline: Sendable {
    func reset()
    func process(_ sampleBuffer: CMSampleBuffer, runtimeConfig: CaptureRuntimeConfig?)
}

struct NoOpFramePipeline: FramePipeline {
    func reset() {}

    func process(_ sampleBuffer: CMSampleBuffer, runtimeConfig: CaptureRuntimeConfig?) {
        // Wave 1 intentionally forwards frames without OCR or trigger logic.
    }
}
