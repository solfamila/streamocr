import CoreMedia

protocol FramePipeline: Sendable {
    func process(_ sampleBuffer: CMSampleBuffer)
}

struct NoOpFramePipeline: FramePipeline {
    func process(_ sampleBuffer: CMSampleBuffer) {
        // Wave 1 intentionally forwards frames without OCR or trigger logic.
    }
}
