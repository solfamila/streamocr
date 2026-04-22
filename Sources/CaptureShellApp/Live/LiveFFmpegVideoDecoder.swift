import CoreMedia
import CoreVideo
import Foundation

enum LiveFFmpegVideoDecoderError: Error, LocalizedError {
    case ffmpegStreamInfoTimedOut(URL)
    case invalidStreamInfo(URL)
    case ffmpegLaunchFailed(String)
    case ffmpegFailed(String)
    case noFramesDecoded(URL)

    var errorDescription: String? {
        switch self {
        case let .ffmpegStreamInfoTimedOut(url):
            return "Timed out waiting for ffmpeg to describe the live stream: \(url.absoluteString)"
        case let .invalidStreamInfo(url):
            return "Could not determine frame size for \(url.absoluteString)"
        case let .ffmpegLaunchFailed(message):
            return "Failed to launch ffmpeg live decoder: \(message)"
        case let .ffmpegFailed(message):
            return "ffmpeg live decoder failed: \(message)"
        case let .noFramesDecoded(url):
            return "ffmpeg connected but decoded no frames: \(url.absoluteString)"
        }
    }
}

struct LiveFFmpegDecodedFrameStats: Sendable {
    let frameCount: Int
    let width: Int
    let height: Int
    let nominalFrameRate: Double
}

final class LiveFFmpegVideoDecoder {
    private let sourceURL: URL
    private let loggingEnabled: Bool

    init(sourceURL: URL, loggingEnabled: Bool) {
        self.sourceURL = sourceURL
        self.loggingEnabled = loggingEnabled
    }

    func decode(
        until runDeadline: Date,
        onFrame: (VideoFrame) throws -> Void
    ) throws -> LiveFFmpegDecodedFrameStats {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stderrMonitor = FFmpegDecoderStderrMonitor()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Self.ffmpegArguments(
            for: sourceURL,
            loggingEnabled: loggingEnabled
        )
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw LiveFFmpegVideoDecoderError.ffmpegLaunchFailed(error.localizedDescription)
        }

        let stdoutHandle = outputPipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrMonitor.append(data)
        }

        guard let streamInfo = stderrMonitor.waitForStreamInfo(timeout: 6) else {
            Self.stop(process: process)
            stderrHandle.readabilityHandler = nil
            throw LiveFFmpegVideoDecoderError.ffmpegStreamInfoTimedOut(sourceURL)
        }

        let frameByteCount = streamInfo.width * streamInfo.height * 4
        var didTerminateAtDeadline = false
        var didTerminateForStall = false
        var frameCount = 0
        var firstFrameArrivalUptime: TimeInterval?

        let deadlineWorkItem = DispatchWorkItem {
            didTerminateAtDeadline = true
            Self.stop(process: process)
        }
        let stallQueue = DispatchQueue(label: "live.ffmpeg.decoder.watchdog")
        var stallWorkItem: DispatchWorkItem?

        func armStallWatchdog(interval: TimeInterval) {
            stallWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                didTerminateForStall = true
                Self.stop(process: process)
            }
            stallWorkItem = workItem
            stallQueue.asyncAfter(deadline: .now() + interval, execute: workItem)
        }

        let remainingRunSeconds = max(0.05, runDeadline.timeIntervalSinceNow)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + remainingRunSeconds,
            execute: deadlineWorkItem
        )
        armStallWatchdog(interval: 8)

        defer {
            deadlineWorkItem.cancel()
            stallWorkItem?.cancel()
            stderrHandle.readabilityHandler = nil
            Self.stop(process: process)
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        while true {
            guard let frameData = try Self.readExactBytes(
                count: frameByteCount,
                from: stdoutHandle
            ) else {
                break
            }

            let arrivalUptime = ProcessInfo.processInfo.systemUptime
            if firstFrameArrivalUptime == nil {
                firstFrameArrivalUptime = arrivalUptime
            }
            let arrivalSeconds = max(0, arrivalUptime - (firstFrameArrivalUptime ?? arrivalUptime))
            let frame = try Self.makeVideoFrame(
                from: frameData,
                width: streamInfo.width,
                height: streamInfo.height,
                arrivalSeconds: arrivalSeconds,
                nominalFrameRate: streamInfo.nominalFrameRate
            )
            try onFrame(frame)
            frameCount += 1
            armStallWatchdog(interval: 1.5)
        }

        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil
        stderrMonitor.append(stderrHandle.readDataToEndOfFile())
        let stderrText = stderrMonitor.text()

        if frameCount == 0 {
            if didTerminateAtDeadline || didTerminateForStall {
                throw LiveFFmpegVideoDecoderError.noFramesDecoded(sourceURL)
            }
            if !stderrText.isEmpty {
                throw LiveFFmpegVideoDecoderError.ffmpegFailed(stderrText)
            }
            throw LiveFFmpegVideoDecoderError.noFramesDecoded(sourceURL)
        }

        if process.terminationStatus != 0,
           !didTerminateAtDeadline,
           !didTerminateForStall,
           !stderrText.isEmpty {
            throw LiveFFmpegVideoDecoderError.ffmpegFailed(stderrText)
        }

        return LiveFFmpegDecodedFrameStats(
            frameCount: frameCount,
            width: streamInfo.width,
            height: streamInfo.height,
            nominalFrameRate: streamInfo.nominalFrameRate
        )
    }

    static func preferredSourceURLs(seedURL: URL, resolved: ResolvedLiveStream) -> [URL] {
        let reorderedDirectCandidates = preferredDirectSourceURLs(seedURL: seedURL)
        return deduplicatedURLs(
            reorderedDirectCandidates + [resolved.streamURL, resolved.playbackURL, resolved.playlistURL] + resolved.alternatePlaybackURLs
        )
    }

    static func preferredDirectSourceURLs(seedURL: URL) -> [URL] {
        let directCandidates = (try? NanocosmosStreamResolver.deriveDirectPlaybackCandidates(seedURL: seedURL)) ?? []
        if let originalStyleCandidate = directCandidates.first(where: { $0.absoluteString.contains("url=") }) {
            return [originalStyleCandidate] + directCandidates.filter { $0 != originalStyleCandidate }
        }
        return directCandidates
    }

    static func parseFrameRate(_ value: String?) -> Double? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0/0" else {
            return nil
        }

        if let direct = Double(trimmed), direct > 0 {
            return direct
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              numerator > 0,
              denominator > 0
        else {
            return nil
        }

        let fps = numerator / denominator
        return fps > 0 ? fps : nil
    }

    static func streamInfo(fromFFmpegLog text: String) -> FFmpegVideoStreamInfo? {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseStreamInfoLine(String($0)) }
            .first
    }

    private static func ffmpegArguments(for sourceURL: URL, loggingEnabled: Bool) -> [String] {
        let logLevel = loggingEnabled ? "info" : "info"
        return [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-loglevel", logLevel,
            "-rw_timeout", "5000000",
            // Nanocosmos startup improved noticeably with a modest probe budget
            // plus genpts, without regressing steady-state decode in our tests.
            "-fflags", "nobuffer+genpts",
            "-flags", "low_delay",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "2",
            "-analyzeduration", "1000000",
            "-probesize", "500000",
            "-hwaccel", "videotoolbox",
            "-i", sourceURL.absoluteString,
            "-map", "0:v:0",
            "-an",
            "-sn",
            "-dn",
            "-vsync", "0",
            "-pix_fmt", "bgra",
            "-f", "rawvideo",
            "pipe:1"
        ]
    }

    private static func readExactBytes(count: Int, from handle: FileHandle) throws -> Data? {
        var data = Data()
        data.reserveCapacity(count)

        while data.count < count {
            let remaining = count - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                return data.isEmpty ? nil : nil
            }
            data.append(chunk)
        }

        return data
    }

    private static func makeVideoFrame(
        from data: Data,
        width: Int,
        height: Int,
        arrivalSeconds: Double,
        nominalFrameRate: Double
    ) throws -> VideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw LiveFFmpegVideoDecoderError.invalidStreamInfo(URL(fileURLWithPath: "pixel-buffer-create"))
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw LiveFFmpegVideoDecoderError.invalidStreamInfo(URL(fileURLWithPath: "pixel-buffer-base-address"))
        }

        let sourceBytesPerRow = width * 4
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        data.withUnsafeBytes { rawBuffer in
            guard let sourceBaseAddress = rawBuffer.baseAddress else {
                return
            }
            if destinationBytesPerRow == sourceBytesPerRow {
                memcpy(baseAddress, sourceBaseAddress, data.count)
                return
            }

            for row in 0..<height {
                let sourceOffset = row * sourceBytesPerRow
                let destinationOffset = row * destinationBytesPerRow
                memcpy(
                    baseAddress.advanced(by: destinationOffset),
                    sourceBaseAddress.advanced(by: sourceOffset),
                    sourceBytesPerRow
                )
            }
        }

        let presentationTimeStamp = CMTime(seconds: max(0, arrivalSeconds), preferredTimescale: 60_000)
        return VideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            nominalFrameRate: nominalFrameRate
        )
    }

    private static func parseStreamInfoLine(_ line: String) -> FFmpegVideoStreamInfo? {
        guard line.contains("Video:") else {
            return nil
        }

        guard
            let dimensionMatch = line.range(
                of: #"\b([0-9]{2,5})x([0-9]{2,5})\b"#,
                options: .regularExpression
            )
        else {
            return nil
        }

        let dimensions = String(line[dimensionMatch])
            .split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              let width = Int(dimensions[0]),
              let height = Int(dimensions[1]),
              width > 0,
              height > 0
        else {
            return nil
        }

        let fpsMatch = line.range(
            of: #"([0-9]+(?:\.[0-9]+)?)\s+fps\b"#,
            options: .regularExpression
        )
        let nominalFrameRate = fpsMatch.flatMap {
            let fpsToken = String(line[$0]).replacingOccurrences(of: " fps", with: "")
            return Double(fpsToken)
        } ?? 60

        return FFmpegVideoStreamInfo(
            width: width,
            height: height,
            nominalFrameRate: nominalFrameRate
        )
    }

    private static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for url in urls where seen.insert(url.absoluteString).inserted {
            result.append(url)
        }
        return result
    }

    private static func stop(process: Process) {
        guard process.isRunning else {
            return
        }

        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

struct FFmpegVideoStreamInfo: Sendable {
    let width: Int
    let height: Int
    let nominalFrameRate: Double
}

private final class FFmpegDecoderStderrMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()
    private var streamInfo: FFmpegVideoStreamInfo?
    private var didSignalInfo = false
    private let infoSemaphore = DispatchSemaphore(value: 0)

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        collectedData.append(data)
        if streamInfo == nil,
           let text = String(data: collectedData, encoding: .utf8),
           let parsed = LiveFFmpegVideoDecoder.streamInfo(fromFFmpegLog: text) {
            streamInfo = parsed
            if !didSignalInfo {
                didSignalInfo = true
                infoSemaphore.signal()
            }
        }
        lock.unlock()
    }

    func waitForStreamInfo(timeout: TimeInterval) -> FFmpegVideoStreamInfo? {
        lock.lock()
        if let streamInfo {
            lock.unlock()
            return streamInfo
        }
        lock.unlock()

        guard infoSemaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        return streamInfo
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: collectedData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
