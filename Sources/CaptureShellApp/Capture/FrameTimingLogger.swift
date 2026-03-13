import CoreMedia
import Foundation

final class FrameTimingLogger {
    private var lastPTS: CMTime?
    private var frameCount: Int = 0
    private var windowStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    func reset() {
        lastPTS = nil
        frameCount = 0
        windowStart = CFAbsoluteTimeGetCurrent()
    }

    func log(sampleBuffer: CMSampleBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        frameCount += 1

        let deltaMilliseconds: Double
        if let lastPTS {
            let delta = CMTimeSubtract(pts, lastPTS)
            deltaMilliseconds = max(0, CMTimeGetSeconds(delta) * 1_000)
        } else {
            deltaMilliseconds = 0
        }

        self.lastPTS = pts

        // Keep logging light: one line every 30 frames with both instantaneous and rolling rates.
        if frameCount == 1 || frameCount.isMultiple(of: 30) {
            let elapsed = max(now - windowStart, 0.000_1)
            let rollingFPS = Double(frameCount) / elapsed
            let instantFPS = deltaMilliseconds > 0 ? 1_000 / deltaMilliseconds : 0

            print(
                String(
                    format: "[capture] frame=%d delta_ms=%.2f instant_fps=%.1f rolling_fps=%.1f",
                    frameCount,
                    deltaMilliseconds,
                    instantFPS,
                    rollingFPS
                )
            )
        }
    }
}
