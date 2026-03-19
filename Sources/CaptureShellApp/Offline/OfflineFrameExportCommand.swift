import AppKit
import AVFoundation
import Foundation

enum OfflineFrameExportCommand {
    static func runIfRequested(arguments: [String]) -> Int? {
        guard arguments.contains("--offline-export-frame") else {
            return nil
        }

        do {
            let request = try parse(arguments: arguments)
            let summary = try exportFrame(
                videoURL: request.videoURL,
                atSeconds: request.atSeconds,
                outputURL: request.outputURL
            )
            print(summary)
            return 0
        } catch {
            fputs("offline frame export failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func parse(arguments: [String]) throws -> OfflineFrameExportRequest {
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
            throw OfflineFrameExportCommandError.missingArgument("--video")
        }

        guard let secondsText = value(for: "--at-seconds") else {
            throw OfflineFrameExportCommandError.missingArgument("--at-seconds")
        }

        guard let outputPath = value(for: "--output-png") else {
            throw OfflineFrameExportCommandError.missingArgument("--output-png")
        }

        guard let atSeconds = Double(secondsText), atSeconds >= 0 else {
            throw OfflineFrameExportCommandError.invalidSeconds(secondsText)
        }

        return OfflineFrameExportRequest(
            videoURL: URL(fileURLWithPath: videoPath),
            atSeconds: atSeconds,
            outputURL: URL(fileURLWithPath: outputPath)
        )
    }

    private static func exportFrame(videoURL: URL, atSeconds: Double, outputURL: URL) throws -> String {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let requestedTime = CMTime(seconds: atSeconds, preferredTimescale: 600)
        var actualTime = CMTime.zero
        let image = try generator.copyCGImage(at: requestedTime, actualTime: &actualTime)

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw OfflineFrameExportCommandError.pngEncodeFailed(outputURL)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL, options: .atomic)

        let actualSeconds = actualTime.isNumeric ? actualTime.seconds : atSeconds
        return "exported \(image.width)x\(image.height) frame at \(String(format: "%.3f", actualSeconds))s to \(outputURL.path)"
    }
}

private struct OfflineFrameExportRequest {
    let videoURL: URL
    let atSeconds: Double
    let outputURL: URL
}

private enum OfflineFrameExportCommandError: Error, LocalizedError {
    case missingArgument(String)
    case invalidSeconds(String)
    case pngEncodeFailed(URL)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            return "Missing required argument \(flag). Example: --offline-export-frame --video /path/input.mp4 --at-seconds 12.5 --output-png /tmp/reference.png"
        case let .invalidSeconds(value):
            return "Invalid --at-seconds value '\(value)'. Use a non-negative decimal number."
        case let .pngEncodeFailed(url):
            return "Failed to encode exported frame as PNG for \(url.path)."
        }
    }
}
