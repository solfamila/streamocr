import Foundation

enum LiveSourceStreamRecorderError: Error, LocalizedError {
    case ffmpegLaunchFailed(String)
    case ffmpegProcessFailed(String)
    case ffmpegTimedOut(String)

    var errorDescription: String? {
        switch self {
        case let .ffmpegLaunchFailed(message):
            return "Failed to launch ffmpeg source recorder: \(message)"
        case let .ffmpegProcessFailed(message):
            return "ffmpeg source recorder failed: \(message)"
        case let .ffmpegTimedOut(message):
            return "Timed out waiting for ffmpeg source recorder: \(message)"
        }
    }
}

final class LiveSourceStreamRecorder {
    private let outputURL: URL
    private let includeAudio: Bool
    private let loggingEnabled: Bool
    private let stderr = Pipe()
    private var process: Process?

    init(outputURL: URL, includeAudio: Bool, loggingEnabled: Bool) {
        self.outputURL = outputURL
        self.includeAudio = includeAudio
        self.loggingEnabled = loggingEnabled
    }

    func start(sourceURL: URL, runSeconds: Double) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Self.recordArguments(
            sourceURL: sourceURL,
            outputURL: outputURL,
            includeAudio: includeAudio,
            loggingEnabled: loggingEnabled,
            runSeconds: runSeconds
        )
        process.standardOutput = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw LiveSourceStreamRecorderError.ffmpegLaunchFailed(error.localizedDescription)
        }

        self.process = process
    }

    func finish(timeout: TimeInterval) throws -> LiveRecordingSummary? {
        guard let process else {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        if !process.isRunning {
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                process.interrupt()
            }
            self.process = nil
            throw LiveSourceStreamRecorderError.ffmpegTimedOut(outputURL.path)
        }

        self.process = nil

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderrText.isEmpty ? "terminationStatus=\(process.terminationStatus)" : stderrText
            throw LiveSourceStreamRecorderError.ffmpegProcessFailed(message)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            return nil
        }

        return Self.probeSummary(outputURL: outputURL, loggingEnabled: loggingEnabled)
    }

    static func recordArguments(
        sourceURL: URL,
        outputURL: URL,
        includeAudio: Bool,
        loggingEnabled: Bool,
        runSeconds: Double
    ) -> [String] {
        var arguments = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel", loggingEnabled ? "info" : "error",
            "-rw_timeout", "5000000",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "2",
            "-fflags", "+genpts",
            "-t", String(format: "%.3f", max(0.05, runSeconds)),
            "-i", sourceURL.absoluteString,
            "-map", "0:v:0",
        ]

        if includeAudio {
            arguments += ["-map", "0:a:0?"]
        } else {
            arguments += ["-an"]
        }

        arguments += [
            "-sn",
            "-dn",
            "-c:v", "copy",
        ]
        if includeAudio {
            arguments += ["-c:a", "copy"]
        }
        arguments += [
            "-movflags", "+faststart",
            "-avoid_negative_ts", "make_zero",
            outputURL.path
        ]
        return arguments
    }

    static func estimatedFrameCount(
        nbFramesText: String?,
        avgFrameRateText: String?,
        durationSeconds: Double?
    ) -> Int {
        if let nbFrames = nbFramesText.flatMap(Int.init), nbFrames > 0 {
            return nbFrames
        }

        guard
            let durationSeconds,
            durationSeconds > 0,
            let fps = LiveFFmpegVideoDecoder.parseFrameRate(avgFrameRateText),
            fps > 0
        else {
            return 0
        }

        return max(0, Int((durationSeconds * fps).rounded()))
    }

    private static func probeSummary(outputURL: URL, loggingEnabled: Bool) -> LiveRecordingSummary {
        let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value
        let fallback = LiveRecordingSummary(
            outputPath: outputURL.path,
            frameCount: 0,
            droppedFrameCount: 0,
            width: 0,
            height: 0,
            firstPresentationTimeSeconds: nil,
            lastPresentationTimeSeconds: nil,
            durationSeconds: nil,
            fileSizeBytes: fileSizeBytes
        )

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe",
            "-v", "error",
            "-print_format", "json",
            "-show_entries", "stream=width,height,avg_frame_rate,nb_frames,start_time,duration:format=duration,size",
            outputURL.path
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            if loggingEnabled {
                print("[live] ffprobe_summary_failed launch_error=\"\(error.localizedDescription)\"")
            }
            return fallback
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if loggingEnabled {
                let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "terminationStatus=\(process.terminationStatus)"
                print("[live] ffprobe_summary_failed error=\"\(errorText)\"")
            }
            return fallback
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: stdout.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        else {
            return fallback
        }

        let stream = (object["streams"] as? [[String: Any]])?.first
        let format = object["format"] as? [String: Any]
        let width = stream?["width"] as? Int ?? 0
        let height = stream?["height"] as? Int ?? 0
        let startTime = parseDouble(stream?["start_time"])
        let durationSeconds = parseDouble(stream?["duration"]) ?? parseDouble(format?["duration"])
        let avgFrameRateText = stream?["avg_frame_rate"] as? String
        let nbFramesText = stringify(stream?["nb_frames"])
        let frameCount = estimatedFrameCount(
            nbFramesText: nbFramesText,
            avgFrameRateText: avgFrameRateText,
            durationSeconds: durationSeconds
        )
        let lastPresentationTimeSeconds: Double? = {
            guard let durationSeconds else { return nil }
            return max(0, (startTime ?? 0) + durationSeconds)
        }()

        return LiveRecordingSummary(
            outputPath: outputURL.path,
            frameCount: frameCount,
            droppedFrameCount: 0,
            width: width,
            height: height,
            firstPresentationTimeSeconds: startTime,
            lastPresentationTimeSeconds: lastPresentationTimeSeconds,
            durationSeconds: durationSeconds,
            fileSizeBytes: parseInt64(format?["size"]) ?? fileSizeBytes
        )
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    private static func parseInt64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let text as String:
            return Int64(text)
        default:
            return nil
        }
    }

    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
