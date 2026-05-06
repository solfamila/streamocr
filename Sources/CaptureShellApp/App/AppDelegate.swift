import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tradingRuntimeManager = TradingRuntimeManager()
    private let liveSessionController: LiveOCRSessionController
    private let recordingSessionController = LiveRecordingSessionController()
    private lazy var tradingWindowController = TradingWindowController(
        manager: tradingRuntimeManager,
        onOpenSetup: { [weak self] in
            self?.showSetupWindow()
        },
        onStartLiveStream: { [weak self] urlText in
            self?.startLiveStream(urlText: urlText)
        },
        onStopLiveStream: { [weak self] in
            self?.stopLiveStream()
        },
        onStartRecording: { [weak self] urlText in
            self?.startRecording(urlText: urlText)
        },
        onStopRecording: { [weak self] in
            self?.stopRecording()
        },
        onLiveStreamURLChanged: { [weak self] urlText in
            self?.liveStreamURLChanged(urlText)
        },
        onOCRBuyRatioChanged: { [weak self] ratio in
            self?.ocrBuyRatioChanged(ratio)
        }
    )
    private lazy var displayCaptureMessageSender = OCRAutomationTradingMessageSender(
        manager: tradingRuntimeManager,
        configurationProvider: { [weak self] in
            guard let self else {
                return OCRAutomationTradingConfiguration(buyQuantityRatio: 0.5, controllerArmed: false)
            }
            return self.currentOCRAutomationTradingConfiguration()
        }
    )
    private lazy var displayOCRTradingRuntime = OCRTradingCoordinatorRuntime(
        coordinator: .liveTradingDefaults(),
        executor: displayCaptureMessageSender,
        eventHandler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDisplayOCRTradingEvent(event)
            }
        },
        emitsTransportOutcomes: true
    )
    private lazy var captureController: DisplayCaptureController = {
        let runtime = displayOCRTradingRuntime
        return DisplayCaptureController(
            permissionManager: ScreenRecordingPermissionManager(),
            timingLogger: FrameTimingLogger(),
            pipeline: LowLatencyOCRFramePipeline(
                frameObservationHandler: { observation in
                    runtime.handle(observation)
                }
            ),
            ocrTradingRuntime: runtime
        )
    }()

    private let runtimeConfigStore = RuntimeConfigStore()
    private let roiSelector = ROISelector()
    private var liveROISelectionTask: Task<Void, Never>?
    private var appliedRuntimeConfig: CaptureRuntimeConfig?

    private var window: NSWindow?
    private var statusLabel = NSTextField(labelWithString: "Starting...")
    private let displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private let requestPermissionButton = NSButton(title: "Request Screen Permission", target: nil, action: nil)
    private let refreshDisplaysButton = NSButton(title: "Refresh Displays", target: nil, action: nil)
    private let startStopButton = NSButton(title: "Start Capture", target: nil, action: nil)

    private let selectBaseROIButton = NSButton(title: "Select Base ROI", target: nil, action: nil)
    private let selectManualCellButton = NSButton(title: "Select Trigger Cell (Base ROI)", target: nil, action: nil)
    private let selectSymbolROIButton = NSButton(title: "Select Symbol ROI", target: nil, action: nil)
    private let selectSymbolCellButton = NSButton(title: "Select Symbol Cell (Symbol ROI)", target: nil, action: nil)

    private let clearSymbolSelectionsButton = NSButton(title: "Clear Symbol ROI/Cell", target: nil, action: nil)
    private let saveConfigButton = NSButton(title: "Save Runtime Config", target: nil, action: nil)
    private let loadConfigButton = NSButton(title: "Load Runtime Config", target: nil, action: nil)
    private let openTradingGUIButton = NSButton(title: "Open Trading GUI", target: nil, action: nil)

    private let activeRegionsLabel = NSTextField(labelWithString: "")
    private let configPathLabel = NSTextField(labelWithString: "")
    private let liveSourceLabel = NSTextField(labelWithString: "Live source: not set")

    private let tradingRuntimeButton = NSButton(title: "Start Trading Runtime", target: nil, action: nil)
    private let applyTradingConnectionButton = NSButton(title: "Apply Trading Connection", target: nil, action: nil)
    private let applyTradingRiskButton = NSButton(title: "Apply Trading Risk", target: nil, action: nil)
    private let subscribeButton = NSButton(title: "Subscribe", target: nil, action: nil)
    private let buyButton = NSButton(title: "Buy", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close Long", target: nil, action: nil)
    private let cancelAllButton = NSButton(title: "Cancel All", target: nil, action: nil)
    private let armControllerButton = NSButton(title: "Arm Controller", target: nil, action: nil)
    private let killSwitchButton = NSButton(title: "Enable Kill Switch", target: nil, action: nil)

    private let tradingStatusLabel = NSTextField(labelWithString: "Trading runtime stopped.")
    private let accountStatusLabel = NSTextField(labelWithString: "Account: --")
    private let controllerStatusLabel = NSTextField(labelWithString: "Controller: --")
    private let marketStatusLabel = NSTextField(labelWithString: "Market: --")

    private let hostField = NSTextField(frame: .zero)
    private let portField = NSTextField(frame: .zero)
    private let clientIDField = NSTextField(frame: .zero)
    private let symbolField = NSTextField(frame: .zero)
    private let quantityField = NSTextField(frame: .zero)
    private let bufferField = NSTextField(frame: .zero)
    private let maxPositionField = NSTextField(frame: .zero)
    private let staleQuoteField = NSTextField(frame: .zero)
    private let maxOrderField = NSTextField(frame: .zero)
    private let maxOpenField = NSTextField(frame: .zero)

    private let tradingMessagesTextView = NSTextView(frame: .zero)

    private var displays: [DisplayTarget] = []
    private var isCapturing = false
    private var regionState = RuntimeRegionSelectionState()
    private var currentLiveStreamURLText = ""
    private var ocrBuyRatio = 0.5
    private let startupEnvironment = ProcessInfo.processInfo.environment
    private var isTerminationShutdownInProgress = false
    private var didCompleteTerminationShutdown = false

    override init() {
        liveSessionController = LiveOCRSessionController(manager: tradingRuntimeManager)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
        bindTradingCallbacks()
        bindLiveSessionCallbacks()
        bindRecordingSessionCallbacks()

        configPathLabel.stringValue = "Config file: \(runtimeConfigStore.configURL.path)"
        loadPersistedRuntimeConfigIfAvailable()
        loadTradingConfiguration()
        syncTradingInputsToRuntime()
        tradingRuntimeManager.refreshDashboard()
        tradingWindowController.updateOCRBuyRatio(ocrBuyRatio)
        tradingWindowController.updateLiveStatus(liveSessionController.currentStatusSnapshot())
        tradingWindowController.updateRecordingStatus(recordingSessionController.currentStatusSnapshot())
        tradingWindowController.showWindowAndStart()
        applyStartupOverridesIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didCompleteTerminationShutdown {
            return .terminateNow
        }

        guard !isTerminationShutdownInProgress else {
            return .terminateLater
        }

        isTerminationShutdownInProgress = true
        Task { [weak self] in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }

            await captureController.stopCapture()
            _ = liveSessionController.stopAndDrain(timeout: 3)
            _ = recordingSessionController.stopAndFinishSynchronously(timeout: 20)
            await tradingRuntimeManager.shutdownAsync()

            didCompleteTerminationShutdown = true
            isTerminationShutdownInProgress = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !didCompleteTerminationShutdown else {
            return
        }

        _ = liveSessionController.stopAndDrain(timeout: 2)
        _ = recordingSessionController.stopAndFinishSynchronously(timeout: 20)
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
        guard let config = regionState.toPersistedConfig() else {
            statusLabel.stringValue = "Position base ROI and position cell ROI are required before saving runtime config."
            return
        }

        do {
            try runtimeConfigStore.save(config)
            regionState.sourceDescription = "Saved to \(runtimeConfigStore.configURL.lastPathComponent)"
            syncRuntimeRegionState()
            statusLabel.stringValue = "Saved runtime config for live OCR."
        } catch {
            statusLabel.stringValue = "Failed to save runtime config: \(error.localizedDescription)"
        }
    }

    @objc
    private func loadRuntimeConfigTapped() {
        do {
            let storedConfig = try runtimeConfigStore.load()
            regionState.applyPersistedConfig(
                storedConfig,
                sourceDescription: "Loaded from \(runtimeConfigStore.configURL.lastPathComponent)"
            )
            syncRuntimeRegionState()
            statusLabel.stringValue = "Loaded runtime config for live OCR."
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
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "OCR ROI Setup"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "Live OCR ROI Setup")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)

        let scopeLabel = NSTextField(
            labelWithString: "Capture a fresh live-stream frame, then define the symbol and position OCR regions. ROI edits are blocked while the controller is armed."
        )
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byWordWrapping
        scopeLabel.maximumNumberOfLines = 3

        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4

        liveSourceLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        liveSourceLabel.textColor = .secondaryLabelColor
        liveSourceLabel.lineBreakMode = .byTruncatingMiddle

        activeRegionsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        activeRegionsLabel.lineBreakMode = .byWordWrapping
        activeRegionsLabel.maximumNumberOfLines = 8
        activeRegionsLabel.textColor = .labelColor

        configPathLabel.font = NSFont.systemFont(ofSize: 11)
        configPathLabel.textColor = .secondaryLabelColor
        configPathLabel.lineBreakMode = .byTruncatingMiddle

        selectBaseROIButton.target = self
        selectBaseROIButton.action = #selector(selectBaseROITapped)
        selectBaseROIButton.title = "Select Position Base ROI"

        selectManualCellButton.target = self
        selectManualCellButton.action = #selector(selectManualCellTapped)
        selectManualCellButton.title = "Select Position Cell ROI"

        selectSymbolROIButton.target = self
        selectSymbolROIButton.action = #selector(selectSymbolROITapped)
        selectSymbolROIButton.title = "Select Symbol Base ROI"

        selectSymbolCellButton.target = self
        selectSymbolCellButton.action = #selector(selectSymbolCellTapped)
        selectSymbolCellButton.title = "Select Symbol Cell ROI"

        clearSymbolSelectionsButton.target = self
        clearSymbolSelectionsButton.action = #selector(clearSymbolSelectionsTapped)

        saveConfigButton.target = self
        saveConfigButton.action = #selector(saveRuntimeConfigTapped)

        loadConfigButton.target = self
        loadConfigButton.action = #selector(loadRuntimeConfigTapped)

        let symbolRow = NSStackView(views: [selectSymbolROIButton, selectSymbolCellButton])
        symbolRow.orientation = .horizontal
        symbolRow.spacing = 10

        let positionRow = NSStackView(views: [selectBaseROIButton, selectManualCellButton])
        positionRow.orientation = .horizontal
        positionRow.spacing = 10

        let configButtonsRow = NSStackView(views: [clearSymbolSelectionsButton, saveConfigButton, loadConfigButton])
        configButtonsRow.orientation = .horizontal
        configButtonsRow.spacing = 10

        let regionsHeader = NSTextField(labelWithString: "Active Runtime Regions")
        regionsHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let nextStepLabel = NSTextField(
            labelWithString: "Use the main trading GUI to enter the live stream URL, preview FPS, and arm OCR-driven buys."
        )
        nextStepLabel.textColor = .secondaryLabelColor
        nextStepLabel.lineBreakMode = .byWordWrapping
        nextStepLabel.maximumNumberOfLines = 3

        let stack = NSStackView(
            views: [
                titleLabel,
                scopeLabel,
                liveSourceLabel,
                symbolRow,
                positionRow,
                configButtonsRow,
                configPathLabel,
                regionsHeader,
                activeRegionsLabel,
                statusLabel,
                nextStepLabel
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

    private func configureTradingField(_ field: NSTextField, placeholder: String, width: CGFloat) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.controlSize = .regular
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func makeTradingLabeledField(title: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
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

    private func bindTradingCallbacks() {
        tradingRuntimeManager.onDashboardChanged = { [weak self] dashboard in
            self?.refreshTradingUI(dashboard)
            self?.tradingWindowController.updateDashboard(dashboard)
        }
    }

    private func bindLiveSessionCallbacks() {
        liveSessionController.onStatusChanged = { [weak self] status in
            guard let self else {
                return
            }
            tradingWindowController.updateLiveStatus(status)
            if window != nil {
                updateSetupWindowSourceLabel()
            }
        }
        appliedRuntimeConfig = regionState.toPersistedConfig()
        liveSessionController.setRuntimeConfig(appliedRuntimeConfig)
        liveSessionController.setBuyQuantityRatio(ocrBuyRatio)
    }

    private func bindRecordingSessionCallbacks() {
        recordingSessionController.onStatusChanged = { [weak self] status in
            guard let self else {
                return
            }
            tradingWindowController.updateRecordingStatus(status)
        }
    }

    @objc
    private func openTradingGUITapped() {
        syncTradingInputsToRuntime()
        tradingWindowController.showWindowAndStart()
    }

    private func showSetupWindow() {
        if window == nil {
            configureUI()
        }
        currentLiveStreamURLText = tradingWindowController.currentLiveStreamURLText
        updateSetupWindowSourceLabel()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startLiveStream(urlText: String) {
        currentLiveStreamURLText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try liveSessionController.start(
                seedURLText: currentLiveStreamURLText,
                loggingEnabled: isEnvironmentFlagEnabled("CAPTURESHELLAPP_LIVE_VERBOSE")
            )
        } catch {
            let errorStatus = LiveOCRSessionStatusSnapshot(
                state: .error,
                isRunning: false,
                seedURLText: currentLiveStreamURLText,
                headline: "Live stream: Error",
                detail: error.localizedDescription,
                fps: nil,
                frameSize: nil,
                lastSubscribedSymbol: nil,
                hasPositionROI: regionState.baseROI != nil && regionState.manualCellROI != nil,
                hasSymbolROI: regionState.symbolROI != nil && regionState.manualSymbolCellROI != nil
            )
            tradingWindowController.updateLiveStatus(errorStatus)
        }
    }

    private func isEnvironmentFlagEnabled(_ name: String) -> Bool {
        guard let rawValue = startupEnvironment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(rawValue)
    }

    private func stopLiveStream() {
        liveSessionController.stop()
    }

    private func startRecording(urlText: String) {
        currentLiveStreamURLText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try recordingSessionController.start(
                seedURLText: currentLiveStreamURLText,
                loggingEnabled: isEnvironmentFlagEnabled("CAPTURESHELLAPP_LIVE_VERBOSE")
            )
        } catch {
            _ = error
        }
    }

    private func stopRecording() {
        recordingSessionController.stop()
    }

    private func applyStartupOverridesIfNeeded() {
        if let startupURL = startupEnvironment["CAPTURESHELLAPP_LIVE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !startupURL.isEmpty
        {
            currentLiveStreamURLText = startupURL
            tradingWindowController.setLiveURLText(startupURL, force: true)
        }

        if let startupRatioText = startupEnvironment["CAPTURESHELLAPP_OCR_RATIO"],
            let startupRatio = Double(startupRatioText),
            startupRatio.isFinite,
            startupRatio > 0
        {
            ocrBuyRatio = startupRatio
            liveSessionController.setBuyQuantityRatio(startupRatio)
            tradingWindowController.updateOCRBuyRatio(startupRatio)
        }

        let autoStartValue = startupEnvironment["CAPTURESHELLAPP_AUTOSTART_LIVE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let autoStartValue, ["1", "true", "yes", "on"].contains(autoStartValue) else {
            return
        }

        guard !currentLiveStreamURLText.isEmpty else {
            tradingWindowController.updateLiveStatus(
                LiveOCRSessionStatusSnapshot(
                    state: .error,
                    isRunning: false,
                    seedURLText: "",
                    headline: "Live stream: Error",
                    detail: "CAPTURESHELLAPP_AUTOSTART_LIVE is set, but no CAPTURESHELLAPP_LIVE_URL was provided.",
                    fps: nil,
                    frameSize: nil,
                    lastSubscribedSymbol: nil,
                    hasPositionROI: regionState.baseROI != nil && regionState.manualCellROI != nil,
                    hasSymbolROI: regionState.symbolROI != nil && regionState.manualSymbolCellROI != nil
                )
            )
            return
        }

        let startupURL = currentLiveStreamURLText
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.startLiveStream(urlText: startupURL)
        }
    }

    private func liveStreamURLChanged(_ urlText: String) {
        currentLiveStreamURLText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSetupWindowSourceLabel()
    }

    private func ocrBuyRatioChanged(_ ratio: Double) {
        ocrBuyRatio = ratio.isFinite && ratio > 0 ? ratio : 0.5
        liveSessionController.setBuyQuantityRatio(ocrBuyRatio)
    }

    private func currentOCRAutomationTradingConfiguration() -> OCRAutomationTradingConfiguration {
        OCRAutomationTradingConfiguration(
            buyQuantityRatio: ocrBuyRatio,
            controllerArmed: tradingRuntimeManager.dashboard.panel.status.controllerArmed
        )
    }

    private func handleDisplayOCRTradingEvent(_ event: OCRPipelineEvent) {
        guard event.kind == .trigger else {
            return
        }

        let message = displayOCRTradingMessage(for: event)
        Task { [weak tradingRuntimeManager] in
            await tradingRuntimeManager?.appendMessageAsync(message)
        }
    }

    private func displayOCRTradingMessage(for event: OCRPipelineEvent) -> String {
        var parts = ["Display OCR", event.action]
        if let symbol = event.symbol, !symbol.isEmpty {
            parts.append(symbol)
        }
        if let parsedInteger = event.parsedInteger {
            parts.append("qty \(parsedInteger)")
        }
        parts.append("frame \(event.frameNumber)")
        if let presentationTimeSeconds = event.presentationTimeSeconds {
            parts.append(String(format: "t %.3fs", presentationTimeSeconds))
        }
        return parts.joined(separator: " ")
    }

    private func loadPersistedRuntimeConfigIfAvailable() {
        guard let storedConfig = try? runtimeConfigStore.load() else {
            updateRegionSummaryUI()
            return
        }

        regionState.applyPersistedConfig(
            storedConfig,
            sourceDescription: "Loaded from \(runtimeConfigStore.configURL.lastPathComponent)"
        )
        syncRuntimeRegionState()
    }

    private func refreshDisplays() async {
        statusLabel.stringValue = "Loading display targets..."
        await captureController.reloadDisplays()
    }

    private func loadTradingConfiguration() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await tradingRuntimeManager.currentConnectionConfigAsync()
                hostField.stringValue = connection.host
                portField.stringValue = String(connection.port)
                clientIDField.stringValue = String(connection.clientId)
            } catch {
                tradingStatusLabel.stringValue = "Failed to load trading connection config: \(error.localizedDescription)"
            }

            do {
                let risk = try await tradingRuntimeManager.currentRiskControlsAsync()
                staleQuoteField.stringValue = String(risk.staleQuoteThresholdMs)
                maxOrderField.stringValue = String(format: "%.0f", risk.maxOrderNotional)
                maxOpenField.stringValue = String(format: "%.0f", risk.maxOpenNotional)
            } catch {
                tradingStatusLabel.stringValue = "Failed to load trading risk controls: \(error.localizedDescription)"
            }
        }
    }

    @objc
    private func tradingRuntimeTapped() {
        if tradingRuntimeManager.isStarted {
            tradingStatusLabel.stringValue = "Stopping trading runtime..."
            Task { [weak self] in
                guard let self else { return }
                await tradingRuntimeManager.shutdownAsync()
                tradingStatusLabel.stringValue = "Trading runtime stopped."
            }
            return
        }

        syncTradingInputsToRuntime()
        tradingStatusLabel.stringValue = "Starting trading runtime..."
        Task { [weak self] in
            guard let self else { return }
            let startResult = await tradingRuntimeManager.startWithAutoConnectFallbackAsync()
            tradingStatusLabel.stringValue = startResult.connected
                ? "Trading runtime started and connected to TWS."
                : "Trading runtime started, but TWS is not connected yet."
            if let autoDetectedConfig = startResult.autoDetectedConfig {
                tradingStatusLabel.stringValue += " Auto-detected \(autoDetectedConfig.host):\(autoDetectedConfig.port)."
            }
        }
    }

    @objc
    private func tradingInputChanged() {
        syncTradingInputsToRuntime()
    }

    @objc
    private func applyTradingConnectionTapped() {
        tradingStatusLabel.stringValue = "Applying trading connection settings..."
        Task { [weak self] in
            guard let self else { return }
            do {
                var config = try await tradingRuntimeManager.currentConnectionConfigAsync()
                config.host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                config.port = max(1, Int(portField.intValue))
                config.clientId = max(1, Int(clientIDField.intValue))
                try await tradingRuntimeManager.updateConnectionConfigAsync(config)
                tradingStatusLabel.stringValue = "Trading connection settings applied."
            } catch {
                tradingStatusLabel.stringValue = "Failed to apply connection settings: \(error.localizedDescription)"
            }
        }
    }

    @objc
    private func applyTradingRiskTapped() {
        tradingStatusLabel.stringValue = "Applying trading risk controls..."
        Task { [weak self] in
            guard let self else { return }
            do {
                var risk = try await tradingRuntimeManager.currentRiskControlsAsync()
                risk.staleQuoteThresholdMs = max(250, Int(staleQuoteField.intValue))
                risk.maxOrderNotional = max(100, maxOrderField.doubleValue)
                risk.maxOpenNotional = max(risk.maxOrderNotional, maxOpenField.doubleValue)
                try await tradingRuntimeManager.updateRiskControlsAsync(risk)
                tradingStatusLabel.stringValue = "Trading risk controls applied."
            } catch {
                tradingStatusLabel.stringValue = "Failed to apply risk controls: \(error.localizedDescription)"
            }
        }
    }

    @objc
    private func subscribeTapped() {
        syncTradingInputsToRuntime()
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await tradingRuntimeManager.requestSubscriptionAsync(
                    symbol: symbolField.stringValue,
                    recalcQtyFromFirstAsk: false
                )
                tradingStatusLabel.stringValue = "Subscribed to \(response.normalizedSymbol ?? symbolField.stringValue)."
            } catch {
                tradingStatusLabel.stringValue = "Subscribe failed: \(error.localizedDescription)"
            }
        }
    }

    @objc
    private func buyTapped() {
        syncTradingInputsToRuntime()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await tradingRuntimeManager.submitBuyAsync(source: "GUI Button", note: "Buy Limit button pressed")
                tradingStatusLabel.stringValue = "BUY submitted."
            } catch {
                tradingStatusLabel.stringValue = "Buy failed: \(error.localizedDescription)"
            }
        }
    }

    @objc
    private func closeTapped() {
        syncTradingInputsToRuntime()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await tradingRuntimeManager.submitCloseAsync(source: "GUI Button", note: "Close Long button pressed")
                tradingStatusLabel.stringValue = "Close submitted."
            } catch {
                tradingStatusLabel.stringValue = "Close failed: \(error.localizedDescription)"
            }
        }
    }

    @objc
    private func cancelAllTapped() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await tradingRuntimeManager.cancelAllAsync()
                let count = response.orderIds?.count ?? 0
                tradingStatusLabel.stringValue = count > 0
                    ? "Cancel requested for \(count) order(s)."
                    : "No pending orders to cancel."
            } catch {
                tradingStatusLabel.stringValue = "Cancel all failed: \(error.localizedDescription)"
            }
        }
    }

    @objc
    private func armControllerTapped() {
        let nextArmed = !tradingRuntimeManager.dashboard.panel.status.controllerArmed
        Task { [weak self] in
            guard let self else { return }
            await tradingRuntimeManager.setControllerArmedAsync(nextArmed)
            tradingStatusLabel.stringValue = nextArmed ? "Controller armed." : "Controller disarmed."
        }
    }

    @objc
    private func killSwitchTapped() {
        let nextEnabled = !tradingRuntimeManager.dashboard.panel.status.tradingKillSwitch
        Task { [weak self] in
            guard let self else { return }
            await tradingRuntimeManager.setTradingKillSwitchAsync(nextEnabled)
            tradingStatusLabel.stringValue = nextEnabled ? "Kill switch enabled." : "Kill switch disabled."
        }
    }

    private func syncTradingInputsToRuntime() {
        tradingRuntimeManager.setUIInputs(
            symbolInput: symbolField.stringValue,
            subscribedSymbol: tradingRuntimeManager.dashboard.inputs.subscribedSymbol,
            subscribed: tradingRuntimeManager.dashboard.inputs.subscribed,
            quantityInput: max(1, Int(quantityField.intValue)),
            priceBuffer: max(0, bufferField.doubleValue),
            maxPositionDollars: max(1000, maxPositionField.doubleValue),
            selectedTraceId: tradingRuntimeManager.dashboard.inputs.selectedTraceId
        )
    }

    private func refreshTradingUI(_ dashboard: TradingDashboardSnapshot) {
        if !isFieldBeingEdited(symbolField) {
            symbolField.stringValue = dashboard.inputs.symbolInput
        }
        if !isFieldBeingEdited(quantityField) {
            quantityField.stringValue = String(dashboard.inputs.quantityInput)
        }
        if !isFieldBeingEdited(bufferField) {
            bufferField.stringValue = String(format: "%.2f", dashboard.inputs.priceBuffer)
        }
        if !isFieldBeingEdited(maxPositionField) {
            maxPositionField.stringValue = String(format: "%.0f", dashboard.inputs.maxPositionDollars)
        }

        tradingRuntimeButton.title = tradingRuntimeManager.isStarted ? "Stop Trading Runtime" : "Start Trading Runtime"
        accountStatusLabel.stringValue = "Account: \(dashboard.panel.status.accountText)"
        controllerStatusLabel.stringValue = dashboard.panel.status.controllerEnabled
            ? "Controller: \(dashboard.panel.status.controllerConnected ? "Connected" : "Disconnected") \(dashboard.panel.status.controllerDeviceName)"
            : "Controller: disabled"
        marketStatusLabel.stringValue = String(
            format: "Market %@  bid %.2f  ask %.2f  last %.2f  pos %.0f",
            dashboard.inputs.subscribedSymbol.isEmpty ? "--" : dashboard.inputs.subscribedSymbol,
            dashboard.panel.symbol.bidPrice,
            dashboard.panel.symbol.askPrice,
            dashboard.panel.symbol.lastPrice,
            dashboard.panel.symbol.currentPositionQty
        )

        let connectedText: String
        if dashboard.panel.status.connected && dashboard.panel.status.sessionReady {
            connectedText = "Connected / ready"
        } else if dashboard.panel.status.connected {
            connectedText = "Connected / syncing"
        } else if tradingRuntimeManager.isStarted {
            connectedText = "Started / disconnected"
        } else {
            connectedText = "Stopped"
        }

        tradingStatusLabel.stringValue = "Trading: \(connectedText)"
        if !dashboard.panel.status.startupRecoveryBanner.isEmpty {
            tradingStatusLabel.stringValue += " | \(dashboard.panel.status.startupRecoveryBanner)"
        }

        subscribeButton.isEnabled = tradingRuntimeManager.isStarted
        buyButton.isEnabled = tradingRuntimeManager.isStarted && dashboard.panel.canBuy
        closeButton.isEnabled = tradingRuntimeManager.isStarted && dashboard.panel.canClosePosition
        cancelAllButton.isEnabled = tradingRuntimeManager.isStarted && dashboard.panel.hasCancelableOrders
        armControllerButton.isEnabled = dashboard.panel.status.controllerEnabled && dashboard.panel.status.controllerConnected
        armControllerButton.title = dashboard.panel.status.controllerArmed ? "Disarm Controller" : "Arm Controller"
        killSwitchButton.title = dashboard.panel.status.tradingKillSwitch ? "Disable Kill Switch" : "Enable Kill Switch"

        let nextMessages = dashboard.messagesText.isEmpty ? "No trading messages yet." : dashboard.messagesText
        if tradingMessagesTextView.string != nextMessages {
            tradingMessagesTextView.string = nextMessages
        }
    }

    private func isFieldBeingEdited(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor(), let window = field.window else {
            return false
        }
        return window.firstResponder == editor
    }

    private func updateRegionSummaryUI() {
        activeRegionsLabel.stringValue = regionState.summaryText
    }

    private func syncRuntimeRegionState() {
        let nextConfig = regionState.toPersistedConfig()
        if let nextConfig {
            appliedRuntimeConfig = nextConfig
        }
        captureController.setActiveRuntimeConfig(appliedRuntimeConfig)
        liveSessionController.setRuntimeConfig(appliedRuntimeConfig)
        updateRegionSummaryUI()
        updateSetupWindowSourceLabel()
    }

    private func refreshRegionDraftUI() {
        updateRegionSummaryUI()
        updateSetupWindowSourceLabel()
    }

    private func updateSetupWindowSourceLabel() {
        let trimmedURL = currentLiveStreamURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            liveSourceLabel.stringValue = "Live source: not set"
        } else {
            liveSourceLabel.stringValue = "Live source: \(trimmedURL)"
        }
    }

    private func prepareRegionStateForFrameSize(width: Int, height: Int) {
        guard width > 0, height > 0 else {
            return
        }

        if
            regionState.displayWidth > 0,
            regionState.displayHeight > 0,
            regionState.displayWidth != width || regionState.displayHeight != height,
            let persistedConfig = regionState.toPersistedConfig()
        {
            regionState.applyPersistedConfig(
                persistedConfig.adjustedForFrameSize(width: width, height: height, displayID: 0),
                sourceDescription: "Scaled for live frame \(width)x\(height)"
            )
            return
        }

        if
            regionState.hasAnySelection,
            regionState.displayWidth > 0,
            regionState.displayHeight > 0,
            (regionState.displayWidth != width || regionState.displayHeight != height)
        {
            regionState = RuntimeRegionSelectionState(
                displayID: 0,
                displayWidth: width,
                displayHeight: height,
                sourceDescription: "Reset for live frame \(width)x\(height)"
            )
            return
        }

        if regionState.displayWidth == 0 || regionState.displayHeight == 0 {
            regionState.displayID = 0
            regionState.displayWidth = width
            regionState.displayHeight = height
            if regionState.sourceDescription.isEmpty {
                regionState.sourceDescription = "Manual (unsaved)"
            }
        }
    }

    private func selectRegion(for type: RegionType) {
        guard !tradingRuntimeManager.dashboard.panel.status.controllerArmed else {
            statusLabel.stringValue = "Disarm the controller before editing OCR ROIs."
            return
        }

        guard liveROISelectionTask == nil else {
            statusLabel.stringValue = "Already capturing a live ROI snapshot. Please wait..."
            return
        }

        currentLiveStreamURLText = tradingWindowController.currentLiveStreamURLText
        let trimmedURL = currentLiveStreamURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seedURL = URL(string: trimmedURL), !trimmedURL.isEmpty else {
            statusLabel.stringValue = "Enter a live stream URL in the trading GUI before selecting OCR ROIs."
            return
        }

        statusLabel.stringValue = "Capturing live ROI snapshot for \(type.statusTitle.lowercased())..."

        liveROISelectionTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.liveROISelectionTask = nil
                }
            }

            do {
                let snapshot = try await Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self else {
                        throw LiveOCRSessionControllerError.noActiveLiveFrame
                    }

                    let liveStatus = self.liveSessionController.currentStatusSnapshot()
                    if liveStatus.isRunning {
                        do {
                            return try self.liveSessionController.captureCurrentFrameSnapshot(timeoutSeconds: 1)
                        } catch LiveOCRSessionControllerError.noActiveLiveFrame {
                            // Fall back to a direct stream snapshot below.
                        } catch LiveOCRSessionControllerError.timedOutWaitingForLiveFrame {
                            // The live decoder can be between frames/backlogged; ROI setup should still work.
                        }
                    }

                    return try LiveStreamFrameSnapshotter().captureSnapshot(seedURL: seedURL)
                }.value

                await MainActor.run { [weak self] in
                    self?.statusLabel.stringValue = "Preparing \(type.statusTitle.lowercased()) ROI selector..."
                }

                await self?.presentRegionSelection(type: type, snapshot: snapshot)
            } catch {
                await MainActor.run { [weak self] in
                    self?.statusLabel.stringValue = "Failed to capture a live ROI snapshot: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func presentRegionSelection(type: RegionType, snapshot: LiveStreamFrameSnapshot) async {
        guard !tradingRuntimeManager.dashboard.panel.status.controllerArmed else {
            statusLabel.stringValue = "Disarm the controller before editing OCR ROIs."
            return
        }

        prepareRegionStateForFrameSize(width: snapshot.width, height: snapshot.height)

        let selectionContext: ROISelectionContext?
        switch type {
        case .manualCellROI:
            guard let baseROI = regionState.baseROI else {
                statusLabel.stringValue = "Select the position base ROI first."
                return
            }
            selectionContext = ROISelectionContext(parentRect: baseROI, label: "Position base ROI")
        case .manualSymbolCellROI:
            guard let symbolROI = regionState.symbolROI else {
                statusLabel.stringValue = "Select the symbol base ROI first."
                return
            }
            selectionContext = ROISelectionContext(parentRect: symbolROI, label: "Symbol base ROI")
        case .baseROI, .symbolROI:
            selectionContext = nil
        }

        let initialRect = currentRect(for: type)
        let frameTitle = "Live stream \(snapshot.width)x\(snapshot.height)"

        do {
            let preparedInput = try await prepareLiveSelectionInput(
                snapshot: snapshot,
                initialRect: initialRect,
                context: selectionContext
            )

            let selectedRect = try roiSelector.selectPreparedRect(
                preparedInput,
                prompt: type.prompt,
                displayTitle: frameTitle,
                maxWidth: snapshot.width,
                maxHeight: snapshot.height
            )

            let clearedDependentSelection = setRect(selectedRect, for: type)
            regionState.sourceDescription = "Manual (unsaved)"
            let shouldApplyRuntimeConfig = !(type == .baseROI && clearedDependentSelection)
            if shouldApplyRuntimeConfig {
                syncRuntimeRegionState()
            } else {
                refreshRegionDraftUI()
            }

            var statusMessage = "\(type.statusTitle) updated from live stream snapshot: \(selectedRect.summary)."
            switch type {
            case .baseROI:
                statusMessage += " Next: select Position cell from the nested Position base ROI view."
                if clearedDependentSelection {
                    statusMessage += " Cleared previous Position cell selection. Live OCR keeps using the previous applied position config until you select the new Position cell ROI."
                }
            case .symbolROI:
                statusMessage += " Next: select Symbol cell from the nested Symbol base ROI view."
                if clearedDependentSelection {
                    statusMessage += " Cleared previous Symbol cell selection."
                }
            case .manualCellROI, .manualSymbolCellROI:
                break
            }
            statusLabel.stringValue = statusMessage
        } catch ROISelectionError.cancelled {
            statusLabel.stringValue = "\(type.statusTitle) selection cancelled."
        } catch let error as ROISelectionError {
            statusLabel.stringValue = "Failed to select \(type.statusTitle.lowercased()): \(error.message)"
        } catch {
            statusLabel.stringValue = "Failed to select \(type.statusTitle.lowercased()): \(error.localizedDescription)"
        }
    }

    private func prepareLiveSelectionInput(
        snapshot: LiveStreamFrameSnapshot,
        initialRect: PixelRect?,
        context: ROISelectionContext?
    ) async throws -> PreparedROISelectionInput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let preparedInput = try ROISelector.prepareSelectionInput(
                        cgImage: snapshot.cgImage,
                        coordinateWidth: snapshot.width,
                        coordinateHeight: snapshot.height,
                        initialRect: initialRect,
                        context: context
                    )
                    continuation.resume(returning: preparedInput)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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

    @discardableResult
    private func setRect(_ rect: PixelRect, for type: RegionType) -> Bool {
        switch type {
        case .baseROI:
            let parentChanged = regionState.baseROI != rect
            regionState.baseROI = rect
            if parentChanged, regionState.manualCellROI != nil {
                regionState.manualCellROI = nil
                return true
            }
            return false
        case .manualCellROI:
            regionState.manualCellROI = rect
            return false
        case .symbolROI:
            let parentChanged = regionState.symbolROI != rect
            regionState.symbolROI = rect
            if parentChanged, regionState.manualSymbolCellROI != nil {
                regionState.manualSymbolCellROI = nil
                return true
            }
            return false
        case .manualSymbolCellROI:
            regionState.manualSymbolCellROI = rect
            return false
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
            return "Select the position base ROI"
        case .manualCellROI:
            return "Select the numeric position cell ROI from the zoomed Position base ROI view"
        case .symbolROI:
            return "Select the symbol base ROI"
        case .manualSymbolCellROI:
            return "Select the symbol cell ROI from the zoomed Symbol base ROI view"
        }
    }

    var statusTitle: String {
        switch self {
        case .baseROI:
            return "Position base ROI"
        case .manualCellROI:
            return "Position cell"
        case .symbolROI:
            return "Symbol base ROI"
        case .manualSymbolCellROI:
            return "Symbol cell"
        }
    }
}
