import CoreMedia
import Foundation

enum FrameTimingPolicy {
    static func deltaMilliseconds(currentPTS: CMTime, previousPTS: CMTime?) -> Double {
        guard let previousPTS else {
            return 0
        }

        let delta = CMTimeSubtract(currentPTS, previousPTS)
        return max(0, CMTimeGetSeconds(delta) * 1_000)
    }

    static func shouldLog(frameCount: Int) -> Bool {
        frameCount == 1 || frameCount.isMultiple(of: 30)
    }
}

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

        let deltaMilliseconds = FrameTimingPolicy.deltaMilliseconds(currentPTS: pts, previousPTS: lastPTS)

        self.lastPTS = pts

        // Keep logging light: one line every 30 frames with both instantaneous and rolling rates.
        if FrameTimingPolicy.shouldLog(frameCount: frameCount) {
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
