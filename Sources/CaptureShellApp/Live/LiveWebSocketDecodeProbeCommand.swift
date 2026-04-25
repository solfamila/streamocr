import Foundation

enum LiveWebSocketDecodeProbeCommand {
    static func runIfRequested(arguments: [String]) -> Int? {
        guard arguments.contains("--live-wss-decode-probe") else {
            return nil
        }

        do {
            let request = try parse(arguments: arguments)
            guard let webSocketURL = NanocosmosWebSocketFrameSource.normalizedWebSocketURL(from: request.seedURL) else {
                throw LiveWebSocketDecodeProbeCommandError.invalidSeedURL(request.seedURL)
            }

            var firstFrameSize: String?
            let summary = try NanocosmosWebSocketFrameSource().decode(
                webSocketURL: webSocketURL,
                runSeconds: request.runSeconds,
                maximumFrames: request.maximumFrames,
                loggingEnabled: request.verbose
            ) { frame in
                firstFrameSize = firstFrameSize ?? frame.sizeSummary
            }

            let result = LiveWebSocketDecodeProbeResult(
                seedURL: request.seedURL.absoluteString,
                webSocketURL: summary.webSocketURL.absoluteString,
                elapsedSeconds: summary.elapsedSeconds,
                textMessageCount: summary.textMessageCount,
                binaryMessageCount: summary.binaryMessageCount,
                binaryByteCount: summary.binaryByteCount,
                decodedFrameCount: summary.decodedFrameCount,
                firstFrameSize: firstFrameSize,
                firstBinaryElapsedSeconds: summary.firstBinaryElapsedSeconds,
                firstMediaElapsedSeconds: summary.firstMediaElapsedSeconds,
                firstFrameElapsedSeconds: summary.firstFrameElapsedSeconds
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }

            return 0
        } catch {
            fputs("live WSS decode probe failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func parse(arguments: [String]) throws -> LiveWebSocketDecodeProbeRequest {
        let indexedArguments = Array(arguments.enumerated())

        func value(for flag: String) -> String? {
            guard let entry = indexedArguments.first(where: { $0.element == flag }) else {
                return nil
            }
            let nextIndex = entry.offset + 1
            guard indexedArguments.indices.contains(nextIndex) else {
                return nil
            }
            return indexedArguments[nextIndex].element
        }

        guard let seedText = value(for: "--seed-url"), let seedURL = URL(string: seedText) else {
            throw LiveWebSocketDecodeProbeCommandError.missingArgument("--seed-url")
        }

        let runSeconds: Double
        if let runSecondsText = value(for: "--run-seconds") {
            guard let parsed = Double(runSecondsText), parsed > 0 else {
                throw LiveWebSocketDecodeProbeCommandError.invalidNumber("--run-seconds", runSecondsText)
            }
            runSeconds = parsed
        } else {
            runSeconds = 4
        }

        let maximumFrames: Int?
        if let maximumFramesText = value(for: "--max-frames") {
            guard let parsed = Int(maximumFramesText), parsed > 0 else {
                throw LiveWebSocketDecodeProbeCommandError.invalidNumber("--max-frames", maximumFramesText)
            }
            maximumFrames = parsed
        } else {
            maximumFrames = nil
        }

        return LiveWebSocketDecodeProbeRequest(
            seedURL: seedURL,
            runSeconds: runSeconds,
            maximumFrames: maximumFrames,
            verbose: arguments.contains("--verbose")
        )
    }
}

private struct LiveWebSocketDecodeProbeRequest {
    let seedURL: URL
    let runSeconds: Double
    let maximumFrames: Int?
    let verbose: Bool
}

private struct LiveWebSocketDecodeProbeResult: Codable {
    let seedURL: String
    let webSocketURL: String
    let elapsedSeconds: Double
    let textMessageCount: Int
    let binaryMessageCount: Int
    let binaryByteCount: Int
    let decodedFrameCount: Int
    let firstFrameSize: String?
    let firstBinaryElapsedSeconds: Double?
    let firstMediaElapsedSeconds: Double?
    let firstFrameElapsedSeconds: Double?
}

private enum LiveWebSocketDecodeProbeCommandError: Error, LocalizedError {
    case missingArgument(String)
    case invalidNumber(String, String)
    case invalidSeedURL(URL)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            return "Missing required argument \(flag). Example: --live-wss-decode-probe --seed-url 'wss://...' --run-seconds 4"
        case let .invalidNumber(flag, value):
            return "Invalid \(flag) value '\(value)'. Use a positive number."
        case let .invalidSeedURL(url):
            return "Could not derive a Nanocosmos WSS stream URL from \(url.absoluteString)"
        }
    }
}
