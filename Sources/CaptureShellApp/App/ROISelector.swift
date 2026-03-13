import AppKit
import CoreGraphics
import Foundation

@MainActor
enum ROISelectionError: Error {
    case screenshotUnavailable(CGDirectDisplayID)
    case cancelled
    case missingSelection

    var message: String {
        switch self {
        case let .screenshotUnavailable(displayID):
            return "Unable to capture a snapshot for display \(displayID). Confirm Screen Recording permission."
        case .cancelled:
            return "ROI selection cancelled."
        case .missingSelection:
            return "Select a region before confirming."
        }
    }
}

@MainActor
final class ROISelector {
    func selectRect(
        for display: DisplayTarget,
        prompt: String,
        initialRect: PixelRect?
    ) throws -> PixelRect {
        guard let cgImage = CGDisplayCreateImage(display.id) else {
            throw ROISelectionError.screenshotUnavailable(display.id)
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let controller = ROISelectionWindowController(
            image: image,
            coordinateWidth: display.width,
            coordinateHeight: display.height,
            prompt: prompt,
            displayTitle: display.title,
            initialRect: initialRect
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

        return selectedRect
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
        initialRect: PixelRect?
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

        let hintLabel = NSTextField(labelWithString: "Drag to select a region, then click Use Selection.")
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
