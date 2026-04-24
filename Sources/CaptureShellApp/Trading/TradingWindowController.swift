import AppKit
import Foundation

private enum LegacyOrderColumn: String, CaseIterable {
    case id
    case symbol
    case side
    case qty
    case price
    case local
    case broker
    case watchdog

    var title: String {
        switch self {
        case .id: return "ID"
        case .symbol: return "Symbol"
        case .side: return "Side"
        case .qty: return "Qty"
        case .price: return "Price"
        case .local: return "Local"
        case .broker: return "Broker"
        case .watchdog: return "Watchdog"
        }
    }

    var width: CGFloat {
        switch self {
        case .id: return 70
        case .symbol: return 90
        case .side: return 60
        case .qty: return 70
        case .price: return 90
        case .local: return 150
        case .broker: return 110
        case .watchdog: return 180
        }
    }
}

@MainActor
private func legacyAppBackgroundColor() -> NSColor {
    NSColor(calibratedWhite: 0.94, alpha: 1.0)
}

@MainActor
private func legacyPanelBackgroundColor() -> NSColor {
    NSColor(calibratedWhite: 0.985, alpha: 1.0)
}

@MainActor
private func legacyPanelBorderColor() -> NSColor {
    NSColor(calibratedWhite: 0.82, alpha: 1.0)
}

@MainActor
private func makeLegacyLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

@MainActor
private func makeLegacyWrappingLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.textColor = color
    return label
}

@MainActor
private func makeLegacyValueLabel() -> NSTextField {
    makeLegacyLabel("--", font: .monospacedSystemFont(ofSize: 13, weight: .medium))
}

@MainActor
private func makeLegacyInputField(
    _ text: String,
    width: CGFloat,
    target: AnyObject?,
    action: Selector?,
    delegate: NSTextFieldDelegate?
) -> NSTextField {
    let field = NSTextField(frame: .zero)
    field.stringValue = text
    field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    field.backgroundColor = .white
    field.textColor = .labelColor
    field.bezelStyle = .roundedBezel
    field.target = target
    field.action = action
    field.delegate = delegate
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: width).isActive = true
    return field
}

@MainActor
private func makeLegacyButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .large
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    return button
}

@MainActor
private func makeLegacyRowStack(_ views: [NSView] = []) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

@MainActor
private func makeLegacyColumnStack(_ views: [NSView] = []) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

@MainActor
private func makeLegacyFlexibleSpacer() -> NSView {
    let spacer = NSView(frame: .zero)
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
}

@MainActor
private func makeLegacyReadOnlyTextView() -> NSTextView {
    let textView = NSTextView(frame: .zero)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textColor = .labelColor
    textView.backgroundColor = .white
    return textView
}

@MainActor
private func makeLegacyScrollView(documentView: NSView, minHeight: CGFloat) -> NSScrollView {
    let scrollView = NSScrollView(frame: .zero)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .bezelBorder
    scrollView.documentView = documentView
    scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
    return scrollView
}

@MainActor
private func styleLegacyPanel(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = legacyPanelBackgroundColor().cgColor
    view.layer?.cornerRadius = 14
    view.layer?.borderWidth = 1
    view.layer?.borderColor = legacyPanelBorderColor().cgColor
}

@MainActor
private func styleLegacyTintedButton(_ button: NSButton, bezelColor: NSColor, tintColor: NSColor = .white) {
    button.bezelColor = bezelColor
    button.contentTintColor = tintColor
}

@MainActor
private func setLegacyButtonAvailability(_ button: NSButton, enabled: Bool, activeColor: NSColor, toolTip: String?) {
    button.isEnabled = true
    button.bezelColor = enabled ? activeColor : NSColor(calibratedWhite: 0.55, alpha: 1)
    button.contentTintColor = .white
    button.toolTip = enabled ? nil : toolTip
}

@MainActor
private func setLegacyEnabledTint(_ button: NSButton, enabled: Bool, enabledColor: NSColor, disabledColor: NSColor) {
    button.isEnabled = enabled
    button.bezelColor = enabled ? enabledColor : disabledColor
    button.contentTintColor = enabled ? .white : .secondaryLabelColor
}

@MainActor
private func legacyFormatPrice(_ value: Double) -> String {
    value > 0 ? String(format: "$%.2f", value) : "--"
}

@MainActor
private func legacyFormatSignedCurrency(_ value: Double) -> String {
    if value > 0 { return String(format: "+$%.2f", value) }
    if value < 0 { return String(format: "-$%.2f", abs(value)) }
    return "$0.00"
}

@MainActor
private func legacyBuyUnavailableReason(_ snapshot: TradingDashboardSnapshot) -> String {
    let status = snapshot.panel.status
    let panel = snapshot.panel
    if !status.connected { return "TWS is disconnected." }
    if !status.sessionReady { return "TWS session is still initializing." }
    if !snapshot.inputs.subscribed { return "Subscribe to a symbol first." }
    if !panel.symbol.hasFreshQuote { return "Waiting for a fresh quote." }
    if status.tradingKillSwitch { return "Kill switch is enabled." }
    if panel.risk.maxOrderNotional > 0, panel.orderNotional > panel.risk.maxOrderNotional {
        return "Order exceeds the max order notional limit."
    }
    if panel.risk.maxOpenNotional > 0, panel.projectedOpenNotional > panel.risk.maxOpenNotional {
        return "Projected exposure exceeds the max open notional limit."
    }
    return "Buy is not currently available."
}

@MainActor
private func legacyCloseUnavailableReason(_ snapshot: TradingDashboardSnapshot) -> String {
    let status = snapshot.panel.status
    let panel = snapshot.panel
    if !status.connected { return "TWS is disconnected." }
    if !status.sessionReady { return "TWS session is still initializing." }
    if !snapshot.inputs.subscribed { return "Subscribe to a symbol first." }
    if !panel.symbol.hasFreshQuote { return "Waiting for a fresh quote." }
    if status.tradingKillSwitch { return "Kill switch is enabled." }
    if panel.symbol.availableLongToClose <= 0 { return "There is no long position to close." }
    return "Close is not currently available."
}

@MainActor
private func legacyCancelUnavailableReason(_ snapshot: TradingDashboardSnapshot) -> String {
    let status = snapshot.panel.status
    if !status.connected { return "TWS is disconnected." }
    if !snapshot.panel.hasCancelableOrders { return "There are no working orders to cancel." }
    return "Cancel All is not currently available."
}

@MainActor
private func legacyControllerSafetyText(_ snapshot: TradingDashboardSnapshot) -> String {
    if !snapshot.panel.risk.controllerArmed {
        return "controller disarmed"
    }
    return snapshot.panel.risk.controllerArmMode == "manual"
        ? "controller armed (manual)"
        : "controller armed (1-shot)"
}

@MainActor
final class TradingWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let manager: TradingRuntimeManager
    private let onOpenSetup: () -> Void
    private let onStartLiveStream: (String) -> Void
    private let onStopLiveStream: () -> Void
    private let onLiveStreamURLChanged: (String) -> Void
    private let onOCRBuyRatioChanged: (Double) -> Void

    private var dashboard: TradingDashboardSnapshot
    private var liveStatus = LiveOCRSessionStatusSnapshot.off
    private var refreshTimer: Timer?
    private var recoveryMaintenanceInFlight = false

    private let twsStatusLabel = makeLegacyLabel("TWS: Disconnected", font: .systemFont(ofSize: 13, weight: .semibold), color: .systemRed)
    private let accountStatusLabel = makeLegacyLabel("Account: --", font: .systemFont(ofSize: 13, weight: .medium))
    private let directLinkStatusLabel = makeLegacyLabel("Link: Direct OCR", font: .systemFont(ofSize: 13, weight: .medium), color: .systemGreen)
    private let liveStatusLabel = makeLegacyLabel("Live: Off", font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor)
    private let buildModeBannerLabel = makeLegacyLabel("", font: .systemFont(ofSize: 12, weight: .semibold), color: .systemOrange)
    private let recoveryBannerLabel = makeLegacyLabel("", font: .systemFont(ofSize: 12, weight: .semibold), color: .systemRed)

    private lazy var liveURLField = makeLegacyInputField("", width: 360, target: self, action: #selector(liveStreamFieldAction), delegate: self)
    private lazy var symbolField = makeLegacyInputField("", width: 120, target: self, action: #selector(subscribeAction), delegate: self)
    private let marketHeaderLabel = makeLegacyLabel("Market Data: waiting for a subscription", font: .systemFont(ofSize: 15, weight: .semibold))
    private let bidLabel = makeLegacyValueLabel()
    private let askLabel = makeLegacyValueLabel()
    private let lastLabel = makeLegacyValueLabel()
    private let positionLabel = makeLegacyValueLabel()
    private let pnlLabel = makeLegacyValueLabel()
    private let bookDepthLabel = makeLegacyValueLabel()
    private let liveMetricsLabel = makeLegacyLabel("Live OCR is off.", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
    private let pricePreviewLabel = makeLegacyLabel("Prices: buy --  |  sell --", font: .monospacedSystemFont(ofSize: 13, weight: .medium))
    private let safetyStatusLabel = makeLegacyLabel("Safety: quote waiting  |  controller disarmed  |  kill switch off", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
    private let controllerHintLabel = makeLegacyLabel("Controller: Square buy  |  Circle close  |  Triangle cancel all  |  Cross toggle qty", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)

    private lazy var quantityField = makeLegacyInputField("1", width: 72, target: self, action: #selector(inputFieldAction), delegate: self)
    private lazy var bufferField = makeLegacyInputField("0.01", width: 80, target: self, action: #selector(inputFieldAction), delegate: self)
    private lazy var maxPositionField = makeLegacyInputField("40000", width: 110, target: self, action: #selector(inputFieldAction), delegate: self)
    private lazy var ocrRatioField = makeLegacyInputField("0.50", width: 80, target: self, action: #selector(ocrRatioFieldAction), delegate: self)

    private lazy var liveStartStopButton = makeLegacyButton("Start Live OCR", target: self, action: #selector(toggleLiveStream))
    private lazy var subscribeButton = makeLegacyButton("Subscribe", target: self, action: #selector(subscribeAction))
    private lazy var buyButton = makeLegacyButton("Buy Limit", target: self, action: #selector(buyAction))
    private lazy var closeButton = makeLegacyButton("Close Long", target: self, action: #selector(closeAction))
    private lazy var cancelAllButton = makeLegacyButton("Cancel All", target: self, action: #selector(cancelAllAction))
    private lazy var cancelSelectedButton = makeLegacyButton("Cancel Selected", target: self, action: #selector(cancelSelectedAction))
    private lazy var reconcileSelectedButton = makeLegacyButton("Reconcile Selected", target: self, action: #selector(reconcileSelectedAction))
    private lazy var acknowledgeSelectedButton = makeLegacyButton("Acknowledge", target: self, action: #selector(acknowledgeSelectedAction))
    private lazy var armControllerButton = makeLegacyButton("Arm Controller", target: self, action: #selector(toggleControllerArmed))
    private lazy var killSwitchButton = makeLegacyButton("Enable Kill Switch", target: self, action: #selector(toggleKillSwitch))
    private lazy var loadRecoveryButton = makeLegacyButton("Load Logs", target: self, action: #selector(loadRecoveryFromLogs))
    private lazy var deleteLogsButton = makeLegacyButton("Delete Logs", target: self, action: #selector(deletePersistedLogs))
    private lazy var settingsButton = makeLegacyButton("Settings", target: self, action: #selector(openSettings))
    private lazy var exportTraceButton = makeLegacyButton("Export Trace", target: self, action: #selector(exportSelectedTrace))
    private lazy var exportAllButton = makeLegacyButton("Export All CSV", target: self, action: #selector(exportAllTracesSummary))

    private let ordersTable = NSTableView(frame: .zero)
    private let tracePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let traceTextView = makeLegacyReadOnlyTextView()
    private let messagesTextView = makeLegacyReadOnlyTextView()

    init(
        manager: TradingRuntimeManager,
        onOpenSetup: @escaping () -> Void,
        onStartLiveStream: @escaping (String) -> Void,
        onStopLiveStream: @escaping () -> Void,
        onLiveStreamURLChanged: @escaping (String) -> Void,
        onOCRBuyRatioChanged: @escaping (Double) -> Void
    ) {
        self.manager = manager
        self.onOpenSetup = onOpenSetup
        self.onStartLiveStream = onStartLiveStream
        self.onStopLiveStream = onStopLiveStream
        self.onLiveStreamURLChanged = onLiveStreamURLChanged
        self.onOCRBuyRatioChanged = onOCRBuyRatioChanged
        self.dashboard = manager.dashboard

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1540, height: 980),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TWS Trading GUI"
        window.minSize = NSSize(width: 1100, height: 700)
        window.collectionBehavior = .moveToActiveSpace
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        buildInterface()
        self.window?.delegate = self
        updateDashboard(manager.dashboard)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndStart() {
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshTimer()
        if !manager.isStarted {
            let startResult = manager.startWithAutoConnectFallback()
            if let autoDetectedConfig = startResult.autoDetectedConfig {
                appendMessage("Auto-detected IB connection at \(autoDetectedConfig.host):\(autoDetectedConfig.port)")
            } else if !startResult.connected, !startResult.attemptedFallbackPorts.isEmpty {
                let ports = startResult.attemptedFallbackPorts.map(String.init).joined(separator: ", ")
                appendMessage("Tried common IB ports (\(ports)) after the default connection failed")
            }
        } else {
            manager.refreshDashboard()
        }
    }

    func updateDashboard(_ dashboard: TradingDashboardSnapshot) {
        self.dashboard = dashboard
        refreshInterface()
    }

    func updateLiveStatus(_ liveStatus: LiveOCRSessionStatusSnapshot) {
        self.liveStatus = liveStatus
        refreshLiveSection()
    }

    func updateOCRBuyRatio(_ ratio: Double) {
        guard !isEditingField(ocrRatioField) else {
            return
        }
        ocrRatioField.stringValue = String(format: "%.2f", ratio)
    }

    func setLiveURLText(_ urlText: String, force: Bool = false) {
        guard force || !isEditingField(liveURLField) else {
            return
        }
        liveURLField.stringValue = urlText
    }

    var currentLiveStreamURLText: String {
        liveURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }

        if field === symbolField {
            syncInputsToRuntime()
        } else if field === liveURLField {
            onLiveStreamURLChanged(currentLiveStreamURLText)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === liveURLField {
            onLiveStreamURLChanged(currentLiveStreamURLText)
        } else if let field = notification.object as? NSTextField, field === ocrRatioField {
            onOCRBuyRatioChanged(sanitizedOCRBuyRatio())
        }
        syncInputsToRuntime()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == ordersTable ? dashboard.orders.count : 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView == ordersTable, row >= 0, row < dashboard.orders.count, let column = tableColumn else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier(column.identifier.rawValue)
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = makeLegacyLabel("", font: .monospacedSystemFont(ofSize: 12, weight: .regular))
            label.identifier = identifier
        }

        let order = dashboard.orders[row]
        switch LegacyOrderColumn(rawValue: column.identifier.rawValue) {
        case .id:
            label.stringValue = String(order.orderId)
            label.textColor = .labelColor
        case .symbol:
            label.stringValue = order.symbol
            label.textColor = .labelColor
        case .side:
            label.stringValue = order.side
            label.textColor = order.side == "BUY" ? .systemGreen : .systemRed
        case .qty:
            label.stringValue = String(format: "%.0f", order.quantity)
            label.textColor = .labelColor
        case .price:
            label.stringValue = String(format: "$%.2f", order.avgFillPrice > 0 ? order.avgFillPrice : order.limitPrice)
            label.textColor = order.avgFillPrice > 0 ? .systemOrange : .labelColor
        case .local:
            label.stringValue = order.localStateText ?? order.localState
            label.textColor = localStateColor(order)
        case .broker:
            label.stringValue = order.status
            label.textColor = .labelColor
        case .watchdog:
            label.stringValue = order.watchdogText ?? order.timingText ?? "--"
            label.textColor = watchdogColor(order)
        case .none:
            label.stringValue = ""
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView, tableView == ordersTable else {
            return
        }
        refreshOrders()
        let selected = selectedOrderIDs()
        if let firstOrderID = selected.first,
           let traceItem = dashboard.traceItems.first(where: { $0.orderId == firstOrderID }) {
            syncInputsToRuntime(selectedTraceID: traceItem.traceId)
            manager.refreshDashboard()
        }
    }

    private func buildInterface() {
        guard let window, let contentView = window.contentView else { return }
        NSApp.appearance = NSAppearance(named: .aqua)
        window.appearance = NSAppearance(named: .aqua)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = legacyAppBackgroundColor().cgColor

        styleLegacyTintedButton(subscribeButton, bezelColor: NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.95, alpha: 1))
        styleLegacyTintedButton(liveStartStopButton, bezelColor: NSColor(calibratedRed: 0.13, green: 0.48, blue: 0.82, alpha: 1))
        styleLegacyTintedButton(buyButton, bezelColor: NSColor(calibratedRed: 0.13, green: 0.64, blue: 0.32, alpha: 1))
        styleLegacyTintedButton(closeButton, bezelColor: NSColor(calibratedRed: 0.96, green: 0.60, blue: 0.18, alpha: 1))
        styleLegacyTintedButton(cancelAllButton, bezelColor: NSColor(calibratedRed: 0.90, green: 0.27, blue: 0.22, alpha: 1))
        styleLegacyTintedButton(cancelSelectedButton, bezelColor: NSColor(calibratedRed: 0.90, green: 0.27, blue: 0.22, alpha: 1))
        styleLegacyTintedButton(reconcileSelectedButton, bezelColor: NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.92, alpha: 1))
        styleLegacyTintedButton(acknowledgeSelectedButton, bezelColor: NSColor(calibratedRed: 0.78, green: 0.45, blue: 0.15, alpha: 1))
        styleLegacyTintedButton(settingsButton, bezelColor: NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.70, alpha: 1))

        [armControllerButton, killSwitchButton, loadRecoveryButton, deleteLogsButton, settingsButton].forEach {
            styleLegacyTintedButton($0, bezelColor: NSColor(calibratedWhite: 0.40, alpha: 1))
        }

        let rootStack = makeLegacyColumnStack()
        rootStack.spacing = 16
        rootStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let statusLabels = makeLegacyRowStack([twsStatusLabel, accountStatusLabel, directLinkStatusLabel, liveStatusLabel])
        statusLabels.spacing = 18

        armControllerButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        killSwitchButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
        loadRecoveryButton.widthAnchor.constraint(equalToConstant: 122).isActive = true
        deleteLogsButton.widthAnchor.constraint(equalToConstant: 122).isActive = true
        settingsButton.title = "OCR Setup"
        settingsButton.widthAnchor.constraint(equalToConstant: 118).isActive = true

        let statusControls = makeLegacyRowStack([armControllerButton, killSwitchButton, loadRecoveryButton, deleteLogsButton])
        statusControls.spacing = 12

        let statusRow = makeLegacyRowStack([statusLabels, makeLegacyFlexibleSpacer(), statusControls])
        rootStack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        buildModeBannerLabel.isHidden = true
        recoveryBannerLabel.isHidden = true
        rootStack.addArrangedSubview(buildModeBannerLabel)
        rootStack.addArrangedSubview(recoveryBannerLabel)
        buildModeBannerLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        recoveryBannerLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let bodySplit = NSSplitView(frame: .zero)
        bodySplit.translatesAutoresizingMaskIntoConstraints = false
        bodySplit.isVertical = true
        bodySplit.dividerStyle = .thin
        rootStack.addArrangedSubview(bodySplit)
        bodySplit.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        bodySplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 760).isActive = true

        let leftPanel = NSView(frame: .zero)
        let rightPanel = NSView(frame: .zero)
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        styleLegacyPanel(leftPanel)
        styleLegacyPanel(rightPanel)
        bodySplit.addSubview(leftPanel)
        bodySplit.addSubview(rightPanel)
        leftPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        rightPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        let leftStack = makeLegacyColumnStack()
        let rightStack = makeLegacyColumnStack()
        leftStack.spacing = 14
        rightStack.spacing = 14
        leftPanel.addSubview(leftStack)
        rightPanel.addSubview(rightStack)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor, constant: 18),
            leftStack.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor, constant: -18),
            leftStack.topAnchor.constraint(equalTo: leftPanel.topAnchor, constant: 18),
            leftStack.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor, constant: -18),
            rightStack.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 18),
            rightStack.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -18),
            rightStack.topAnchor.constraint(equalTo: rightPanel.topAnchor, constant: 18),
            rightStack.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor, constant: -18)
        ])

        liveStartStopButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        subscribeButton.widthAnchor.constraint(equalToConstant: 116).isActive = true

        let liveRow = makeLegacyRowStack([
            makeLegacyLabel("Live URL", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor),
            liveURLField,
            liveStartStopButton,
            settingsButton
        ])
        leftStack.addArrangedSubview(liveRow)
        liveRow.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        leftStack.addArrangedSubview(liveMetricsLabel)
        liveMetricsLabel.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        let symbolRow = makeLegacyRowStack([
            makeLegacyLabel("Symbol", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor),
            symbolField,
            subscribeButton
        ])
        leftStack.addArrangedSubview(symbolRow)
        symbolRow.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        leftStack.addArrangedSubview(marketHeaderLabel)
        marketHeaderLabel.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        let marketGrid = NSGridView(views: [
            [makeLegacyLabel("Bid", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor), bidLabel, makeLegacyLabel("Ask", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor), askLabel],
            [makeLegacyLabel("Last", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor), lastLabel, makeLegacyLabel("Book", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor), bookDepthLabel],
            [makeLegacyLabel("Position", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor), positionLabel, makeLegacyLabel("P&L", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor), pnlLabel]
        ])
        marketGrid.rowSpacing = 8
        marketGrid.columnSpacing = 12
        marketGrid.xPlacement = .leading
        marketGrid.yPlacement = .center
        leftStack.addArrangedSubview(marketGrid)
        marketGrid.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        let inputRow = makeLegacyRowStack([
            makeLegacyLabel("Qty", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor),
            quantityField,
            makeLegacyLabel("OCR Ratio", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor),
            ocrRatioField,
            makeLegacyLabel("Buffer", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor),
            bufferField,
            makeLegacyLabel("Max Position $", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor),
            maxPositionField
        ])
        leftStack.addArrangedSubview(inputRow)
        inputRow.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        leftStack.addArrangedSubview(pricePreviewLabel)
        leftStack.addArrangedSubview(safetyStatusLabel)
        leftStack.addArrangedSubview(controllerHintLabel)
        pricePreviewLabel.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
        safetyStatusLabel.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
        controllerHintLabel.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        buyButton.widthAnchor.constraint(equalToConstant: 170).isActive = true
        closeButton.widthAnchor.constraint(equalToConstant: 210).isActive = true
        cancelAllButton.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let actionRow = makeLegacyRowStack([buyButton, closeButton, cancelAllButton])
        leftStack.addArrangedSubview(actionRow)
        actionRow.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        leftStack.addArrangedSubview(makeLegacyLabel("Working Orders", font: .systemFont(ofSize: 15, weight: .semibold)))

        ordersTable.delegate = self
        ordersTable.dataSource = self
        ordersTable.usesAlternatingRowBackgroundColors = true
        ordersTable.allowsMultipleSelection = true
        ordersTable.rowHeight = 24
        for column in LegacyOrderColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.resizingMask = .autoresizingMask
            ordersTable.addTableColumn(tableColumn)
        }
        let ordersScrollView = makeLegacyScrollView(documentView: ordersTable, minHeight: 280)
        leftStack.addArrangedSubview(ordersScrollView)
        ordersScrollView.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        cancelSelectedButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        reconcileSelectedButton.widthAnchor.constraint(equalToConstant: 170).isActive = true
        acknowledgeSelectedButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let orderButtons = makeLegacyRowStack([cancelSelectedButton, reconcileSelectedButton, acknowledgeSelectedButton])
        leftStack.addArrangedSubview(orderButtons)
        orderButtons.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true

        rightStack.addArrangedSubview(makeLegacyLabel("Trade Trace", font: .systemFont(ofSize: 15, weight: .semibold)))
        tracePopup.target = self
        tracePopup.action = #selector(traceSelectionChanged)
        rightStack.addArrangedSubview(tracePopup)
        tracePopup.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true

        exportTraceButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        exportAllButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let exportRow = makeLegacyRowStack([exportTraceButton, exportAllButton])
        rightStack.addArrangedSubview(exportRow)
        exportRow.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true

        let traceScrollView = makeLegacyScrollView(documentView: traceTextView, minHeight: 320)
        rightStack.addArrangedSubview(traceScrollView)
        traceScrollView.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true

        rightStack.addArrangedSubview(makeLegacyLabel("Messages", font: .systemFont(ofSize: 15, weight: .semibold)))
        let messagesScrollView = makeLegacyScrollView(documentView: messagesTextView, minHeight: 240)
        rightStack.addArrangedSubview(messagesScrollView)
        messagesScrollView.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(refreshTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    private func syncInputsToRuntime(selectedTraceID: UInt64? = nil) {
        manager.setUIInputs(
            symbolInput: symbolField.stringValue,
            subscribedSymbol: dashboard.inputs.subscribedSymbol,
            subscribed: dashboard.inputs.subscribed,
            quantityInput: max(1, Int(quantityField.intValue)),
            priceBuffer: max(0, bufferField.doubleValue),
            maxPositionDollars: max(1000, maxPositionField.doubleValue),
            selectedTraceId: selectedTraceID ?? dashboard.inputs.selectedTraceId
        )
    }

    private func selectedOrderIDs() -> [Int] {
        let indexes = ordersTable.selectedRowIndexes
        return indexes.compactMap { index in
            guard dashboard.orders.indices.contains(index) else { return nil }
            return dashboard.orders[index].orderId
        }
    }

    private func refreshInterface() {
        updateInputFieldsFromState()
        refreshStatusLabels()
        refreshLiveSection()
        refreshMarketSection()
        refreshOrders()
        refreshTracePopup()

        if traceTextView.string != dashboard.traceDetailsText {
            traceTextView.string = dashboard.traceDetailsText
        }

        exportTraceButton.isEnabled = dashboard.canExportSelectedTrace ?? false
        exportAllButton.isEnabled = dashboard.canExportAllTraces ?? false

        let nextMessages = dashboard.messagesText
        if messagesTextView.string != nextMessages {
            messagesTextView.string = nextMessages
        }
    }

    private func refreshStatusLabels() {
        let status = dashboard.panel.status
        if status.connected && status.sessionReady {
            twsStatusLabel.stringValue = "TWS: Ready"
            twsStatusLabel.textColor = .systemGreen
        } else if status.connected {
            twsStatusLabel.stringValue = "TWS: \(status.sessionStateText)"
            twsStatusLabel.textColor = .systemOrange
        } else {
            twsStatusLabel.stringValue = "TWS: Disconnected"
            twsStatusLabel.textColor = .systemRed
        }

        accountStatusLabel.stringValue = "Account: \(status.accountText)"
        directLinkStatusLabel.stringValue = "Link: OCR direct in-process"
        directLinkStatusLabel.textColor = .systemGreen

        armControllerButton.title = status.controllerArmed ? "Disarm Controller" : "Arm Controller"
        setLegacyEnabledTint(
            armControllerButton,
            enabled: status.controllerEnabled && status.controllerConnected,
            enabledColor: status.controllerArmed ? .systemOrange : .systemBlue,
            disabledColor: NSColor(calibratedWhite: 0.86, alpha: 1)
        )

        killSwitchButton.title = status.tradingKillSwitch ? "Disable Kill Switch" : "Enable Kill Switch"
        setLegacyEnabledTint(
            killSwitchButton,
            enabled: true,
            enabledColor: status.tradingKillSwitch ? .systemRed : NSColor(calibratedWhite: 0.40, alpha: 1),
            disabledColor: NSColor(calibratedWhite: 0.86, alpha: 1)
        )

        setLegacyEnabledTint(
            loadRecoveryButton,
            enabled: !recoveryMaintenanceInFlight,
            enabledColor: NSColor(calibratedRed: 0.16, green: 0.56, blue: 0.58, alpha: 1),
            disabledColor: NSColor(calibratedWhite: 0.86, alpha: 1)
        )
        setLegacyEnabledTint(
            deleteLogsButton,
            enabled: !recoveryMaintenanceInFlight,
            enabledColor: NSColor(calibratedRed: 0.75, green: 0.28, blue: 0.22, alpha: 1),
            disabledColor: NSColor(calibratedWhite: 0.86, alpha: 1)
        )

        if status.startupRecoveryBanner.isEmpty {
            recoveryBannerLabel.isHidden = true
            recoveryBannerLabel.stringValue = ""
        } else {
            recoveryBannerLabel.isHidden = false
            recoveryBannerLabel.stringValue = status.startupRecoveryBanner
        }
        buildModeBannerLabel.isHidden = true
    }

    private func refreshLiveSection() {
        liveStatusLabel.stringValue = liveStatus.headline.replacingOccurrences(of: "stream: ", with: ": ")
        switch liveStatus.state {
        case .off:
            liveStatusLabel.textColor = .secondaryLabelColor
        case .connecting:
            liveStatusLabel.textColor = .systemOrange
        case .live:
            liveStatusLabel.textColor = .systemGreen
        case .error:
            liveStatusLabel.textColor = .systemRed
        }

        liveMetricsLabel.stringValue = liveStatus.detail
        liveMetricsLabel.textColor = liveStatus.state == .error ? .systemRed : .secondaryLabelColor
        liveStartStopButton.title = liveStatus.isRunning ? "Stop Live OCR" : "Start Live OCR"
        liveStartStopButton.bezelColor = liveStatus.isRunning
            ? NSColor(calibratedRed: 0.70, green: 0.20, blue: 0.18, alpha: 1)
            : NSColor(calibratedRed: 0.13, green: 0.48, blue: 0.82, alpha: 1)

        if !isEditingField(liveURLField) {
            liveURLField.stringValue = liveStatus.seedURLText
        }

        if !isEditingField(ocrRatioField) {
            ocrRatioField.stringValue = sanitizedOCRBuyRatioString()
        }

        settingsButton.isEnabled = !dashboard.panel.status.controllerArmed
        settingsButton.toolTip = dashboard.panel.status.controllerArmed
            ? "Disarm the controller before editing OCR ROIs."
            : nil
    }

    private func refreshMarketSection() {
        let panel = dashboard.panel
        if dashboard.inputs.subscribed, !dashboard.inputs.subscribedSymbol.isEmpty {
            marketHeaderLabel.stringValue = "Market Data: \(dashboard.inputs.subscribedSymbol)"
        } else {
            marketHeaderLabel.stringValue = "Market Data: waiting for a subscription"
        }

        bidLabel.stringValue = legacyFormatPrice(panel.symbol.bidPrice)
        askLabel.stringValue = legacyFormatPrice(panel.symbol.askPrice)
        lastLabel.stringValue = legacyFormatPrice(panel.symbol.lastPrice)
        bookDepthLabel.stringValue = "\(panel.askLevels) ask / \(panel.bidLevels) bid"

        if panel.symbol.hasPosition && panel.symbol.currentPositionQty != 0 {
            if panel.symbol.currentPositionQty > 0 {
                positionLabel.stringValue = String(format: "%.0f LONG", panel.symbol.currentPositionQty)
                positionLabel.textColor = .systemGreen
            } else {
                positionLabel.stringValue = String(format: "%.0f SHORT", -panel.symbol.currentPositionQty)
                positionLabel.textColor = .systemRed
            }
            let currentPrice = panel.symbol.lastPrice > 0 ? panel.symbol.lastPrice : panel.symbol.bidPrice
            if currentPrice > 0 && panel.symbol.currentPositionAvgCost > 0 {
                let pnl = (currentPrice - panel.symbol.currentPositionAvgCost) * panel.symbol.currentPositionQty
                pnlLabel.stringValue = legacyFormatSignedCurrency(pnl)
                pnlLabel.textColor = pnl > 0 ? .systemGreen : (pnl < 0 ? .systemRed : .secondaryLabelColor)
            } else {
                pnlLabel.stringValue = "--"
                pnlLabel.textColor = .secondaryLabelColor
            }
        } else {
            positionLabel.stringValue = "FLAT"
            positionLabel.textColor = .secondaryLabelColor
            pnlLabel.stringValue = "--"
            pnlLabel.textColor = .secondaryLabelColor
        }

        let buySegment = panel.buySweepAvailable
            ? String(format: "buy %@ (sweep+%.2f)", legacyFormatPrice(panel.buyPrice), dashboard.inputs.priceBuffer)
            : String(format: "buy %@ (ask+%.2f)", legacyFormatPrice(panel.buyPrice), dashboard.inputs.priceBuffer)
        let sellSegment = panel.sellSweepAvailable
            ? String(format: "sell %@ (sweep-%.2f)", legacyFormatPrice(panel.sellPrice), dashboard.inputs.priceBuffer)
            : String(format: "sell %@ (bid-%.2f)", legacyFormatPrice(panel.sellPrice), dashboard.inputs.priceBuffer)
        pricePreviewLabel.stringValue = "Prices: \(buySegment)  |  \(sellSegment)"

        let quoteSegment = panel.symbol.quoteAgeMs >= 0 ? String(format: "quote %.0f ms", panel.symbol.quoteAgeMs) : "quote waiting"
        let armSegment = legacyControllerSafetyText(dashboard)
        let killSegment = panel.status.tradingKillSwitch ? "kill switch ON" : "kill switch off"
        let exposureSegment = String(format: "open $%.0f / cap $%.0f", panel.projectedOpenNotional, panel.risk.maxOpenNotional)
        safetyStatusLabel.stringValue = "Safety: \(quoteSegment)  |  \(armSegment)  |  \(killSegment)  |  \(exposureSegment)"
        safetyStatusLabel.textColor = panel.status.tradingKillSwitch ? .systemRed : (panel.symbol.hasFreshQuote ? .secondaryLabelColor : .systemOrange)

        setLegacyButtonAvailability(
            buyButton,
            enabled: panel.canBuy,
            activeColor: NSColor(calibratedRed: 0.13, green: 0.64, blue: 0.32, alpha: 1),
            toolTip: legacyBuyUnavailableReason(dashboard)
        )
        setLegacyButtonAvailability(
            closeButton,
            enabled: panel.canClosePosition,
            activeColor: NSColor(calibratedRed: 0.96, green: 0.60, blue: 0.18, alpha: 1),
            toolTip: legacyCloseUnavailableReason(dashboard)
        )
        setLegacyButtonAvailability(
            cancelAllButton,
            enabled: panel.hasCancelableOrders,
            activeColor: NSColor(calibratedRed: 0.90, green: 0.27, blue: 0.22, alpha: 1),
            toolTip: legacyCancelUnavailableReason(dashboard)
        )

        buyButton.title = panel.buyPrice > 0 ? String(format: "Buy Limit @ %.2f", panel.buyPrice) : "Buy Limit"
        if panel.symbol.availableLongToClose > 0 && panel.sellPrice > 0 {
            closeButton.title = String(format: "Close Long (%.0f) @ %.2f", panel.symbol.availableLongToClose, panel.sellPrice)
        } else if panel.symbol.availableLongToClose > 0 {
            closeButton.title = String(format: "Close Long (%.0f)", panel.symbol.availableLongToClose)
        } else {
            closeButton.title = "Close Long"
        }

        controllerHintLabel.stringValue = panel.status.controllerEnabled
            ? "Controller: Square buy  |  Circle close  |  Triangle cancel all  |  Cross toggle qty"
            : "Controller input is disabled in Settings."
    }

    private func refreshOrders() {
        ordersTable.reloadData()
        let selected = selectedOrderIDs()
        let selectedOrders = dashboard.orders.filter { selected.contains($0.orderId) }
        let hasSelectedOrders = !selectedOrders.isEmpty
        let hasSelectedActiveOrders = selectedOrders.contains { !$0.localState.contains("filled") && !$0.localState.contains("cancelled") && !$0.localState.contains("rejected") && !$0.localState.contains("inactive") }
        let hasSelectedManualReviewOrders = selectedOrders.contains { ($0.localState == "needs_manual_review") && !($0.manualReviewAcknowledged ?? false) }

        setLegacyEnabledTint(cancelSelectedButton, enabled: hasSelectedOrders, enabledColor: NSColor(calibratedRed: 0.90, green: 0.27, blue: 0.22, alpha: 1), disabledColor: NSColor(calibratedWhite: 0.86, alpha: 1))
        setLegacyEnabledTint(reconcileSelectedButton, enabled: hasSelectedActiveOrders, enabledColor: NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.92, alpha: 1), disabledColor: NSColor(calibratedWhite: 0.86, alpha: 1))
        setLegacyEnabledTint(acknowledgeSelectedButton, enabled: hasSelectedManualReviewOrders, enabledColor: NSColor(calibratedRed: 0.78, green: 0.45, blue: 0.15, alpha: 1), disabledColor: NSColor(calibratedWhite: 0.86, alpha: 1))
    }

    private func refreshTracePopup() {
        if dashboard.traceItems.isEmpty {
            tracePopup.removeAllItems()
            tracePopup.addItem(withTitle: "No trade trace yet")
            tracePopup.isEnabled = false
            return
        }

        tracePopup.removeAllItems()
        tracePopup.isEnabled = true
        var selectedIndex = 0
        for (index, item) in dashboard.traceItems.enumerated() {
            tracePopup.addItem(withTitle: item.summary)
            if item.traceId == dashboard.inputs.selectedTraceId {
                selectedIndex = index
            }
        }
        tracePopup.selectItem(at: selectedIndex)
    }

    private func updateInputFieldsFromState() {
        if !isEditingField(quantityField) {
            quantityField.stringValue = String(dashboard.inputs.quantityInput)
        }
        if !isEditingField(ocrRatioField) {
            ocrRatioField.stringValue = sanitizedOCRBuyRatioString()
        }
        if !isEditingField(bufferField) {
            bufferField.stringValue = String(format: "%.2f", dashboard.inputs.priceBuffer)
        }
        if !isEditingField(maxPositionField) {
            maxPositionField.stringValue = String(format: "%.0f", dashboard.inputs.maxPositionDollars)
        }
        if !isEditingField(symbolField) {
            symbolField.stringValue = dashboard.inputs.symbolInput
        }
        if !isEditingField(liveURLField), !liveStatus.seedURLText.isEmpty {
            liveURLField.stringValue = liveStatus.seedURLText
        }
    }

    private func isEditingField(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor(), let window = field.window else {
            return false
        }
        return window.firstResponder == editor
    }

    private func sanitizedOCRBuyRatio() -> Double {
        let ratio = ocrRatioField.doubleValue
        return ratio.isFinite && ratio > 0 ? ratio : 0.5
    }

    private func sanitizedOCRBuyRatioString() -> String {
        String(format: "%.2f", sanitizedOCRBuyRatio())
    }

    private func localStateColor(_ order: TradingDashboardSnapshot.Order) -> NSColor {
        switch order.localState {
        case "awaiting_broker_echo", "awaiting_cancel_ack", "needs_reconciliation":
            return .systemOrange
        case "needs_manual_review":
            return .systemRed
        case "filled":
            return .systemGreen
        case "cancelled", "rejected", "inactive":
            return .secondaryLabelColor
        default:
            return .labelColor
        }
    }

    private func watchdogColor(_ order: TradingDashboardSnapshot.Order) -> NSColor {
        switch order.localState {
        case "needs_manual_review":
            return .systemRed
        case "needs_reconciliation", "awaiting_broker_echo", "awaiting_cancel_ack", "partially_filled":
            return .systemOrange
        default:
            if (order.fillDurationMs ?? -1) >= 0 {
                return .systemGreen
            }
            return .secondaryLabelColor
        }
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendMessage(_ message: String) {
        manager.appendMessage(message)
    }

    @objc
    private func refreshTimerFired() {
        guard window?.isVisible == true else { return }
        manager.refreshDashboard()
    }

    @objc
    private func inputFieldAction() {
        syncInputsToRuntime()
        manager.refreshDashboard()
    }

    @objc
    private func liveStreamFieldAction() {
        onLiveStreamURLChanged(currentLiveStreamURLText)
    }

    @objc
    private func ocrRatioFieldAction() {
        let ratio = sanitizedOCRBuyRatio()
        ocrRatioField.stringValue = String(format: "%.2f", ratio)
        onOCRBuyRatioChanged(ratio)
    }

    @objc
    private func toggleLiveStream() {
        if liveStatus.isRunning {
            onStopLiveStream()
            appendMessage("Stopped live OCR stream")
            return
        }

        let urlText = currentLiveStreamURLText
        guard !urlText.isEmpty else {
            appendMessage("Enter a live stream URL before starting OCR")
            return
        }

        onLiveStreamURLChanged(urlText)
        onStartLiveStream(urlText)
        appendMessage("Starting live OCR stream")
    }

    @objc
    private func subscribeAction() {
        syncInputsToRuntime()
        do {
            let response = try manager.requestSubscription(symbol: symbolField.stringValue, recalcQtyFromFirstAsk: false)
            appendMessage("Subscribed to \(response.normalizedSymbol ?? symbolField.stringValue)")
        } catch {
            appendMessage("Subscribe failed: \(error.localizedDescription)")
        }
    }

    @objc
    private func buyAction() {
        syncInputsToRuntime()
        do {
            _ = try manager.submitBuy(source: "GUI Button", note: "Buy Limit button pressed")
        } catch {
            appendMessage("Buy failed: \(error.localizedDescription)")
        }
    }

    @objc
    private func closeAction() {
        syncInputsToRuntime()
        do {
            _ = try manager.submitClose(source: "GUI Button", note: "Close Long button pressed")
        } catch {
            appendMessage("Close failed: \(error.localizedDescription)")
        }
    }

    @objc
    private func cancelAllAction() {
        let confirm = NSAlert()
        confirm.messageText = "Cancel All Orders?"
        confirm.informativeText = "This will send cancel requests for every working order."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Cancel All")
        confirm.addButton(withTitle: "Keep Orders")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            let response = try manager.cancelAll()
            let count = response.orderIds?.count ?? 0
            appendMessage(count > 0 ? "Cancel requested for \(count) order(s)" : "No pending orders to cancel")
        } catch {
            appendMessage("Cancel all failed: \(error.localizedDescription)")
        }
    }

    @objc
    private func cancelSelectedAction() {
        let orderIDs = selectedOrderIDs()
        guard !orderIDs.isEmpty else {
            appendMessage("No orders selected for cancellation")
            return
        }
        do {
            let response = try manager.cancelSelected(orderIDs: orderIDs)
            let sentFlags = response.sent ?? []
            for (index, orderID) in (response.orderIds ?? orderIDs).enumerated() {
                if index < sentFlags.count, sentFlags[index] {
                    appendMessage("Cancel request sent for order \(orderID)")
                } else {
                    appendMessage("Cancel failed (not connected) for order \(orderID)")
                }
            }
        } catch {
            appendMessage("Cancel selected failed: \(error.localizedDescription)")
        }
    }

    @objc
    private func reconcileSelectedAction() {
        let orderIDs = selectedOrderIDs()
        guard !orderIDs.isEmpty else {
            appendMessage("No orders selected for reconciliation")
            return
        }
        do {
            let response = try manager.reconcileSelected(orderIDs: orderIDs)
            let accepted = response.orderIds ?? []
            if accepted.isEmpty {
                appendMessage("Selected orders do not need reconciliation right now")
            } else {
                accepted.forEach { appendMessage("Manual reconcile requested for order \($0)") }
            }
        } catch {
            appendMessage("Reconcile failed: \(error.localizedDescription)")
        }
    }

    @objc
    private func acknowledgeSelectedAction() {
        let orderIDs = selectedOrderIDs()
        guard !orderIDs.isEmpty else {
            appendMessage("No orders selected for acknowledgement")
            return
        }
        do {
            let response = try manager.acknowledgeSelected(orderIDs: orderIDs)
            if (response.orderIds ?? []).isEmpty {
                appendMessage("Selected orders do not require manual review acknowledgement")
            }
        } catch {
            appendMessage("Acknowledge failed: \(error.localizedDescription)")
        }
    }

    @objc
    private func toggleControllerArmed() {
        let nextArmed = !dashboard.panel.status.controllerArmed
        manager.setControllerArmed(nextArmed)
        appendMessage(nextArmed ? "Controller trading armed" : "Controller trading disarmed")
    }

    @objc
    private func toggleKillSwitch() {
        let nextEnabled = !dashboard.panel.status.tradingKillSwitch
        manager.setTradingKillSwitch(nextEnabled)
        if nextEnabled {
            manager.setControllerArmed(false)
        }
        appendMessage(nextEnabled ? "Kill switch enabled: trading halted" : "Kill switch disabled: trading may resume")
    }

    @objc
    private func openSettings() {
        onOpenSetup()
        appendMessage("Opened OCR ROI setup")
    }

    @objc
    private func loadRecoveryFromLogs() {
        guard !recoveryMaintenanceInFlight else { return }
        recoveryMaintenanceInFlight = true
        appendMessage("Loading persisted trade logs on demand...")
        refreshInterface()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.manager.loadRecoveryFromLogs() }
            DispatchQueue.main.async {
                self.recoveryMaintenanceInFlight = false
                switch result {
                case let .success(response):
                    if let banner = response.bannerText, !banner.isEmpty {
                        self.appendMessage("Loaded persisted runtime recovery: \(banner)")
                    } else {
                        self.appendMessage("Loaded persisted logs; no prior-session recovery work was found")
                    }
                case let .failure(error):
                    self.appendMessage("Failed to load persisted logs: \(error.localizedDescription)")
                }
                self.refreshInterface()
            }
        }
    }

    @objc
    private func deletePersistedLogs() {
        guard !recoveryMaintenanceInFlight else { return }

        let confirm = NSAlert()
        confirm.messageText = "Delete Persisted Trade Logs?"
        confirm.informativeText = "This removes the saved trade trace and runtime journal JSONL files. The app can recreate fresh logs after deletion."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Delete Logs")
        confirm.addButton(withTitle: "Keep Logs")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        recoveryMaintenanceInFlight = true
        refreshInterface()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.manager.deletePersistentLogs() }
            DispatchQueue.main.async {
                self.recoveryMaintenanceInFlight = false
                switch result {
                case let .success(response):
                    if let error = response.error, !error.isEmpty {
                        self.appendMessage("Failed to delete persisted logs: \(error)")
                    } else if response.deletedTradeTraceLog != true && response.deletedRuntimeJournalLog != true {
                        self.appendMessage("No persisted trade log files were present")
                    } else {
                        var parts: [String] = []
                        if response.deletedTradeTraceLog == true { parts.append("trade_trace_events.jsonl") }
                        if response.deletedRuntimeJournalLog == true { parts.append("trade_runtime_journal.jsonl") }
                        self.appendMessage("Deleted persisted logs: \(parts.joined(separator: ", ")). Fresh logs will be created as new activity occurs.")
                    }
                case let .failure(error):
                    self.appendMessage("Failed to delete persisted logs: \(error.localizedDescription)")
                }
                self.refreshInterface()
            }
        }
    }

    @objc
    private func traceSelectionChanged() {
        guard dashboard.traceItems.indices.contains(tracePopup.indexOfSelectedItem) else { return }
        let traceID = dashboard.traceItems[tracePopup.indexOfSelectedItem].traceId
        syncInputsToRuntime(selectedTraceID: traceID)
        manager.refreshDashboard()
    }

    @objc
    private func exportSelectedTrace() {
        let traceID = dashboard.inputs.selectedTraceId
        guard traceID != 0 else {
            let alert = NSAlert()
            alert.messageText = "No Trace Selected"
            alert.informativeText = "Select a trade trace before exporting."
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window!, completionHandler: nil)
            return
        }

        do {
            let bundle = try manager.traceExportBundle(traceID: traceID)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose a folder for the selected trace export."
            guard panel.runModal() == .OK, let directoryURL = panel.url else { return }

            try writeText(bundle.reportText, to: directoryURL.appendingPathComponent("\(bundle.baseName)-report.txt"))
            try writeText(bundle.summaryCsv, to: directoryURL.appendingPathComponent("\(bundle.baseName)-summary.csv"))
            try writeText(bundle.fillsCsv, to: directoryURL.appendingPathComponent("\(bundle.baseName)-fills.csv"))
            try writeText(bundle.timelineCsv, to: directoryURL.appendingPathComponent("\(bundle.baseName)-timeline.csv"))
            appendMessage("Exported trace bundle to \(directoryURL.path)")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.beginSheetModal(for: window!, completionHandler: nil)
        }
    }

    @objc
    private func exportAllTracesSummary() {
        do {
            let csv = try manager.allTradesSummaryCSV()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "all-trades-summary.csv"
            panel.prompt = "Save CSV"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try writeText(csv, to: url)
            appendMessage("Exported trade summary CSV to \(url.path)")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.beginSheetModal(for: window!, completionHandler: nil)
        }
    }
}
