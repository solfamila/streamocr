import Foundation

enum LiveAnalysisCommand {
    static func runIfRequested(arguments: [String]) -> Int? {
        guard arguments.contains("--live-analyze") else {
            return nil
        }

        do {
            let request = try parse(arguments: arguments)
            let result = try LiveStreamAnalyzer().analyze(
                seedURL: request.seedURL,
                runtimeConfigURL: request.runtimeConfigURL,
                runSeconds: request.runSeconds,
                pollFPS: request.pollFPS,
                loggingEnabled: request.verbose,
                recordVideoURL: request.recordVideoURL,
                metadataURL: request.metadataURL
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)

            if let resultURL = request.resultURL {
                try data.write(to: resultURL, options: .atomic)
            } else if let text = String(data: data, encoding: .utf8) {
                print(text)
            }

            return 0
        } catch {
            fputs("live analysis failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func parse(arguments: [String]) throws -> LiveAnalysisRequest {
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
            throw LiveAnalysisCommandError.missingArgument("--seed-url")
        }

        let runSeconds: Double
        if let runSecondsText = value(for: "--run-seconds") {
            guard let parsed = Double(runSecondsText), parsed > 0 else {
                throw LiveAnalysisCommandError.invalidNumber("--run-seconds", runSecondsText)
            }
            runSeconds = parsed
        } else {
            runSeconds = 5
        }

        let pollFPS: Double
        if let pollFPSText = value(for: "--poll-fps") {
            guard let parsed = Double(pollFPSText), parsed > 0 else {
                throw LiveAnalysisCommandError.invalidNumber("--poll-fps", pollFPSText)
            }
            pollFPS = parsed
        } else {
            pollFPS = 60
        }

        let recordVideoURL = value(for: "--record-video").map { URL(fileURLWithPath: $0) }
        if arguments.contains("--record-audio") {
            throw LiveAnalysisCommandError.removedRecordAudioFlag
        }
        let explicitMetadataURL = value(for: "--live-metadata-json").map { URL(fileURLWithPath: $0) }
        let metadataURL = explicitMetadataURL ?? recordVideoURL.map(defaultMetadataURL(for:))

        return LiveAnalysisRequest(
            seedURL: seedURL,
            runtimeConfigURL: value(for: "--runtime-config").map { URL(fileURLWithPath: $0) },
            resultURL: value(for: "--result-json").map { URL(fileURLWithPath: $0) },
            recordVideoURL: recordVideoURL,
            metadataURL: metadataURL,
            runSeconds: runSeconds,
            pollFPS: pollFPS,
            verbose: arguments.contains("--verbose")
        )
    }

    private static func defaultMetadataURL(for recordingURL: URL) -> URL {
        let directory = recordingURL.deletingLastPathComponent()
        let fileName = recordingURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(fileName).metadata.json")
    }
}

private struct LiveAnalysisRequest {
    let seedURL: URL
    let runtimeConfigURL: URL?
    let resultURL: URL?
    let recordVideoURL: URL?
    let metadataURL: URL?
    let runSeconds: Double
    let pollFPS: Double
    let verbose: Bool
}

private enum LiveAnalysisCommandError: Error, LocalizedError {
    case missingArgument(String)
    case invalidNumber(String, String)
    case removedRecordAudioFlag

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            return "Missing required argument \(flag). Example: --live-analyze --seed-url 'wss://...' --run-seconds 5 --runtime-config /path/runtime-config.json --record-video /tmp/live.mp4"
        case let .invalidNumber(flag, value):
            return "Invalid \(flag) value '\(value)'. Use a positive number."
        case .removedRecordAudioFlag:
            return "--record-audio was removed. Source recording now preserves source audio automatically; use --record-video /path/output.mp4 only."
        }
    }
}
