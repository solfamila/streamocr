import AppKit
import CoreImage
import CoreGraphics
import Foundation

@MainActor
enum ROISelectionError: Error {
    case screenshotUnavailable(CGDirectDisplayID)
    case invalidContext(String)
    case cancelled
    case missingSelection

    var message: String {
        switch self {
        case let .screenshotUnavailable(displayID):
            return "Unable to capture a snapshot for display \(displayID). Confirm Screen Recording permission."
        case let .invalidContext(reason):
            return reason
        case .cancelled:
            return "ROI selection cancelled."
        case .missingSelection:
            return "Select a region before confirming."
        }
    }
}

struct ROISelectionContext {
    let parentRect: PixelRect
    let label: String
}

@MainActor
final class ROISelector {
    private struct SelectionInput {
        let image: NSImage
        let coordinateWidth: Int
        let coordinateHeight: Int
        let initialRect: PixelRect?
        let contextDescription: String?
        let outputOffsetX: Int
        let outputOffsetY: Int
    }

    func selectRect(
        for display: DisplayTarget,
        prompt: String,
        initialRect: PixelRect?,
        context: ROISelectionContext? = nil
    ) throws -> PixelRect {
        guard let cgImage = CGDisplayCreateImage(display.id) else {
            throw ROISelectionError.screenshotUnavailable(display.id)
        }

        let selectionInput = try makeSelectionInput(
            cgImage: cgImage,
            display: display,
            initialRect: initialRect,
            context: context
        )

        let controller = ROISelectionWindowController(
            image: selectionInput.image,
            coordinateWidth: selectionInput.coordinateWidth,
            coordinateHeight: selectionInput.coordinateHeight,
            prompt: prompt,
            displayTitle: display.title,
            initialRect: selectionInput.initialRect,
            contextDescription: selectionInput.contextDescription
        )

        guard let window = controller.window else {
            throw ROISelectionError.missingSelection
        }

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        let response = NSApp.runModal(for: window)
        window.orderOut(nil)

        guard response == .OK else {
            throw ROISelectionError.cancelled
        }

        guard let selectedRect = controller.selectedRect else {
            throw ROISelectionError.missingSelection
        }

        let translatedRect = PixelRect(
            x: selectedRect.x + selectionInput.outputOffsetX,
            y: selectedRect.y + selectionInput.outputOffsetY,
            width: selectedRect.width,
            height: selectedRect.height
        )

        return translatedRect.clamped(maxWidth: display.width, maxHeight: display.height) ?? translatedRect
    }

    private func makeSelectionInput(
        cgImage: CGImage,
        display: DisplayTarget,
        initialRect: PixelRect?,
        context: ROISelectionContext?
    ) throws -> SelectionInput {
        guard let context else {
            return SelectionInput(
                image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)),
                coordinateWidth: display.width,
                coordinateHeight: display.height,
                initialRect: initialRect,
                contextDescription: nil,
                outputOffsetX: 0,
                outputOffsetY: 0
            )
        }

        guard let clampedParent = context.parentRect.clamped(maxWidth: display.width, maxHeight: display.height) else {
            throw ROISelectionError.invalidContext("The parent ROI for nested selection is invalid.")
        }

        let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let ciY = cgImage.height - clampedParent.y - clampedParent.height
        let cropRect = CGRect(
            x: clampedParent.x,
            y: ciY,
            width: clampedParent.width,
            height: clampedParent.height
        ).integral.intersection(imageBounds)

        guard cropRect.width >= 1, cropRect.height >= 1 else {
            throw ROISelectionError.invalidContext("The parent ROI for nested selection is outside the display bounds.")
        }

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let sourceImage = CIImage(cgImage: cgImage)
        let croppedImage = sourceImage.cropped(to: cropRect)
        guard let nestedCGImage = ciContext.createCGImage(croppedImage, from: cropRect) else {
            throw ROISelectionError.invalidContext("Unable to prepare nested ROI preview for \(context.label).")
        }

        let nestedInitialRect = initialRect.flatMap { rect in
            PixelRect(
                x: rect.x - clampedParent.x,
                y: rect.y - clampedParent.y,
                width: rect.width,
                height: rect.height
            ).clamped(maxWidth: clampedParent.width, maxHeight: clampedParent.height)
        }

        return SelectionInput(
            image: NSImage(
                cgImage: nestedCGImage,
                size: NSSize(width: clampedParent.width, height: clampedParent.height)
            ),
            coordinateWidth: clampedParent.width,
            coordinateHeight: clampedParent.height,
            initialRect: nestedInitialRect,
            contextDescription: "Nested inside \(context.label): \(clampedParent.summary)",
            outputOffsetX: clampedParent.x,
            outputOffsetY: clampedParent.y
        )
    }
}

@MainActor
private final class ROISelectionWindowController: NSWindowController, NSWindowDelegate {
    private let selectionView: ROISelectionCanvasView
    private let selectionLabel = NSTextField(labelWithString: "Selection: not set")
    private let confirmButton = NSButton(title: "Use Selection", target: nil, action: nil)

    private var modalEnded = false

    var selectedRect: PixelRect? {
        selectionView.selectedRect
    }

    init(
        image: NSImage,
        coordinateWidth: Int,
        coordinateHeight: Int,
        prompt: String,
        displayTitle: String,
        initialRect: PixelRect?,
        contextDescription: String?
    ) {
        self.selectionView = ROISelectionCanvasView(
            image: image,
            coordinateWidth: coordinateWidth,
            coordinateHeight: coordinateHeight,
            initialRect: initialRect
        )

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let windowWidth = min(1_100, max(700, visibleFrame.width * 0.82))
        let windowHeight = min(820, max(560, visibleFrame.height * 0.82))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "Select ROI"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let instructionLabel = NSTextField(labelWithString: "\(prompt) [\(displayTitle)]")
        instructionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        instructionLabel.lineBreakMode = .byWordWrapping
        instructionLabel.maximumNumberOfLines = 2

        let hintText: String
        if let contextDescription {
            hintText = "\(contextDescription). Drag to select the nested cell region, then click Use Selection."
        } else {
            hintText = "Drag to select a region, then click Use Selection."
        }
        let hintLabel = NSTextField(labelWithString: hintText)
        hintLabel.textColor = .secondaryLabelColor

        selectionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        selectionLabel.textColor = .labelColor
        selectionLabel.lineBreakMode = .byTruncatingMiddle

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        confirmButton.isEnabled = initialRect != nil

        let buttonRow = NSStackView(views: [cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.setHuggingPriority(.required, for: .horizontal)

        let footerRow = NSStackView(views: [selectionLabel, buttonRow])
        footerRow.orientation = .horizontal
        footerRow.spacing = 12
        footerRow.alignment = .centerY

        let stack = NSStackView(views: [instructionLabel, hintLabel, selectionView, footerRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            selectionView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])

        selectionView.onSelectionChanged = { [weak self] rect in
            self?.updateSelectionLabel(rect)
        }

        updateSelectionLabel(initialRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        endModalIfNeeded(.cancel)
    }

    @objc
    private func cancelTapped() {
        endModalIfNeeded(.cancel)
    }

    @objc
    private func confirmTapped() {
        guard selectedRect != nil else {
            NSSound.beep()
            return
        }

        endModalIfNeeded(.OK)
    }

    private func updateSelectionLabel(_ rect: PixelRect?) {
        if let rect {
            selectionLabel.stringValue = "Selection: \(rect.summary)"
            confirmButton.isEnabled = true
        } else {
            selectionLabel.stringValue = "Selection: not set"
            confirmButton.isEnabled = false
        }
    }

    private func endModalIfNeeded(_ response: NSApplication.ModalResponse) {
        guard !modalEnded else {
            return
        }

        modalEnded = true
        NSApp.stopModal(withCode: response)
        window?.close()
    }
}

@MainActor
private final class ROISelectionCanvasView: NSView {
    private let image: NSImage
    private let coordinateWidth: Int
    private let coordinateHeight: Int

    private var dragStartPoint: NSPoint?
    private var dragCurrentPoint: NSPoint?

    var onSelectionChanged: ((PixelRect?) -> Void)?

    private(set) var selectedRect: PixelRect? {
        didSet {
            onSelectionChanged?(selectedRect)
        }
    }

    init(image: NSImage, coordinateWidth: Int, coordinateHeight: Int, initialRect: PixelRect?) {
        self.image = image
        self.coordinateWidth = max(1, coordinateWidth)
        self.coordinateHeight = max(1, coordinateHeight)
        self.selectedRect = initialRect
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.black.setFill()
        bounds.fill()

        let imageRect = renderedImageRect()
        image.draw(in: imageRect)

        if let selectionRect = currentSelectionViewRect(imageRect: imageRect) {
            let overlayPath = NSBezierPath(rect: imageRect)
            overlayPath.append(NSBezierPath(rect: selectionRect))
            overlayPath.windingRule = .evenOdd

            NSColor(calibratedWhite: 0, alpha: 0.28).setFill()
            overlayPath.fill()

            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: selectionRect)
            border.lineWidth = 2
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let imageRect = renderedImageRect()
        let location = clampToImageRect(convert(event.locationInWindow, from: nil), imageRect: imageRect)

        guard imageRect.contains(location) else {
            return
        }

        dragStartPoint = location
        dragCurrentPoint = location
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartPoint != nil else {
            return
        }

        let imageRect = renderedImageRect()
        dragCurrentPoint = clampToImageRect(convert(event.locationInWindow, from: nil), imageRect: imageRect)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStartPoint else {
            return
        }

        let imageRect = renderedImageRect()
        let endPoint = clampToImageRect(convert(event.locationInWindow, from: nil), imageRect: imageRect)

        let viewRect = NSRect(
            x: min(dragStartPoint.x, endPoint.x),
            y: min(dragStartPoint.y, endPoint.y),
            width: abs(endPoint.x - dragStartPoint.x),
            height: abs(endPoint.y - dragStartPoint.y)
        )

        selectedRect = pixelRect(from: viewRect, imageRect: imageRect)
        dragCurrentPoint = nil
        self.dragStartPoint = nil
        needsDisplay = true
    }

    private func currentSelectionViewRect(imageRect: CGRect) -> CGRect? {
        if let dragStartPoint, let dragCurrentPoint {
            let rect = CGRect(
                x: min(dragStartPoint.x, dragCurrentPoint.x),
                y: min(dragStartPoint.y, dragCurrentPoint.y),
                width: abs(dragCurrentPoint.x - dragStartPoint.x),
                height: abs(dragCurrentPoint.y - dragStartPoint.y)
            )
            return rect.intersection(imageRect)
        }

        if let selectedRect {
            return viewRect(from: selectedRect, imageRect: imageRect)
        }

        return nil
    }

    private func renderedImageRect() -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawWidth = imageSize.width * scale
        let drawHeight = imageSize.height * scale

        return CGRect(
            x: bounds.midX - drawWidth / 2,
            y: bounds.midY - drawHeight / 2,
            width: drawWidth,
            height: drawHeight
        )
    }

    private func pixelRect(from viewRect: CGRect, imageRect: CGRect) -> PixelRect? {
        let clipped = viewRect.intersection(imageRect)
        guard clipped.width >= 1, clipped.height >= 1 else {
            return nil
        }

        let xScale = CGFloat(coordinateWidth) / imageRect.width
        let yScale = CGFloat(coordinateHeight) / imageRect.height

        let x = Int(((clipped.minX - imageRect.minX) * xScale).rounded(.towardZero))
        let maxX = Int(((clipped.maxX - imageRect.minX) * xScale).rounded(.up))

        let yTop = Int(((imageRect.maxY - clipped.maxY) * yScale).rounded(.towardZero))
        let yBottom = Int(((imageRect.maxY - clipped.minY) * yScale).rounded(.up))

        let raw = PixelRect(
            x: x,
            y: yTop,
            width: max(1, maxX - x),
            height: max(1, yBottom - yTop)
        )

        return raw.clamped(maxWidth: coordinateWidth, maxHeight: coordinateHeight)
    }

    private func viewRect(from pixelRect: PixelRect, imageRect: CGRect) -> CGRect {
        let xScale = imageRect.width / CGFloat(coordinateWidth)
        let yScale = imageRect.height / CGFloat(coordinateHeight)

        return CGRect(
            x: imageRect.minX + CGFloat(pixelRect.x) * xScale,
            y: imageRect.maxY - CGFloat(pixelRect.y + pixelRect.height) * yScale,
            width: CGFloat(pixelRect.width) * xScale,
            height: CGFloat(pixelRect.height) * yScale
        )
    }

    private func clampToImageRect(_ point: CGPoint, imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, imageRect.minX), imageRect.maxX),
            y: min(max(point.y, imageRect.minY), imageRect.maxY)
        )
    }
}
