import CoreMedia
import CoreVideo
import Foundation

struct VideoFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTimeStamp: CMTime?
    let nominalFrameRate: Double?

    init(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime? = nil,
        nominalFrameRate: Double? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.nominalFrameRate = nominalFrameRate
    }

    init?(sampleBuffer: CMSampleBuffer, nominalFrameRate: Double? = nil) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        self.init(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            nominalFrameRate: nominalFrameRate
        )
    }

    var width: Int {
        CVPixelBufferGetWidth(pixelBuffer)
    }

    var height: Int {
        CVPixelBufferGetHeight(pixelBuffer)
    }

    var presentationTimeSeconds: Double? {
        guard let presentationTimeStamp else {
            return nil
        }
        let seconds = CMTimeGetSeconds(presentationTimeStamp)
        return seconds.isFinite ? max(0, seconds) : nil
    }

    var sizeSummary: String {
        "\(width)x\(height)"
    }
}
