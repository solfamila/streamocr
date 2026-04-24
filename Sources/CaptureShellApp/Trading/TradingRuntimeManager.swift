import Foundation
import TradingRuntimeBridge

struct TradingDashboardSnapshot: Decodable, Equatable {
    struct Inputs: Decodable, Equatable {
        var symbolInput: String
        var subscribedSymbol: String
        var subscribed: Bool
        var quantityInput: Int
        var priceBuffer: Double
        var maxPositionDollars: Double
        var selectedTraceId: UInt64
    }

    struct Panel: Decodable, Equatable {
        struct Status: Decodable, Equatable {
            var connected: Bool
            var sessionReady: Bool
            var sessionStateText: String
            var accountText: String
            var controllerConnected: Bool
            var controllerEnabled: Bool
            var controllerArmed: Bool
            var tradingKillSwitch: Bool
            var controllerDeviceName: String
            var controllerLockedDeviceName: String
            var startupRecoveryBanner: String
        }

        struct Symbol: Decodable, Equatable {
            var canTrade: Bool
            var hasPosition: Bool
            var hasFreshQuote: Bool
            var bidPrice: Double
            var askPrice: Double
            var lastPrice: Double
            var currentPositionQty: Double
            var currentPositionAvgCost: Double
            var availableLongToClose: Double
            var quoteAgeMs: Double
            var openBuyExposure: Double
        }

        struct Risk: Decodable, Equatable {
            var staleQuoteThresholdMs: Int
            var brokerEchoTimeoutMs: Int
            var cancelAckTimeoutMs: Int
            var partialFillQuietTimeoutMs: Int
            var maxOrderNotional: Double
            var maxOpenNotional: Double
            var controllerArmMode: String
            var controllerArmed: Bool
            var tradingKillSwitch: Bool
        }

        var status: Status
        var symbol: Symbol
        var risk: Risk
        var buyPrice: Double
        var sellPrice: Double
        var orderNotional: Double
        var projectedOpenNotional: Double
        var buySweepAvailable: Bool
        var sellSweepAvailable: Bool
        var canTrade: Bool
        var canBuy: Bool
        var canClosePosition: Bool
        var hasCancelableOrders: Bool
        var askLevels: Int
        var bidLevels: Int
        var maxToggleQuantity: Int
    }

    struct Order: Decodable, Equatable {
        var orderId: Int
        var account: String?
        var symbol: String
        var side: String
        var quantity: Double
        var limitPrice: Double
        var status: String
        var filledQty: Double
        var remainingQty: Double
        var avgFillPrice: Double
        var cancelPending: Bool
        var localState: String
        var localStateText: String?
        var watchdogText: String?
        var timingText: String?
        var manualReviewAcknowledged: Bool?
        var fillDurationMs: Double?
    }

    struct TraceItem: Decodable, Equatable {
        var traceId: UInt64
        var orderId: Int
        var terminal: Bool
        var failed: Bool
        var summary: String
    }

    var inputs: Inputs
    var panel: Panel
    var messagesText: String
    var orders: [Order]
    var traceItems: [TraceItem]
    var traceItemsFromReplayLog: Bool?
    var traceDetailsText: String
    var canExportSelectedTrace: Bool?
    var canExportAllTraces: Bool?
    var activeSymbol: String
    var subscriptionActive: Bool
    var latestTraceId: UInt64
}

struct TradingConnectionConfigSnapshot: Codable, Equatable {
    var host: String
    var port: Int
    var clientId: Int
    var controllerEnabled: Bool
    var orderRoutingMode: String
    var pegBestOffset: Double
    var pegBestOffsetUpToMid: Bool
    var pegBestMinCompeteSize: Int
    var pegBestMidOffsetAtWhole: Double
    var pegBestMidOffsetAtHalf: Double
    var pegBestRerouteToSmartMinutes: Int
}

struct TradingRiskControlsSnapshot: Codable, Equatable {
    var staleQuoteThresholdMs: Int
    var brokerEchoTimeoutMs: Int
    var cancelAckTimeoutMs: Int
    var partialFillQuietTimeoutMs: Int
    var maxOrderNotional: Double
    var maxOpenNotional: Double
    var controllerArmMode: String
    var controllerArmed: Bool
    var tradingKillSwitch: Bool
}

struct TradingActionResponse: Decodable, Equatable {
    var ok: Bool
    var error: String?
    var normalizedSymbol: String?
    var traceId: UInt64?
    var runtimeAvailable: Bool?
    var orderIds: [Int]?
    var sent: [Bool]?
    var bannerText: String?
    var unfinishedTraceCount: Int?
    var pendingOutboxCount: Int?
    var deletedTradeTraceLog: Bool?
    var deletedRuntimeJournalLog: Bool?
    var baseName: String?
    var reportText: String?
    var summaryCsv: String?
    var fillsCsv: String?
    var timelineCsv: String?
}

struct TradingRuntimeStartResult: Equatable {
    let connected: Bool
    let activeConfig: TradingConnectionConfigSnapshot
    let autoDetectedConfig: TradingConnectionConfigSnapshot?
    let attemptedFallbackPorts: [Int]
}

struct TradingTraceExportBundle: Equatable {
    var baseName: String
    var reportText: String
    var summaryCsv: String
    var fillsCsv: String
    var timelineCsv: String
}

enum TradingRuntimeManagerError: LocalizedError {
    case unavailable
    case invalidUTF8
    case decodeFailed(String)
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Trading runtime bridge is unavailable."
        case .invalidUTF8:
            return "Trading runtime returned invalid text."
        case let .decodeFailed(message):
            return "Trading runtime JSON decode failed: \(message)"
        case let .actionFailed(message):
            return message
        }
    }
}

final class TradingRuntimeManager: @unchecked Sendable {
    var onDashboardChanged: ((TradingDashboardSnapshot) -> Void)?
    private(set) var isStarted = false

    private static let autoDetectFallbackPorts = [4001, 4002, 7497]
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var handle: OpaquePointer?
    private(set) var dashboard = TradingDashboardSnapshot(
        inputs: .init(
            symbolInput: "",
            subscribedSymbol: "",
            subscribed: false,
            quantityInput: 1,
            priceBuffer: 0.01,
            maxPositionDollars: 40_000,
            selectedTraceId: 0
        ),
        panel: .init(
            status: .init(
                connected: false,
                sessionReady: false,
                sessionStateText: "Disconnected",
                accountText: "",
                controllerConnected: false,
                controllerEnabled: true,
                controllerArmed: false,
                tradingKillSwitch: false,
                controllerDeviceName: "",
                controllerLockedDeviceName: "",
                startupRecoveryBanner: ""
            ),
            symbol: .init(
                canTrade: false,
                hasPosition: false,
                hasFreshQuote: false,
                bidPrice: 0,
                askPrice: 0,
                lastPrice: 0,
                currentPositionQty: 0,
                currentPositionAvgCost: 0,
                availableLongToClose: 0,
                quoteAgeMs: -1,
                openBuyExposure: 0
            ),
            risk: .init(
                staleQuoteThresholdMs: 1500,
                brokerEchoTimeoutMs: 2000,
                cancelAckTimeoutMs: 5000,
                partialFillQuietTimeoutMs: 15000,
                maxOrderNotional: 15_000,
                maxOpenNotional: 50_000,
                controllerArmMode: "one_shot",
                controllerArmed: false,
                tradingKillSwitch: false
            ),
            buyPrice: 0,
            sellPrice: 0,
            orderNotional: 0,
            projectedOpenNotional: 0,
            buySweepAvailable: false,
            sellSweepAvailable: false,
            canTrade: false,
            canBuy: false,
            canClosePosition: false,
            hasCancelableOrders: false,
            askLevels: 0,
            bidLevels: 0,
            maxToggleQuantity: 1
        ),
        messagesText: "",
        orders: [],
        traceItems: [],
        traceItemsFromReplayLog: nil,
        traceDetailsText: "",
        canExportSelectedTrace: nil,
        canExportAllTraces: nil,
        activeSymbol: "",
        subscriptionActive: false,
        latestTraceId: 0
    )

    init() {
        handle = TradingRuntimeBridgeCreate()
        if let handle {
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            TradingRuntimeBridgeSetInvalidationCallback(handle, tradingRuntimeInvalidationThunk, context)
        }
    }

    deinit {
        guard let handle else { return }
        TradingRuntimeBridgeSetInvalidationCallback(handle, nil, nil)
        TradingRuntimeBridgeShutdown(handle)
        TradingRuntimeBridgeDestroy(handle)
    }

    func start() -> Bool {
        guard let handle else { return false }
        let started = TradingRuntimeBridgeStart(handle)
        isStarted = true
        refreshDashboard()
        return started
    }

    func startWithAutoConnectFallback() -> TradingRuntimeStartResult {
        let originalConfig = (try? currentConnectionConfig()) ?? TradingConnectionConfigSnapshot(
            host: "127.0.0.1",
            port: 7496,
            clientId: 1,
            controllerEnabled: true,
            orderRoutingMode: "smart",
            pegBestOffset: 0,
            pegBestOffsetUpToMid: false,
            pegBestMinCompeteSize: 0,
            pegBestMidOffsetAtWhole: 0,
            pegBestMidOffsetAtHalf: 0,
            pegBestRerouteToSmartMinutes: 0
        )

        let initialConnected = start()
        guard !initialConnected, Self.shouldAutoDetectLocalIBConnection(for: originalConfig) else {
            return TradingRuntimeStartResult(
                connected: initialConnected,
                activeConfig: (try? currentConnectionConfig()) ?? originalConfig,
                autoDetectedConfig: nil,
                attemptedFallbackPorts: []
            )
        }

        shutdown()

        var attemptedFallbackPorts: [Int] = []
        for port in Self.autoDetectFallbackPorts where port != originalConfig.port {
            attemptedFallbackPorts.append(port)
            var fallbackConfig = originalConfig
            fallbackConfig.port = port

            do {
                try updateConnectionConfig(fallbackConfig)
            } catch {
                continue
            }

            if start() {
                let activeConfig = (try? currentConnectionConfig()) ?? fallbackConfig
                return TradingRuntimeStartResult(
                    connected: true,
                    activeConfig: activeConfig,
                    autoDetectedConfig: activeConfig,
                    attemptedFallbackPorts: attemptedFallbackPorts
                )
            }

            shutdown()
        }

        try? updateConnectionConfig(originalConfig)
        let restoredConnected = start()
        return TradingRuntimeStartResult(
            connected: restoredConnected,
            activeConfig: (try? currentConnectionConfig()) ?? originalConfig,
            autoDetectedConfig: nil,
            attemptedFallbackPorts: attemptedFallbackPorts
        )
    }

    func shutdown() {
        guard let handle else { return }
        TradingRuntimeBridgeShutdown(handle)
        isStarted = false
        refreshDashboard()
    }

    func setUIInputs(
        symbolInput: String,
        subscribedSymbol: String,
        subscribed: Bool,
        quantityInput: Int,
        priceBuffer: Double,
        maxPositionDollars: Double,
        selectedTraceId: UInt64
    ) {
        guard let handle else { return }
        symbolInput.withCString { symbolInputCString in
            subscribedSymbol.withCString { subscribedSymbolCString in
                TradingRuntimeBridgeSetUIInputs(
                    handle,
                    symbolInputCString,
                    subscribedSymbolCString,
                    subscribed,
                    CInt(quantityInput),
                    priceBuffer,
                    maxPositionDollars,
                    selectedTraceId
                )
            }
        }
    }

    func refreshDashboard() {
        guard let handle else { return }
        do {
            dashboard = try decodeJSONString(
                TradingRuntimeBridgeCopyDashboardJSON(handle),
                as: TradingDashboardSnapshot.self
            )
            onDashboardChanged?(dashboard)
        } catch {
            print("[trading] dashboard_refresh_failed error=\(error.localizedDescription)")
        }
    }

    func currentConnectionConfig() throws -> TradingConnectionConfigSnapshot {
        guard let handle else { throw TradingRuntimeManagerError.unavailable }
        return try decodeJSONString(
            TradingRuntimeBridgeCopyConnectionJSON(handle),
            as: TradingConnectionConfigSnapshot.self
        )
    }

    func currentRiskControls() throws -> TradingRiskControlsSnapshot {
        guard let handle else { throw TradingRuntimeManagerError.unavailable }
        return try decodeJSONString(
            TradingRuntimeBridgeCopyRiskJSON(handle),
            as: TradingRiskControlsSnapshot.self
        )
    }

    func updateConnectionConfig(_ config: TradingConnectionConfigSnapshot) throws {
        let payload = try encoder.encode(config)
        guard let jsonText = String(data: payload, encoding: .utf8) else {
            throw TradingRuntimeManagerError.invalidUTF8
        }
        _ = try runAction {
            jsonText.withCString { jsonCString in
                TradingRuntimeBridgeUpdateConnectionJSON(handle, jsonCString)
            }
        }
        refreshDashboard()
    }

    func updateRiskControls(_ risk: TradingRiskControlsSnapshot) throws {
        let payload = try encoder.encode(risk)
        guard let jsonText = String(data: payload, encoding: .utf8) else {
            throw TradingRuntimeManagerError.invalidUTF8
        }
        _ = try runAction {
            jsonText.withCString { jsonCString in
                TradingRuntimeBridgeUpdateRiskJSON(handle, jsonCString)
            }
        }
        refreshDashboard()
    }

    @discardableResult
    func requestSubscription(symbol: String, recalcQtyFromFirstAsk: Bool) throws -> TradingActionResponse {
        let response = try runAction {
            symbol.withCString { symbolCString in
                TradingRuntimeBridgeRequestSubscriptionJSON(handle, symbolCString, recalcQtyFromFirstAsk)
            }
        }
        refreshDashboard()
        return response
    }

    @discardableResult
    func submitBuy(source: String, note: String) throws -> TradingActionResponse {
        let response = try runAction {
            source.withCString { sourceCString in
                note.withCString { noteCString in
                    TradingRuntimeBridgeSubmitBuyJSON(handle, sourceCString, noteCString)
                }
            }
        }
        refreshDashboard()
        return response
    }

    @discardableResult
    func submitClose(source: String, note: String) throws -> TradingActionResponse {
        let response = try runAction {
            source.withCString { sourceCString in
                note.withCString { noteCString in
                    TradingRuntimeBridgeSubmitCloseJSON(handle, sourceCString, noteCString)
                }
            }
        }
        refreshDashboard()
        return response
    }

    @discardableResult
    func cancelAll() throws -> TradingActionResponse {
        let response = try runAction {
            TradingRuntimeBridgeCancelAllJSON(handle)
        }
        refreshDashboard()
        return response
    }

    func setControllerArmed(_ armed: Bool) {
        guard let handle else { return }
        TradingRuntimeBridgeSetControllerArmed(handle, armed)
        refreshDashboard()
    }

    func setTradingKillSwitch(_ enabled: Bool) {
        guard let handle else { return }
        TradingRuntimeBridgeSetTradingKillSwitch(handle, enabled)
        refreshDashboard()
    }

    private static func shouldAutoDetectLocalIBConnection(for config: TradingConnectionConfigSnapshot) -> Bool {
        let normalizedHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isLocalHost = normalizedHost.isEmpty || normalizedHost == "127.0.0.1" || normalizedHost == "localhost"
        return isLocalHost && config.port == 7496
    }

    func appendMessage(_ message: String) {
        guard let handle else { return }
        message.withCString { messageCString in
            TradingRuntimeBridgeAppendMessage(handle, messageCString)
        }
        refreshDashboard()
    }

    @discardableResult
    func cancelSelected(orderIDs: [Int]) throws -> TradingActionResponse {
        let cOrderIDs = orderIDs.map(Int64.init)
        let response = try runAction {
            cOrderIDs.withUnsafeBufferPointer { buffer in
                TradingRuntimeBridgeCancelSelectedJSON(
                    handle,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        }
        refreshDashboard()
        return response
    }

    @discardableResult
    func reconcileSelected(orderIDs: [Int]) throws -> TradingActionResponse {
        let cOrderIDs = orderIDs.map(Int64.init)
        let response = try runAction {
            cOrderIDs.withUnsafeBufferPointer { buffer in
                TradingRuntimeBridgeReconcileSelectedJSON(
                    handle,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        }
        refreshDashboard()
        return response
    }

    @discardableResult
    func acknowledgeSelected(orderIDs: [Int]) throws -> TradingActionResponse {
        let cOrderIDs = orderIDs.map(Int64.init)
        let response = try runAction {
            cOrderIDs.withUnsafeBufferPointer { buffer in
                TradingRuntimeBridgeAcknowledgeSelectedJSON(
                    handle,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        }
        refreshDashboard()
        return response
    }

    @discardableResult
    func loadRecoveryFromLogs() throws -> TradingActionResponse {
        let response = try runAction {
            TradingRuntimeBridgeLoadRecoveryJSON(handle)
        }
        refreshDashboard()
        return response
    }

    @discardableResult
    func deletePersistentLogs() throws -> TradingActionResponse {
        let response = try runAction {
            TradingRuntimeBridgeDeletePersistentLogsJSON(handle)
        }
        refreshDashboard()
        return response
    }

    func traceExportBundle(traceID: UInt64) throws -> TradingTraceExportBundle {
        guard let handle else { throw TradingRuntimeManagerError.unavailable }
        let response = try runAction {
            TradingRuntimeBridgeCopyTraceExportBundleJSON(handle, traceID)
        }
        return TradingTraceExportBundle(
            baseName: response.baseName ?? "trace",
            reportText: response.reportText ?? "",
            summaryCsv: response.summaryCsv ?? "",
            fillsCsv: response.fillsCsv ?? "",
            timelineCsv: response.timelineCsv ?? ""
        )
    }

    func allTradesSummaryCSV() throws -> String {
        guard let handle else { throw TradingRuntimeManagerError.unavailable }
        return try decodePlainString(
            TradingRuntimeBridgeCopyAllTradesSummaryCSV(handle)
        )
    }

    private func runAction(
        _ invoke: () -> UnsafeMutablePointer<CChar>?
    ) throws -> TradingActionResponse {
        guard handle != nil else {
            throw TradingRuntimeManagerError.unavailable
        }
        let response = try decodeJSONString(invoke(), as: TradingActionResponse.self)
        if !response.ok {
            throw TradingRuntimeManagerError.actionFailed(response.error ?? "Trading action failed.")
        }
        return response
    }

    private func decodeJSONString<T: Decodable>(
        _ cString: UnsafeMutablePointer<CChar>?,
        as type: T.Type
    ) throws -> T {
        guard let cString else {
            throw TradingRuntimeManagerError.unavailable
        }
        defer {
            TradingRuntimeBridgeFreeString(cString)
        }
        let string = String(cString: cString)
        guard let data = string.data(using: .utf8) else {
            throw TradingRuntimeManagerError.invalidUTF8
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TradingRuntimeManagerError.decodeFailed(error.localizedDescription)
        }
    }

    private func decodePlainString(
        _ cString: UnsafeMutablePointer<CChar>?
    ) throws -> String {
        guard let cString else {
            throw TradingRuntimeManagerError.unavailable
        }
        defer {
            TradingRuntimeBridgeFreeString(cString)
        }
        return String(cString: cString)
    }

    fileprivate func handleInvalidation() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDashboard()
        }
    }
}

private func tradingRuntimeInvalidationThunk(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let manager = Unmanaged<TradingRuntimeManager>.fromOpaque(context).takeUnretainedValue()
    manager.handleInvalidation()
}
