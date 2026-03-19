import CoreGraphics
import Foundation

struct PixelRect: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Int(rect.origin.x.rounded(.towardZero))
        self.y = Int(rect.origin.y.rounded(.towardZero))
        self.width = Int(rect.size.width.rounded(.towardZero))
        self.height = Int(rect.size.height.rounded(.towardZero))
    }

    var summary: String {
        "x=\(x) y=\(y) w=\(width) h=\(height)"
    }

    func clamped(maxWidth: Int, maxHeight: Int) -> PixelRect? {
        guard maxWidth > 0, maxHeight > 0 else {
            return nil
        }

        let clampedX = min(max(0, x), maxWidth - 1)
        let clampedY = min(max(0, y), maxHeight - 1)

        let maximumWidth = maxWidth - clampedX
        let maximumHeight = maxHeight - clampedY
        let clampedWidth = min(max(1, width), maximumWidth)
        let clampedHeight = min(max(1, height), maximumHeight)

        return PixelRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    func scaled(from sourceSize: CGSize, to targetSize: CGSize) -> PixelRect {
        guard sourceSize.width > 0, sourceSize.height > 0, targetSize.width > 0, targetSize.height > 0 else {
            return self
        }

        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height

        let scaled = PixelRect(
            x: Int((CGFloat(x) * scaleX).rounded(.towardZero)),
            y: Int((CGFloat(y) * scaleY).rounded(.towardZero)),
            width: max(1, Int((CGFloat(width) * scaleX).rounded())),
            height: max(1, Int((CGFloat(height) * scaleY).rounded()))
        )

        return scaled.clamped(maxWidth: Int(targetSize.width), maxHeight: Int(targetSize.height)) ?? scaled
    }
}

struct CaptureRuntimeConfig: Codable, Equatable, Sendable {
    var version: Int
    var displayID: UInt32
    var displayWidth: Int
    var displayHeight: Int
    var baseROI: PixelRect
    var manualCellROI: PixelRect
    var symbolROI: PixelRect?
    var manualSymbolCellROI: PixelRect?

    init(
        version: Int = 1,
        displayID: UInt32,
        displayWidth: Int,
        displayHeight: Int,
        baseROI: PixelRect,
        manualCellROI: PixelRect,
        symbolROI: PixelRect?,
        manualSymbolCellROI: PixelRect?
    ) {
        self.version = version
        self.displayID = displayID
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.baseROI = baseROI
        self.manualCellROI = manualCellROI
        self.symbolROI = symbolROI
        self.manualSymbolCellROI = manualSymbolCellROI
    }

    func adjustedForDisplay(_ display: DisplayTarget) -> CaptureRuntimeConfig {
        adjustedForFrameSize(width: display.width, height: display.height, displayID: UInt32(display.id))
    }

    func adjustedForFrameSize(width: Int, height: Int, displayID: UInt32? = nil) -> CaptureRuntimeConfig {
        guard displayWidth > 0, displayHeight > 0, (displayWidth != width || displayHeight != height) else {
            return CaptureRuntimeConfig(
                version: version,
                displayID: displayID ?? self.displayID,
                displayWidth: width,
                displayHeight: height,
                baseROI: baseROI,
                manualCellROI: manualCellROI,
                symbolROI: symbolROI,
                manualSymbolCellROI: manualSymbolCellROI
            )
        }

        let sourceSize = CGSize(width: displayWidth, height: displayHeight)
        let targetSize = CGSize(width: width, height: height)

        return CaptureRuntimeConfig(
            version: version,
            displayID: displayID ?? self.displayID,
            displayWidth: width,
            displayHeight: height,
            baseROI: baseROI.scaled(from: sourceSize, to: targetSize),
            manualCellROI: manualCellROI.scaled(from: sourceSize, to: targetSize),
            symbolROI: symbolROI?.scaled(from: sourceSize, to: targetSize),
            manualSymbolCellROI: manualSymbolCellROI?.scaled(from: sourceSize, to: targetSize)
        )
    }

    var runtimeSummary: String {
        let symbolSummary = symbolROI?.summary ?? "not set"
        let symbolCellSummary = manualSymbolCellROI?.summary ?? "not set"
        return "base=\(baseROI.summary); manual_cell=\(manualCellROI.summary); symbol_roi=\(symbolSummary); symbol_cell=\(symbolCellSummary)"
    }
}

struct RuntimeRegionSelectionState: Equatable {
    var displayID: CGDirectDisplayID?
    var displayWidth: Int
    var displayHeight: Int
    var baseROI: PixelRect?
    var manualCellROI: PixelRect?
    var symbolROI: PixelRect?
    var manualSymbolCellROI: PixelRect?
    var sourceDescription: String

    init(
        displayID: CGDirectDisplayID? = nil,
        displayWidth: Int = 0,
        displayHeight: Int = 0,
        baseROI: PixelRect? = nil,
        manualCellROI: PixelRect? = nil,
        symbolROI: PixelRect? = nil,
        manualSymbolCellROI: PixelRect? = nil,
        sourceDescription: String = "Manual (unsaved)"
    ) {
        self.displayID = displayID
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.baseROI = baseROI
        self.manualCellROI = manualCellROI
        self.symbolROI = symbolROI
        self.manualSymbolCellROI = manualSymbolCellROI
        self.sourceDescription = sourceDescription
    }

    var hasAnySelection: Bool {
        baseROI != nil || manualCellROI != nil || symbolROI != nil || manualSymbolCellROI != nil
    }

    var canPersist: Bool {
        displayID != nil && displayWidth > 0 && displayHeight > 0 && baseROI != nil && manualCellROI != nil
    }

    mutating func resetForDisplay(_ display: DisplayTarget) {
        displayID = display.id
        displayWidth = display.width
        displayHeight = display.height
        baseROI = nil
        manualCellROI = nil
        symbolROI = nil
        manualSymbolCellROI = nil
        sourceDescription = "Manual (unsaved)"
    }

    mutating func clearOptionalSymbolSelections() {
        symbolROI = nil
        manualSymbolCellROI = nil
        sourceDescription = "Manual (unsaved)"
    }

    func toPersistedConfig() -> CaptureRuntimeConfig? {
        guard
            let displayID,
            let baseROI,
            let manualCellROI,
            displayWidth > 0,
            displayHeight > 0
        else {
            return nil
        }

        return CaptureRuntimeConfig(
            displayID: UInt32(displayID),
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            baseROI: baseROI,
            manualCellROI: manualCellROI,
            symbolROI: symbolROI,
            manualSymbolCellROI: manualSymbolCellROI
        )
    }

    mutating func applyPersistedConfig(_ config: CaptureRuntimeConfig, sourceDescription: String) {
        displayID = CGDirectDisplayID(config.displayID)
        displayWidth = config.displayWidth
        displayHeight = config.displayHeight
        baseROI = config.baseROI
        manualCellROI = config.manualCellROI
        symbolROI = config.symbolROI
        manualSymbolCellROI = config.manualSymbolCellROI
        self.sourceDescription = sourceDescription
    }

    var summaryText: String {
        let displaySummary: String
        if let displayID {
            displaySummary = "\(displayID) (\(displayWidth)x\(displayHeight))"
        } else {
            displaySummary = "not set"
        }

        return [
            "Source: \(sourceDescription)",
            "Display: \(displaySummary)",
            "Base ROI: \(baseROI?.summary ?? "not set")",
            "Manual Cell: \(manualCellROI?.summary ?? "not set")",
            "Symbol ROI: \(symbolROI?.summary ?? "not set")",
            "Symbol Cell: \(manualSymbolCellROI?.summary ?? "not set")"
        ].joined(separator: "\n")
    }
}
