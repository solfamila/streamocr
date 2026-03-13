import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureController = DisplayCaptureController(
        permissionManager: ScreenRecordingPermissionManager(),
        timingLogger: FrameTimingLogger(),
        pipeline: LowLatencyOCRFramePipeline()
    )

    private let runtimeConfigStore = RuntimeConfigStore()
    private let roiSelector = ROISelector()

    private var window: NSWindow?
    private var statusLabel = NSTextField(labelWithString: "Starting...")
    private let displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private let requestPermissionButton = NSButton(title: "Request Screen Permission", target: nil, action: nil)
    private let refreshDisplaysButton = NSButton(title: "Refresh Displays", target: nil, action: nil)
    private let startStopButton = NSButton(title: "Start Capture", target: nil, action: nil)

    private let selectBaseROIButton = NSButton(title: "Select Base ROI", target: nil, action: nil)
    private let selectManualCellButton = NSButton(title: "Select Trigger Cell", target: nil, action: nil)
    private let selectSymbolROIButton = NSButton(title: "Select Symbol ROI", target: nil, action: nil)
    private let selectSymbolCellButton = NSButton(title: "Select Symbol Cell", target: nil, action: nil)

    private let clearSymbolSelectionsButton = NSButton(title: "Clear Symbol ROI/Cell", target: nil, action: nil)
    private let saveConfigButton = NSButton(title: "Save Runtime Config", target: nil, action: nil)
    private let loadConfigButton = NSButton(title: "Load Runtime Config", target: nil, action: nil)

    private let activeRegionsLabel = NSTextField(labelWithString: "")
    private let configPathLabel = NSTextField(labelWithString: "")

    private var displays: [DisplayTarget] = []
    private var isCapturing = false
    private var regionState = RuntimeRegionSelectionState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
        configureUI()
        bindCaptureCallbacks()

        configPathLabel.stringValue = "Config file: \(runtimeConfigStore.configURL.path)"
        updateRegionSummaryUI()

        Task {
            await refreshDisplays()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await captureController.stopCapture()
        }
    }

    @objc
    private func requestPermissionTapped() {
        let granted = captureController.requestScreenRecordingPermission()
        statusLabel.stringValue = granted
            ? "Screen Recording permission granted."
            : "Permission not granted. Enable Screen Recording for this app in System Settings."

        if granted {
            Task {
                await refreshDisplays()
            }
        }
    }

    @objc
    private func refreshDisplaysTapped() {
        Task {
            await refreshDisplays()
        }
    }

    @objc
    private func startStopTapped() {
        if isCapturing {
            Task {
                await captureController.stopCapture()
            }
            return
        }

        guard let selected = selectedDisplay else {
            statusLabel.stringValue = "Select a display target first."
            return
        }

        if let regionDisplayID = regionState.displayID,
            regionDisplayID != selected.id,
            regionState.hasAnySelection {
            statusLabel.stringValue = "Active regions target display \(regionDisplayID), not selected display \(selected.id). Load matching config or re-select regions."
            return
        }

        Task {
            await captureController.startCapture(displayID: selected.id)
        }
    }

    @objc
    private func displaySelectionChanged() {
        guard let selected = selectedDisplay else {
            return
        }

        if let regionDisplayID = regionState.displayID,
            regionDisplayID != selected.id,
            regionState.hasAnySelection {
            statusLabel.stringValue = "Display changed to \(selected.id). Existing runtime regions belong to display \(regionDisplayID)."
        }
    }

    @objc
    private func selectBaseROITapped() {
        selectRegion(for: .baseROI)
    }

    @objc
    private func selectManualCellTapped() {
        selectRegion(for: .manualCellROI)
    }

    @objc
    private func selectSymbolROITapped() {
        selectRegion(for: .symbolROI)
    }

    @objc
    private func selectSymbolCellTapped() {
        selectRegion(for: .manualSymbolCellROI)
    }

    @objc
    private func clearSymbolSelectionsTapped() {
        regionState.clearOptionalSymbolSelections()
        syncRuntimeRegionState()
        statusLabel.stringValue = "Cleared optional symbol ROI and symbol cell selections."
    }

    @objc
    private func saveRuntimeConfigTapped() {
        guard let selected = selectedDisplay else {
            statusLabel.stringValue = "Select a display target before saving runtime config."
            return
        }

        if let regionDisplayID = regionState.displayID,
            regionDisplayID != selected.id,
            regionState.hasAnySelection {
            statusLabel.stringValue = "Cannot save: active regions target display \(regionDisplayID), but selected display is \(selected.id)."
            return
        }

        guard let config = regionState.toPersistedConfig() else {
            statusLabel.stringValue = "Base ROI and trigger cell are required before saving runtime config."
            return
        }

        do {
            try runtimeConfigStore.save(config)
            regionState.sourceDescription = "Saved to \(runtimeConfigStore.configURL.lastPathComponent)"
            syncRuntimeRegionState()
            statusLabel.stringValue = "Saved runtime config for display \(selected.id)."
        } catch {
            statusLabel.stringValue = "Failed to save runtime config: \(error.localizedDescription)"
        }
    }

    @objc
    private func loadRuntimeConfigTapped() {
        do {
            let storedConfig = try runtimeConfigStore.load()

            if let matchingIndex = displays.firstIndex(where: { UInt32($0.id) == storedConfig.displayID }) {
                let matchingDisplay = displays[matchingIndex]
                displayPopUp.selectItem(at: matchingIndex)

                let adjustedConfig = storedConfig.adjustedForDisplay(matchingDisplay)
                regionState.applyPersistedConfig(
                    adjustedConfig,
                    sourceDescription: "Loaded from \(runtimeConfigStore.configURL.lastPathComponent)"
                )

                syncRuntimeRegionState()
                statusLabel.stringValue = "Loaded runtime config for display \(matchingDisplay.id). Active regions are now in use."
                return
            }

            regionState.applyPersistedConfig(
                storedConfig,
                sourceDescription: "Loaded (display unavailable)"
            )

            syncRuntimeRegionState()
            statusLabel.stringValue = "Loaded runtime config for display \(storedConfig.displayID), but that display is not currently available."
        } catch {
            statusLabel.stringValue = "Failed to load runtime config: \(error.localizedDescription)"
        }
    }

    private var selectedDisplay: DisplayTarget? {
        guard displays.indices.contains(displayPopUp.indexOfSelectedItem) else {
            return nil
        }

        return displays[displayPopUp.indexOfSelectedItem]
    }

    private func configureUI() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "CaptureShell Wave 1"
        window.center()
        window.makeKeyAndOrderFront(nil)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "ScreenCaptureKit Display Capture")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)

        let scopeLabel = NSTextField(labelWithString: "Display capture with interactive ROI selection and persisted runtime config.")
        scopeLabel.textColor = .secondaryLabelColor

        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4

        activeRegionsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        activeRegionsLabel.lineBreakMode = .byWordWrapping
        activeRegionsLabel.maximumNumberOfLines = 8
        activeRegionsLabel.textColor = .labelColor

        configPathLabel.font = NSFont.systemFont(ofSize: 11)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle

        requestPermissionButton.target = self
        requestPermissionButton.action = #selector(requestPermissionTapped)

        refreshDisplaysButton.target = self
        refreshDisplaysButton.action = #selector(refreshDisplaysTapped)

        startStopButton.target = self
        startStopButton.action = #selector(startStopTapped)

        displayPopUp.target = self
        displayPopUp.action = #selector(displaySelectionChanged)

        selectBaseROIButton.target = self
        selectBaseROIButton.action = #selector(selectBaseROITapped)

        selectManualCellButton.target = self
        selectManualCellButton.action = #selector(selectManualCellTapped)

        selectSymbolROIButton.target = self
        selectSymbolROIButton.action = #selector(selectSymbolROITapped)

        selectSymbolCellButton.target = self
        selectSymbolCellButton.action = #selector(selectSymbolCellTapped)

        clearSymbolSelectionsButton.target = self
        clearSymbolSelectionsButton.action = #selector(clearSymbolSelectionsTapped)

        saveConfigButton.target = self
        saveConfigButton.action = #selector(saveRuntimeConfigTapped)

        loadConfigButton.target = self
        loadConfigButton.action = #selector(loadRuntimeConfigTapped)

        let captureButtonsRow = NSStackView(views: [requestPermissionButton, refreshDisplaysButton, startStopButton])
        captureButtonsRow.orientation = .horizontal
        captureButtonsRow.spacing = 10

        let roiButtonsRow = NSStackView(views: [selectBaseROIButton, selectManualCellButton, selectSymbolROIButton, selectSymbolCellButton])
        roiButtonsRow.orientation = .horizontal
        roiButtonsRow.spacing = 10

        let configButtonsRow = NSStackView(views: [clearSymbolSelectionsButton, saveConfigButton, loadConfigButton])
        configButtonsRow.orientation = .horizontal
        configButtonsRow.spacing = 10

        let regionsHeader = NSTextField(labelWithString: "Active Runtime Regions")
        regionsHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView(
            views: [
                titleLabel,
                scopeLabel,
                displayPopUp,
                captureButtonsRow,
                roiButtonsRow,
                configButtonsRow,
                configPathLabel,
                regionsHeader,
                activeRegionsLabel,
                statusLabel
            ]
        )
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])

        self.window = window
    }

    private func bindCaptureCallbacks() {
        captureController.onDisplaysUpdated = { [weak self] targets in
            guard let self else {
                return
            }

            let previousSelection = selectedDisplay?.id
            displays = targets
            displayPopUp.removeAllItems()
            displayPopUp.addItems(withTitles: targets.map(\.title))

            if let previousSelection,
                let index = targets.firstIndex(where: { $0.id == previousSelection }) {
                displayPopUp.selectItem(at: index)
            }

            if targets.isEmpty {
                statusLabel.stringValue = "No displays found. Confirm Screen Recording permission and retry."
            } else {
                statusLabel.stringValue = "Select a display target, configure regions, and start capture."
            }
        }

        captureController.onStatus = { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = message
            }
        }

        captureController.onCaptureStateChanged = { [weak self] active in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                isCapturing = active
                startStopButton.title = active ? "Stop Capture" : "Start Capture"
            }
        }
    }

    private func refreshDisplays() async {
        statusLabel.stringValue = "Loading display targets..."
        await captureController.reloadDisplays()
    }

    private func updateRegionSummaryUI() {
        activeRegionsLabel.stringValue = regionState.summaryText
    }

    private func syncRuntimeRegionState() {
        captureController.setActiveRuntimeConfig(regionState.toPersistedConfig())
        updateRegionSummaryUI()
    }

    private func selectRegion(for type: RegionType) {
        guard let selectedDisplay else {
            statusLabel.stringValue = "Select a display target before selecting regions."
            return
        }

        if let existingDisplayID = regionState.displayID,
            existingDisplayID != selectedDisplay.id,
            regionState.hasAnySelection {
            regionState.resetForDisplay(selectedDisplay)
            statusLabel.stringValue = "Display changed. Cleared previous selections from display \(existingDisplayID)."
        } else {
            regionState.displayID = selectedDisplay.id
            regionState.displayWidth = selectedDisplay.width
            regionState.displayHeight = selectedDisplay.height
        }

        do {
            let selectedRect = try roiSelector.selectRect(
                for: selectedDisplay,
                prompt: type.prompt,
                initialRect: currentRect(for: type)
            )

            setRect(selectedRect, for: type)
            regionState.sourceDescription = "Manual (unsaved)"
            syncRuntimeRegionState()

            statusLabel.stringValue = "\(type.statusTitle) updated for display \(selectedDisplay.id): \(selectedRect.summary)."
        } catch ROISelectionError.cancelled {
            statusLabel.stringValue = "\(type.statusTitle) selection cancelled."
        } catch let error as ROISelectionError {
            statusLabel.stringValue = "Failed to select \(type.statusTitle.lowercased()): \(error.message)"
        } catch {
            statusLabel.stringValue = "Failed to select \(type.statusTitle.lowercased()): \(error.localizedDescription)"
        }
    }

    private func currentRect(for type: RegionType) -> PixelRect? {
        switch type {
        case .baseROI:
            return regionState.baseROI
        case .manualCellROI:
            return regionState.manualCellROI
        case .symbolROI:
            return regionState.symbolROI
        case .manualSymbolCellROI:
            return regionState.manualSymbolCellROI
        }
    }

    private func setRect(_ rect: PixelRect, for type: RegionType) {
        switch type {
        case .baseROI:
            regionState.baseROI = rect
        case .manualCellROI:
            regionState.manualCellROI = rect
        case .symbolROI:
            regionState.symbolROI = rect
        case .manualSymbolCellROI:
            regionState.manualSymbolCellROI = rect
        }
    }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let quitTitle = "Quit \(ProcessInfo.processInfo.processName)"
        appMenu.addItem(withTitle: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        appMenuItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }
}

private enum RegionType {
    case baseROI
    case manualCellROI
    case symbolROI
    case manualSymbolCellROI

    var prompt: String {
        switch self {
        case .baseROI:
            return "Select the main OCR base ROI"
        case .manualCellROI:
            return "Select the numeric trigger cell ROI"
        case .symbolROI:
            return "Select the optional symbol ROI"
        case .manualSymbolCellROI:
            return "Select the optional symbol cell ROI"
        }
    }

    var statusTitle: String {
        switch self {
        case .baseROI:
            return "Base ROI"
        case .manualCellROI:
            return "Trigger cell"
        case .symbolROI:
            return "Symbol ROI"
        case .manualSymbolCellROI:
            return "Symbol cell"
        }
    }
}
