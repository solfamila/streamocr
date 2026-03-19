import Foundation

enum OfflineAnalysisCommand {
    static func runIfRequested(arguments: [String]) -> Int? {
        guard arguments.contains("--offline-analyze") else {
            return nil
        }

        do {
            let request = try parse(arguments: arguments)
            let result = try OfflineVideoAnalyzer().analyze(
                videoURL: request.videoURL,
                runtimeConfigURL: request.runtimeConfigURL,
                expectedOutputURL: request.expectedOutputURL
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)

            if let resultURL = request.resultURL {
                try data.write(to: resultURL, options: .atomic)
            } else if let text = String(data: data, encoding: .utf8) {
                print(text)
            }

            if request.strictVerify, let verification = result.verification, !verification.matched {
                return 2
            }

            return 0
        } catch {
            fputs("offline analysis failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func parse(arguments: [String]) throws -> OfflineAnalysisRequest {
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

        guard let videoPath = value(for: "--video") else {
            throw OfflineAnalysisCommandError.missingArgument("--video")
        }

        guard let runtimeConfigPath = value(for: "--runtime-config") else {
            throw OfflineAnalysisCommandError.missingArgument("--runtime-config")
        }

        return OfflineAnalysisRequest(
            videoURL: URL(fileURLWithPath: videoPath),
            runtimeConfigURL: URL(fileURLWithPath: runtimeConfigPath),
            expectedOutputURL: value(for: "--expected-output").map { URL(fileURLWithPath: $0) },
            resultURL: value(for: "--result-json").map { URL(fileURLWithPath: $0) },
            strictVerify: arguments.contains("--strict-verify")
        )
    }
}

private struct OfflineAnalysisRequest {
    let videoURL: URL
    let runtimeConfigURL: URL
    let expectedOutputURL: URL?
    let resultURL: URL?
    let strictVerify: Bool
}

private enum OfflineAnalysisCommandError: Error, LocalizedError {
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            return "Missing required argument \(flag). Example: --offline-analyze --video /path/input.mp4 --runtime-config /path/runtime-config.json"
        }
    }
}
