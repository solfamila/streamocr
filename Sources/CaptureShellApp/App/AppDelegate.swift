import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tradingRuntimeManager = TradingRuntimeManager()
    private lazy var tradingWindowController = TradingWindowController(
        manager: tradingRuntimeManager,
        onOpenSetup: { [weak self] in
            self?.showSetupWindow()
        }
    )
    private lazy var captureController = DisplayCaptureController(
        permissionManager: ScreenRecordingPermissionManager(),
        timingLogger: FrameTimingLogger(),
        pipeline: LowLatencyOCRFramePipeline(
            messageSender: DirectTradingMessageSender(manager: tradingRuntimeManager)
        )
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
    private let selectManualCellButton = NSButton(title: "Select Trigger Cell (Base ROI)", target: nil, action: nil)
    private let selectSymbolROIButton = NSButton(title: "Select Symbol ROI", target: nil, action: nil)
    private let selectSymbolCellButton = NSButton(title: "Select Symbol Cell (Symbol ROI)", target: nil, action: nil)

    private let clearSymbolSelectionsButton = NSButton(title: "Clear Symbol ROI/Cell", target: nil, action: nil)
    private let saveConfigButton = NSButton(title: "Save Runtime Config", target: nil, action: nil)
    private let loadConfigButton = NSButton(title: "Load Runtime Config", target: nil, action: nil)
    private let openTradingGUIButton = NSButton(title: "Open Trading GUI", target: nil, action: nil)

    private let activeRegionsLabel = NSTextField(labelWithString: "")
    private let configPathLabel = NSTextField(labelWithString: "")

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
        configureUI()
        bindCaptureCallbacks()
        bindTradingCallbacks()

        configPathLabel.stringValue = "Config file: \(runtimeConfigStore.configURL.path)"
        updateRegionSummaryUI()
        loadTradingConfiguration()
        syncTradingInputsToRuntime()
        tradingRuntimeManager.refreshDashboard()

        Task {
            await refreshDisplays()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await captureController.stopCapture()
        }
        tradingRuntimeManager.shutdown()
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
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640),
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

        let scopeLabel = NSTextField(
            labelWithString: "Display capture with nested ROI selection (base/symbol first, then cell) and persisted runtime config."
        )
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

        configureTradingField(hostField, placeholder: "127.0.0.1", width: 140)
        configureTradingField(portField, placeholder: "7496", width: 80)
        configureTradingField(clientIDField, placeholder: "101", width: 80)
        configureTradingField(symbolField, placeholder: "PLRZ", width: 120)
        configureTradingField(quantityField, placeholder: "1", width: 80)
        configureTradingField(bufferField, placeholder: "0.01", width: 80)
        configureTradingField(maxPositionField, placeholder: "40000", width: 110)
        configureTradingField(staleQuoteField, placeholder: "1500", width: 90)
        configureTradingField(maxOrderField, placeholder: "15000", width: 110)
        configureTradingField(maxOpenField, placeholder: "50000", width: 110)

        tradingStatusLabel.lineBreakMode = .byWordWrapping
        tradingStatusLabel.maximumNumberOfLines = 3
        accountStatusLabel.textColor = .secondaryLabelColor
        controllerStatusLabel.textColor = .secondaryLabelColor
        marketStatusLabel.textColor = .secondaryLabelColor

        tradingMessagesTextView.isEditable = false
        tradingMessagesTextView.isSelectable = true
        tradingMessagesTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tradingMessagesTextView.backgroundColor = .textBackgroundColor
        let tradingMessagesScrollView = NSScrollView()
        tradingMessagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        tradingMessagesScrollView.documentView = tradingMessagesTextView
        tradingMessagesScrollView.hasVerticalScroller = true
        tradingMessagesScrollView.borderType = .bezelBorder
        tradingMessagesScrollView.heightAnchor.constraint(equalToConstant: 180).isActive = true

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
        openTradingGUIButton.target = self
        openTradingGUIButton.action = #selector(openTradingGUITapped)

        tradingRuntimeButton.target = self
        tradingRuntimeButton.action = #selector(tradingRuntimeTapped)
        applyTradingConnectionButton.target = self
        applyTradingConnectionButton.action = #selector(applyTradingConnectionTapped)
        applyTradingRiskButton.target = self
        applyTradingRiskButton.action = #selector(applyTradingRiskTapped)
        subscribeButton.target = self
        subscribeButton.action = #selector(subscribeTapped)
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        cancelAllButton.target = self
        cancelAllButton.action = #selector(cancelAllTapped)
        armControllerButton.target = self
        armControllerButton.action = #selector(armControllerTapped)
        killSwitchButton.target = self
        killSwitchButton.action = #selector(killSwitchTapped)

        [hostField, portField, clientIDField, symbolField, quantityField, bufferField, maxPositionField, staleQuoteField, maxOrderField, maxOpenField].forEach {
            $0.target = self
            $0.action = #selector(tradingInputChanged)
        }

        let captureButtonsRow = NSStackView(views: [requestPermissionButton, refreshDisplaysButton, startStopButton])
        captureButtonsRow.orientation = .horizontal
        captureButtonsRow.spacing = 10

        let roiButtonsRow = NSStackView(views: [selectBaseROIButton, selectManualCellButton, selectSymbolROIButton, selectSymbolCellButton])
        roiButtonsRow.orientation = .horizontal
        roiButtonsRow.spacing = 10

        let configButtonsRow = NSStackView(views: [clearSymbolSelectionsButton, saveConfigButton, loadConfigButton, openTradingGUIButton])
        configButtonsRow.orientation = .horizontal
        configButtonsRow.spacing = 10

        let regionsHeader = NSTextField(labelWithString: "Active Runtime Regions")
        regionsHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let nextStepLabel = NSTextField(
            labelWithString: "After ROI selection, open the old trading GUI. OCR BUY/SUBSCRIBE now route directly into that in-process trading runtime."
        )
        nextStepLabel.textColor = .secondaryLabelColor
        nextStepLabel.lineBreakMode = .byWordWrapping
        nextStepLabel.maximumNumberOfLines = 3

        let connectionRow = NSStackView(views: [
            makeTradingLabeledField(title: "Host", field: hostField),
            makeTradingLabeledField(title: "Port", field: portField),
            makeTradingLabeledField(title: "Client ID", field: clientIDField),
            applyTradingConnectionButton,
            tradingRuntimeButton
        ])
        connectionRow.orientation = .horizontal
        connectionRow.spacing = 10

        let inputRow = NSStackView(views: [
            makeTradingLabeledField(title: "Symbol", field: symbolField),
            makeTradingLabeledField(title: "Qty", field: quantityField),
            makeTradingLabeledField(title: "Buffer", field: bufferField),
            makeTradingLabeledField(title: "Max Position $", field: maxPositionField),
            subscribeButton
        ])
        inputRow.orientation = .horizontal
        inputRow.spacing = 10

        let riskRow = NSStackView(views: [
            makeTradingLabeledField(title: "Stale Quote ms", field: staleQuoteField),
            makeTradingLabeledField(title: "Max Order $", field: maxOrderField),
            makeTradingLabeledField(title: "Max Open $", field: maxOpenField),
            applyTradingRiskButton
        ])
        riskRow.orientation = .horizontal
        riskRow.spacing = 10

        let actionRow = NSStackView(views: [buyButton, closeButton, cancelAllButton, armControllerButton, killSwitchButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10

        let tradingMessagesHeader = NSTextField(labelWithString: "Trading Messages")
        tradingMessagesHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

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

    @objc
    private func openTradingGUITapped() {
        syncTradingInputsToRuntime()
        tradingWindowController.showWindowAndStart()
    }

    private func showSetupWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshDisplays() async {
        statusLabel.stringValue = "Loading display targets..."
        await captureController.reloadDisplays()
    }

    private func loadTradingConfiguration() {
        do {
            let connection = try tradingRuntimeManager.currentConnectionConfig()
            hostField.stringValue = connection.host
            portField.stringValue = String(connection.port)
            clientIDField.stringValue = String(connection.clientId)
        } catch {
            tradingStatusLabel.stringValue = "Failed to load trading connection config: \(error.localizedDescription)"
        }

        do {
            let risk = try tradingRuntimeManager.currentRiskControls()
            staleQuoteField.stringValue = String(risk.staleQuoteThresholdMs)
            maxOrderField.stringValue = String(format: "%.0f", risk.maxOrderNotional)
            maxOpenField.stringValue = String(format: "%.0f", risk.maxOpenNotional)
        } catch {
            tradingStatusLabel.stringValue = "Failed to load trading risk controls: \(error.localizedDescription)"
        }
    }

    @objc
    private func tradingRuntimeTapped() {
        if tradingRuntimeManager.isStarted {
            tradingRuntimeManager.shutdown()
            tradingStatusLabel.stringValue = "Trading runtime stopped."
            return
        }

        syncTradingInputsToRuntime()
        let connected = tradingRuntimeManager.start()
        tradingStatusLabel.stringValue = connected
            ? "Trading runtime started and connected to TWS."
            : "Trading runtime started, but TWS is not connected yet."
    }

    @objc
    private func tradingInputChanged() {
        syncTradingInputsToRuntime()
    }

    @objc
    private func applyTradingConnectionTapped() {
        do {
            var config = try tradingRuntimeManager.currentConnectionConfig()
            config.host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.port = max(1, Int(portField.intValue))
            config.clientId = max(1, Int(clientIDField.intValue))
            try tradingRuntimeManager.updateConnectionConfig(config)
            tradingStatusLabel.stringValue = "Trading connection settings applied."
        } catch {
            tradingStatusLabel.stringValue = "Failed to apply connection settings: \(error.localizedDescription)"
        }
    }

    @objc
    private func applyTradingRiskTapped() {
        do {
            var risk = try tradingRuntimeManager.currentRiskControls()
            risk.staleQuoteThresholdMs = max(250, Int(staleQuoteField.intValue))
            risk.maxOrderNotional = max(100, maxOrderField.doubleValue)
            risk.maxOpenNotional = max(risk.maxOrderNotional, maxOpenField.doubleValue)
            try tradingRuntimeManager.updateRiskControls(risk)
            tradingStatusLabel.stringValue = "Trading risk controls applied."
        } catch {
            tradingStatusLabel.stringValue = "Failed to apply risk controls: \(error.localizedDescription)"
        }
    }

    @objc
    private func subscribeTapped() {
        syncTradingInputsToRuntime()
        do {
            let response = try tradingRuntimeManager.requestSubscription(
                symbol: symbolField.stringValue,
                recalcQtyFromFirstAsk: false
            )
            tradingStatusLabel.stringValue = "Subscribed to \(response.normalizedSymbol ?? symbolField.stringValue)."
        } catch {
            tradingStatusLabel.stringValue = "Subscribe failed: \(error.localizedDescription)"
        }
    }

    @objc
    private func buyTapped() {
        syncTradingInputsToRuntime()
        do {
            _ = try tradingRuntimeManager.submitBuy(source: "GUI Button", note: "Buy Limit button pressed")
            tradingStatusLabel.stringValue = "BUY submitted."
        } catch {
            tradingStatusLabel.stringValue = "Buy failed: \(error.localizedDescription)"
        }
    }

    @objc
    private func closeTapped() {
        syncTradingInputsToRuntime()
        do {
            _ = try tradingRuntimeManager.submitClose(source: "GUI Button", note: "Close Long button pressed")
            tradingStatusLabel.stringValue = "Close submitted."
        } catch {
            tradingStatusLabel.stringValue = "Close failed: \(error.localizedDescription)"
        }
    }

    @objc
    private func cancelAllTapped() {
        do {
            let response = try tradingRuntimeManager.cancelAll()
            let count = response.orderIds?.count ?? 0
            tradingStatusLabel.stringValue = count > 0
                ? "Cancel requested for \(count) order(s)."
                : "No pending orders to cancel."
        } catch {
            tradingStatusLabel.stringValue = "Cancel all failed: \(error.localizedDescription)"
        }
    }

    @objc
    private func armControllerTapped() {
        let nextArmed = !tradingRuntimeManager.dashboard.panel.status.controllerArmed
        tradingRuntimeManager.setControllerArmed(nextArmed)
        tradingStatusLabel.stringValue = nextArmed ? "Controller armed." : "Controller disarmed."
    }

    @objc
    private func killSwitchTapped() {
        let nextEnabled = !tradingRuntimeManager.dashboard.panel.status.tradingKillSwitch
        tradingRuntimeManager.setTradingKillSwitch(nextEnabled)
        tradingStatusLabel.stringValue = nextEnabled ? "Kill switch enabled." : "Kill switch disabled."
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

        let selectionContext: ROISelectionContext?
        switch type {
        case .manualCellROI:
            guard let baseROI = regionState.baseROI else {
                statusLabel.stringValue = "Select Base ROI first. Trigger cell selection is nested inside Base ROI."
                return
            }
            selectionContext = ROISelectionContext(parentRect: baseROI, label: "Base ROI")
        case .manualSymbolCellROI:
            guard let symbolROI = regionState.symbolROI else {
                statusLabel.stringValue = "Select Symbol ROI first. Symbol cell selection is nested inside Symbol ROI."
                return
            }
            selectionContext = ROISelectionContext(parentRect: symbolROI, label: "Symbol ROI")
        case .baseROI, .symbolROI:
            selectionContext = nil
        }

        do {
            let selectedRect = try roiSelector.selectRect(
                for: selectedDisplay,
                prompt: type.prompt,
                initialRect: currentRect(for: type),
                context: selectionContext
            )

            let clearedDependentSelection = setRect(selectedRect, for: type)
            regionState.sourceDescription = "Manual (unsaved)"
            syncRuntimeRegionState()

            var statusMessage = "\(type.statusTitle) updated for display \(selectedDisplay.id): \(selectedRect.summary)."
            switch type {
            case .baseROI:
                statusMessage += " Next: select Trigger cell from the nested Base ROI view."
                if clearedDependentSelection {
                    statusMessage += " Cleared previous Trigger cell selection."
                }
            case .symbolROI:
                statusMessage += " Next: select Symbol cell from the nested Symbol ROI view."
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
            return "Select the main OCR base ROI"
        case .manualCellROI:
            return "Select the numeric trigger cell ROI from the zoomed Base ROI view"
        case .symbolROI:
            return "Select the optional symbol ROI"
        case .manualSymbolCellROI:
            return "Select the optional symbol cell ROI from the zoomed Symbol ROI view"
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
