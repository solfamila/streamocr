import AppKit
import AVFoundation
import Foundation

@MainActor
enum OfflineROISelectionCommand {
    static func runIfRequested(arguments: [String]) -> Int? {
        guard arguments.contains("--offline-select-roi") else {
            return nil
        }

        do {
            let request = try parse(arguments: arguments)
            let summary = try selectAndSave(request: request)
            print(summary)
            return 0
        } catch ROISelectionError.cancelled {
            fputs("offline ROI selection cancelled\n", stderr)
            return 2
        } catch let error as ROISelectionError {
            fputs("offline ROI selection failed: \(error.message)\n", stderr)
            return 1
        } catch {
            fputs("offline ROI selection failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func parse(arguments: [String]) throws -> OfflineROISelectionRequest {
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
            throw OfflineROISelectionCommandError.missingArgument("--video")
        }

        guard let outputPath = value(for: "--output-runtime-config") else {
            throw OfflineROISelectionCommandError.missingArgument("--output-runtime-config")
        }

        let atSeconds: Double
        if let secondsText = value(for: "--at-seconds") {
            guard let parsed = Double(secondsText), parsed >= 0 else {
                throw OfflineROISelectionCommandError.invalidSeconds(secondsText)
            }
            atSeconds = parsed
        } else {
            atSeconds = 0
        }

        return OfflineROISelectionRequest(
            videoURL: URL(fileURLWithPath: videoPath),
            atSeconds: atSeconds,
            outputRuntimeConfigURL: URL(fileURLWithPath: outputPath),
            initialConfigURL: value(for: "--initial-config").map { URL(fileURLWithPath: $0) },
            includeSymbol: arguments.contains("--include-symbol"),
            symbolFirst: arguments.contains("--symbol-first")
        )
    }

    private static func selectAndSave(request: OfflineROISelectionRequest) throws -> String {
        let frame = try copyFrame(videoURL: request.videoURL, atSeconds: request.atSeconds)
        let frameTitle = "\(request.videoURL.lastPathComponent) @ \(String(format: "%.3f", frame.actualSeconds))s"
        let initialConfig = try request.initialConfigURL
            .map { try RuntimeConfigFileIO.load(from: $0) }
            .map { $0.adjustedForFrameSize(width: frame.image.width, height: frame.image.height, displayID: 0) }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let selector = ROISelector()
        let symbolSelection: (roi: PixelRect?, cell: PixelRect?)
        let numericSelection: (baseROI: PixelRect, manualCellROI: PixelRect)

        if request.symbolFirst {
            symbolSelection = try request.includeSymbol
                ? selectSymbolROI(
                    with: selector,
                    frameImage: frame.image,
                    frameTitle: frameTitle,
                    initialConfig: initialConfig
                )
                : (roi: nil, cell: nil)
            numericSelection = try selectNumericROI(
                with: selector,
                frameImage: frame.image,
                frameTitle: frameTitle,
                initialConfig: initialConfig
            )
        } else {
            numericSelection = try selectNumericROI(
                with: selector,
                frameImage: frame.image,
                frameTitle: frameTitle,
                initialConfig: initialConfig
            )
            symbolSelection = try request.includeSymbol
                ? selectSymbolROI(
                    with: selector,
                    frameImage: frame.image,
                    frameTitle: frameTitle,
                    initialConfig: initialConfig
                )
                : (roi: nil, cell: nil)
        }

        let config = CaptureRuntimeConfig(
            version: 1,
            displayID: 0,
            displayWidth: frame.image.width,
            displayHeight: frame.image.height,
            baseROI: numericSelection.baseROI,
            manualCellROI: numericSelection.manualCellROI,
            symbolROI: symbolSelection.roi,
            manualSymbolCellROI: symbolSelection.cell
        )

        try save(config, to: request.outputRuntimeConfigURL)
        return "saved \(frame.image.width)x\(frame.image.height) ROI config to \(request.outputRuntimeConfigURL.path)"
    }

    private static func copyFrame(videoURL: URL, atSeconds: Double) throws -> (image: CGImage, actualSeconds: Double) {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let requestedTime = CMTime(seconds: atSeconds, preferredTimescale: 600)
        var actualTime = CMTime.zero
        let image = try generator.copyCGImage(at: requestedTime, actualTime: &actualTime)
        let actualSeconds = actualTime.isNumeric ? actualTime.seconds : atSeconds
        return (image, actualSeconds)
    }

    private static func save(_ config: CaptureRuntimeConfig, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    private static func selectSymbolROI(
        with selector: ROISelector,
        frameImage: CGImage,
        frameTitle: String,
        initialConfig: CaptureRuntimeConfig?
    ) throws -> (roi: PixelRect, cell: PixelRect) {
        let symbolROI = try selector.selectRect(
            on: frameImage,
            frameTitle: frameTitle,
            prompt: "Select the symbol base ROI",
            initialRect: initialConfig?.symbolROI
        )

        let symbolCellROI = try selector.selectRect(
            on: frameImage,
            frameTitle: frameTitle,
            prompt: "Select the symbol cell inside the Symbol base ROI",
            initialRect: initialConfig?.manualSymbolCellROI,
            context: ROISelectionContext(parentRect: symbolROI, label: "Symbol base ROI")
        )

        return (symbolROI, symbolCellROI)
    }

    private static func selectNumericROI(
        with selector: ROISelector,
        frameImage: CGImage,
        frameTitle: String,
        initialConfig: CaptureRuntimeConfig?
    ) throws -> (baseROI: PixelRect, manualCellROI: PixelRect) {
        let baseROI = try selector.selectRect(
            on: frameImage,
            frameTitle: frameTitle,
            prompt: "Select the number base ROI",
            initialRect: initialConfig?.baseROI
        )

        let manualCellROI = try selector.selectRect(
            on: frameImage,
            frameTitle: frameTitle,
            prompt: "Select the number cell inside the Number base ROI",
            initialRect: initialConfig?.manualCellROI,
            context: ROISelectionContext(parentRect: baseROI, label: "Number base ROI")
        )

        return (baseROI, manualCellROI)
    }
}

private struct OfflineROISelectionRequest {
    let videoURL: URL
    let atSeconds: Double
    let outputRuntimeConfigURL: URL
    let initialConfigURL: URL?
    let includeSymbol: Bool
    let symbolFirst: Bool
}

private enum OfflineROISelectionCommandError: Error, LocalizedError {
    case missingArgument(String)
    case invalidSeconds(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            return "Missing required argument \(flag). Example: --offline-select-roi --video /path/input.mp4 --at-seconds 1 --output-runtime-config /path/runtime-config.json"
        case let .invalidSeconds(value):
            return "Invalid --at-seconds value '\(value)'. Use a non-negative decimal number."
        }
    }
}
