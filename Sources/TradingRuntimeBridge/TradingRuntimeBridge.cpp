#include "TradingRuntimeBridge.h"

#include "Imported/long/trading_actions.h"
#include "Imported/long/trace_exporter.h"
#include "Imported/long/trading_runtime.h"
#include "Imported/long/trading_ui_format.h"
#include "Imported/long/trading_view_model.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>

namespace {

using json = nlohmann::json;

std::string stringOrEmpty(const char* text) {
    return text == nullptr ? std::string() : std::string(text);
}

char* copyCString(const std::string& text) {
    const std::size_t bytes = text.size() + 1;
    auto* buffer = static_cast<char*>(std::malloc(bytes));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, text.c_str(), bytes);
    return buffer;
}

json makeActionResult(bool ok, std::string error = {}) {
    return json{
        {"ok", ok},
        {"error", error.empty() ? json(nullptr) : json(std::move(error))}
    };
}

std::string controllerArmModeName(ControllerArmMode mode) {
    switch (mode) {
    case ControllerArmMode::Manual:
        return "manual";
    case ControllerArmMode::OneShot:
    default:
        return "one_shot";
    }
}

std::string orderRoutingModeName(OrderRoutingMode mode) {
    switch (mode) {
    case OrderRoutingMode::IbkrAtsPegBest:
        return "ibkr_ats_peg_best";
    case OrderRoutingMode::SmartLimit:
    default:
        return "smart_limit";
    }
}

std::string localOrderStateName(LocalOrderState state) {
    switch (state) {
    case LocalOrderState::IntentAccepted: return "intent_accepted";
    case LocalOrderState::SentToBroker: return "sent_to_broker";
    case LocalOrderState::AwaitingBrokerEcho: return "awaiting_broker_echo";
    case LocalOrderState::Working: return "working";
    case LocalOrderState::PartiallyFilled: return "partially_filled";
    case LocalOrderState::CancelRequested: return "cancel_requested";
    case LocalOrderState::AwaitingCancelAck: return "awaiting_cancel_ack";
    case LocalOrderState::Filled: return "filled";
    case LocalOrderState::Cancelled: return "cancelled";
    case LocalOrderState::Rejected: return "rejected";
    case LocalOrderState::Inactive: return "inactive";
    case LocalOrderState::NeedsReconciliation: return "needs_reconciliation";
    case LocalOrderState::NeedsManualReview: return "needs_manual_review";
    }
}

std::vector<OrderId> decodeOrderIds(const int64_t* orderIds, std::size_t count) {
    std::vector<OrderId> decoded;
    decoded.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        decoded.push_back(static_cast<OrderId>(orderIds[index]));
    }
    return decoded;
}

json orderInfoToJson(OrderId orderId, const OrderInfo& order) {
    return json{
        {"orderId", static_cast<long long>(orderId)},
        {"account", order.account},
        {"symbol", order.symbol},
        {"side", order.side},
        {"quantity", order.quantity},
        {"limitPrice", order.limitPrice},
        {"status", order.status},
        {"filledQty", order.filledQty},
        {"remainingQty", order.remainingQty},
        {"avgFillPrice", order.avgFillPrice},
        {"cancelPending", order.cancelPending},
        {"localState", localOrderStateName(order.localState)},
        {"localStateText", formatOrderLocalStateText(order)},
        {"watchdogText", formatOrderWatchdogText(order)},
        {"timingText", formatOrderTimingText(order)},
        {"manualReviewAcknowledged", order.manualReviewAcknowledged},
        {"fillDurationMs", order.fillDurationMs}
    };
}

json panelStateToJson(const TradingPanelState& panel) {
    return json{
        {"status", {
            {"connected", panel.status.connected},
            {"sessionReady", panel.status.sessionReady},
            {"sessionStateText", panel.status.sessionStateText},
            {"accountText", panel.status.accountText},
            {"controllerConnected", panel.status.controllerConnected},
            {"controllerEnabled", panel.status.controllerEnabled},
            {"controllerArmed", panel.status.controllerArmed},
            {"tradingKillSwitch", panel.status.tradingKillSwitch},
            {"controllerDeviceName", panel.status.controllerDeviceName},
            {"controllerLockedDeviceName", panel.status.controllerLockedDeviceName},
            {"startupRecoveryBanner", panel.status.startupRecoveryBanner}
        }},
        {"symbol", {
            {"canTrade", panel.symbol.canTrade},
            {"hasPosition", panel.symbol.hasPosition},
            {"hasFreshQuote", panel.symbol.hasFreshQuote},
            {"bidPrice", panel.symbol.bidPrice},
            {"askPrice", panel.symbol.askPrice},
            {"lastPrice", panel.symbol.lastPrice},
            {"currentPositionQty", panel.symbol.currentPositionQty},
            {"currentPositionAvgCost", panel.symbol.currentPositionAvgCost},
            {"availableLongToClose", panel.symbol.availableLongToClose},
            {"quoteAgeMs", panel.symbol.quoteAgeMs},
            {"openBuyExposure", panel.symbol.openBuyExposure}
        }},
        {"risk", {
            {"staleQuoteThresholdMs", panel.risk.staleQuoteThresholdMs},
            {"brokerEchoTimeoutMs", panel.risk.brokerEchoTimeoutMs},
            {"cancelAckTimeoutMs", panel.risk.cancelAckTimeoutMs},
            {"partialFillQuietTimeoutMs", panel.risk.partialFillQuietTimeoutMs},
            {"maxOrderNotional", panel.risk.maxOrderNotional},
            {"maxOpenNotional", panel.risk.maxOpenNotional},
            {"controllerArmMode", controllerArmModeName(panel.risk.controllerArmMode)},
            {"controllerArmed", panel.risk.controllerArmed},
            {"tradingKillSwitch", panel.risk.tradingKillSwitch}
        }},
        {"buyPrice", panel.buyPrice},
        {"sellPrice", panel.sellPrice},
        {"orderNotional", panel.orderNotional},
        {"projectedOpenNotional", panel.projectedOpenNotional},
        {"buySweepAvailable", panel.buySweepAvailable},
        {"sellSweepAvailable", panel.sellSweepAvailable},
        {"canTrade", panel.canTrade},
        {"canBuy", panel.canBuy},
        {"canClosePosition", panel.canClosePosition},
        {"hasCancelableOrders", panel.hasCancelableOrders},
        {"askLevels", panel.askLevels},
        {"bidLevels", panel.bidLevels},
        {"maxToggleQuantity", panel.maxToggleQuantity}
    };
}

json connectionConfigToJson(const RuntimeConnectionConfig& config) {
    return json{
        {"host", config.host},
        {"port", config.port},
        {"clientId", config.clientId},
        {"controllerEnabled", config.controllerEnabled},
        {"orderRoutingMode", orderRoutingModeName(config.orderRoutingMode)},
        {"pegBestOffset", config.pegBestOffset},
        {"pegBestOffsetUpToMid", config.pegBestOffsetUpToMid},
        {"pegBestMinCompeteSize", config.pegBestMinCompeteSize},
        {"pegBestMidOffsetAtWhole", config.pegBestMidOffsetAtWhole},
        {"pegBestMidOffsetAtHalf", config.pegBestMidOffsetAtHalf},
        {"pegBestRerouteToSmartMinutes", config.pegBestRerouteToSmartMinutes}
    };
}

json riskControlsToJson(const RiskControlsSnapshot& risk) {
    return json{
        {"staleQuoteThresholdMs", risk.staleQuoteThresholdMs},
        {"brokerEchoTimeoutMs", risk.brokerEchoTimeoutMs},
        {"cancelAckTimeoutMs", risk.cancelAckTimeoutMs},
        {"partialFillQuietTimeoutMs", risk.partialFillQuietTimeoutMs},
        {"maxOrderNotional", risk.maxOrderNotional},
        {"maxOpenNotional", risk.maxOpenNotional},
        {"controllerArmMode", controllerArmModeName(risk.controllerArmMode)},
        {"controllerArmed", risk.controllerArmed},
        {"tradingKillSwitch", risk.tradingKillSwitch}
    };
}

json cancelResultToJson(const TradingCancelResult& result) {
    json sent = json::array();
    for (bool value : result.sent) {
        sent.push_back(value);
    }
    json orderIds = json::array();
    for (OrderId orderId : result.orderIds) {
        orderIds.push_back(static_cast<long long>(orderId));
    }
    return json{
        {"ok", result.runtimeAvailable && !result.orderIds.empty()},
        {"runtimeAvailable", result.runtimeAvailable},
        {"orderIds", std::move(orderIds)},
        {"sent", std::move(sent)}
    };
}

struct BridgeUIState {
    std::string symbolInput;
    std::string subscribedSymbol;
    bool subscribed = false;
    int quantityInput = 1;
    double priceBuffer = 0.01;
    double maxPositionDollars = 40000.0;
    std::uint64_t selectedTraceId = 0;
};

class TradingRuntimeBridgeImpl {
public:
    TradingRuntimeBridgeImpl() {
        runtime_.setUiInvalidationCallback([this]() {
            TradingRuntimeBridgeInvalidationCallback callback = nullptr;
            void* context = nullptr;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                callback = invalidationCallback_;
                context = invalidationContext_;
            }
            if (callback != nullptr) {
                callback(context);
            }
        });

        runtime_.setControllerActionCallback([this](TradingRuntimeControllerAction action) {
            BridgeUIState ui = currentUIState();
            const RuntimePresentationSnapshot presentation =
                runtime_.capturePresentationSnapshot(ui.subscribed ? ui.subscribedSymbol : std::string(), 50);
            const TradingPanelState panel = buildTradingPanelState(
                presentation,
                ui.subscribed,
                ui.quantityInput,
                ui.priceBuffer,
                ui.maxPositionDollars
            );
            const TradingControllerActionResult result = handleControllerActionIntent(
                &runtime_,
                action,
                panel,
                ui.subscribedSymbol,
                ui.quantityInput,
                ui.priceBuffer,
                ui.maxPositionDollars
            );

            if (result.quantityChanged) {
                updateQuantity(result.quantityInput);
            }
            if (result.traceId != 0) {
                updateSelectedTrace(result.traceId);
            }
            for (const auto& message : result.messages) {
                runtime_.appendMessage(message);
            }
            requestUiInvalidation();
        });
    }

    TradingRuntime& runtime() { return runtime_; }

    void setInvalidationCallback(
        TradingRuntimeBridgeInvalidationCallback callback,
        void* context
    ) {
        std::lock_guard<std::mutex> lock(mutex_);
        invalidationCallback_ = callback;
        invalidationContext_ = context;
    }

    void setUIInputs(
        const std::string& symbolInput,
        const std::string& subscribedSymbol,
        bool subscribed,
        int quantityInput,
        double priceBuffer,
        double maxPositionDollars,
        std::uint64_t selectedTraceId
    ) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            uiState_.symbolInput = symbolInput;
            uiState_.subscribedSymbol = subscribedSymbol;
            uiState_.subscribed = subscribed;
            uiState_.quantityInput = std::max(1, quantityInput);
            uiState_.priceBuffer = std::max(0.0, priceBuffer);
            uiState_.maxPositionDollars = std::max(1000.0, maxPositionDollars);
            uiState_.selectedTraceId = selectedTraceId;
        }
        const BridgeUIState ui = currentUIState();
        runtime_.syncGuiInputs(ui.quantityInput, ui.priceBuffer, ui.maxPositionDollars);
    }

    json dashboardJson() {
        const BridgeUIState currentUI = currentUIState();
        TradingViewModelInput input;
        input.symbolInput = currentUI.symbolInput;
        input.subscribedSymbol = currentUI.subscribedSymbol;
        input.subscribed = currentUI.subscribed;
        input.quantityInput = currentUI.quantityInput;
        input.priceBuffer = currentUI.priceBuffer;
        input.maxPositionDollars = currentUI.maxPositionDollars;
        input.selectedTraceId = currentUI.selectedTraceId;
        input.pendingUiSync = runtime_.consumePendingUiSyncUpdate();
        input.presentation = runtime_.capturePresentationSnapshot(
            currentUI.subscribed ? currentUI.subscribedSymbol : std::string(),
            50
        );

        const TradingViewModel model = buildTradingViewModel(input);
        updateUIStateFromModel(model, currentUI.priceBuffer, currentUI.maxPositionDollars);
        runtime_.setControllerVibration(model.shouldVibrate);

        json orders = json::array();
        for (const auto& entry : model.orders) {
            orders.push_back(orderInfoToJson(entry.first, entry.second));
        }

        json traceItems = json::array();
        for (const auto& item : model.traceItems) {
            traceItems.push_back({
                {"traceId", static_cast<unsigned long long>(item.traceId)},
                {"orderId", static_cast<long long>(item.orderId)},
                {"terminal", item.terminal},
                {"failed", item.failed},
                {"summary", item.summary}
            });
        }

        return json{
            {"inputs", {
                {"symbolInput", model.symbolInput},
                {"subscribedSymbol", model.subscribedSymbol},
                {"subscribed", model.subscribed},
                {"quantityInput", model.quantityInput},
                {"priceBuffer", currentUI.priceBuffer},
                {"maxPositionDollars", currentUI.maxPositionDollars},
                {"selectedTraceId", static_cast<unsigned long long>(model.selectedTraceId)}
            }},
            {"panel", panelStateToJson(model.panel)},
            {"messagesText", model.messagesText},
            {"messagesVersionSeen", static_cast<unsigned long long>(model.messagesVersionSeen)},
            {"orders", std::move(orders)},
            {"traceItems", std::move(traceItems)},
            {"traceItemsFromReplayLog", model.traceItemsFromReplayLog},
            {"traceDetailsText", model.traceDetailsText},
            {"canExportSelectedTrace", model.canExportSelectedTrace},
            {"canExportAllTraces", model.canExportAllTraces},
            {"shouldVibrate", model.shouldVibrate},
            {"activeSymbol", input.presentation.activeSymbol},
            {"subscriptionActive", input.presentation.subscriptionActive},
            {"latestTraceId", static_cast<unsigned long long>(input.presentation.latestTraceId)}
        };
    }

    json requestSubscription(const std::string& rawSymbol, bool recalcQtyFromFirstAsk) {
        std::string normalizedSymbol;
        std::string error;
        const bool ok = requestSubscriptionAction(
            &runtime_,
            rawSymbol,
            recalcQtyFromFirstAsk,
            &normalizedSymbol,
            &error
        );

        if (ok) {
            std::lock_guard<std::mutex> lock(mutex_);
            uiState_.symbolInput = normalizedSymbol;
            uiState_.subscribedSymbol = normalizedSymbol;
            uiState_.subscribed = true;
        }

        json result = makeActionResult(ok, error);
        result["normalizedSymbol"] = normalizedSymbol.empty() ? json(nullptr) : json(normalizedSymbol);
        return result;
    }

    json submitBuy(const std::string& source, const std::string& note) {
        const BridgeUIState ui = currentUIState();
        const RuntimePresentationSnapshot presentation =
            runtime_.capturePresentationSnapshot(ui.subscribed ? ui.subscribedSymbol : std::string(), 50);
        const TradingPanelState panel = buildTradingPanelState(
            presentation,
            ui.subscribed,
            ui.quantityInput,
            ui.priceBuffer,
            ui.maxPositionDollars
        );
        const TradingSubmitResult result = submitBuyAction(
            &runtime_,
            panel,
            ui.subscribedSymbol,
            ui.quantityInput,
            ui.priceBuffer,
            source,
            note
        );
        if (result.traceId != 0) {
            updateSelectedTrace(result.traceId);
        }
        json payload = makeActionResult(result.submitted, result.error);
        payload["traceId"] = static_cast<unsigned long long>(result.traceId);
        payload["symbol"] = ui.subscribedSymbol.empty() ? json(nullptr) : json(ui.subscribedSymbol);
        return payload;
    }

    json submitClose(const std::string& source, const std::string& note) {
        const BridgeUIState ui = currentUIState();
        const RuntimePresentationSnapshot presentation =
            runtime_.capturePresentationSnapshot(ui.subscribed ? ui.subscribedSymbol : std::string(), 50);
        const TradingPanelState panel = buildTradingPanelState(
            presentation,
            ui.subscribed,
            ui.quantityInput,
            ui.priceBuffer,
            ui.maxPositionDollars
        );
        const TradingSubmitResult result = submitCloseAction(
            &runtime_,
            panel,
            ui.subscribedSymbol,
            ui.priceBuffer,
            source,
            note
        );
        if (result.traceId != 0) {
            updateSelectedTrace(result.traceId);
        }
        json payload = makeActionResult(result.submitted, result.error);
        payload["traceId"] = static_cast<unsigned long long>(result.traceId);
        payload["symbol"] = ui.subscribedSymbol.empty() ? json(nullptr) : json(ui.subscribedSymbol);
        return payload;
    }

    json cancelAll() {
        return cancelResultToJson(cancelAllOrdersAction(&runtime_));
    }

    json cancelSelected(const std::vector<OrderId>& orderIds) {
        return cancelResultToJson(cancelSelectedOrdersAction(&runtime_, orderIds));
    }

    json reconcileSelected(const std::vector<OrderId>& orderIds) {
        const std::vector<OrderId> accepted = runtime_.requestOrderReconciliation(orderIds);
        json acceptedIds = json::array();
        for (OrderId orderId : accepted) {
            acceptedIds.push_back(static_cast<long long>(orderId));
        }
        return json{
            {"ok", !accepted.empty()},
            {"orderIds", std::move(acceptedIds)}
        };
    }

    json acknowledgeSelected(const std::vector<OrderId>& orderIds) {
        const std::vector<OrderId> acknowledged = runtime_.acknowledgeManualReviewOrders(orderIds);
        json acknowledgedIds = json::array();
        for (OrderId orderId : acknowledged) {
            acknowledgedIds.push_back(static_cast<long long>(orderId));
        }
        return json{
            {"ok", !acknowledged.empty()},
            {"orderIds", std::move(acknowledgedIds)}
        };
    }

    json loadRecovery() {
        const RuntimeRecoverySnapshot recovery = loadRuntimeRecoverySnapshotFromLogs(5);
        return json{
            {"ok", true},
            {"bannerText", recovery.bannerText},
            {"unfinishedTraceCount", recovery.unfinishedTraceCount},
            {"pendingOutboxCount", recovery.pendingOutboxCount}
        };
    }

    json deletePersistentLogs() {
        const RuntimeLogDeleteResult result = deletePersistentRuntimeLogs();
        return json{
            {"ok", result.error.empty()},
            {"error", result.error.empty() ? json(nullptr) : json(result.error)},
            {"deletedTradeTraceLog", result.deletedTradeTraceLog},
            {"deletedRuntimeJournalLog", result.deletedRuntimeJournalLog}
        };
    }

    json traceExportBundle(std::uint64_t traceId) {
        TraceExportBundle bundle;
        std::string error;
        const bool ok = buildTraceExportBundle(traceId, &bundle, &error);
        return json{
            {"ok", ok},
            {"error", error.empty() ? json(nullptr) : json(error)},
            {"baseName", bundle.baseName},
            {"reportText", bundle.reportText},
            {"summaryCsv", bundle.summaryCsv},
            {"fillsCsv", bundle.fillsCsv},
            {"timelineCsv", bundle.timelineCsv}
        };
    }

    std::string allTradesSummaryCsv() {
        return buildAllTradesSummaryCsv();
    }

private:
    BridgeUIState currentUIState() {
        std::lock_guard<std::mutex> lock(mutex_);
        return uiState_;
    }

    void updateQuantity(int quantity) {
        BridgeUIState ui;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            uiState_.quantityInput = std::max(1, quantity);
            ui = uiState_;
        }
        runtime_.syncGuiInputs(ui.quantityInput, ui.priceBuffer, ui.maxPositionDollars);
    }

    void updateSelectedTrace(std::uint64_t traceId) {
        std::lock_guard<std::mutex> lock(mutex_);
        uiState_.selectedTraceId = traceId;
    }

    void updateUIStateFromModel(
        const TradingViewModel& model,
        double priceBuffer,
        double maxPositionDollars
    ) {
        std::lock_guard<std::mutex> lock(mutex_);
        uiState_.symbolInput = model.symbolInput;
        uiState_.subscribedSymbol = model.subscribedSymbol;
        uiState_.subscribed = model.subscribed;
        uiState_.quantityInput = std::max(1, model.quantityInput);
        uiState_.selectedTraceId = model.selectedTraceId;
        uiState_.priceBuffer = priceBuffer;
        uiState_.maxPositionDollars = maxPositionDollars;
    }

    TradingRuntime runtime_;
    std::mutex mutex_;
    BridgeUIState uiState_;
    TradingRuntimeBridgeInvalidationCallback invalidationCallback_ = nullptr;
    void* invalidationContext_ = nullptr;
};

json parseObject(const char* text) {
    if (text == nullptr || text[0] == '\0') {
        return json::object();
    }
    return json::parse(text);
}

} // namespace

struct TradingRuntimeBridgeHandle {
    TradingRuntimeBridgeImpl impl;
};

extern "C" {

TradingRuntimeBridgeHandle* TradingRuntimeBridgeCreate(void) {
    return new TradingRuntimeBridgeHandle();
}

void TradingRuntimeBridgeDestroy(TradingRuntimeBridgeHandle* handle) {
    delete handle;
}

bool TradingRuntimeBridgeStart(TradingRuntimeBridgeHandle* handle) {
    return handle != nullptr && handle->impl.runtime().start();
}

void TradingRuntimeBridgeShutdown(TradingRuntimeBridgeHandle* handle) {
    if (handle != nullptr) {
        handle->impl.runtime().shutdown();
    }
}

void TradingRuntimeBridgeSetInvalidationCallback(
    TradingRuntimeBridgeHandle* handle,
    TradingRuntimeBridgeInvalidationCallback callback,
    void* context
) {
    if (handle != nullptr) {
        handle->impl.setInvalidationCallback(callback, context);
    }
}

void TradingRuntimeBridgeSetUIInputs(
    TradingRuntimeBridgeHandle* handle,
    const char* symbolInput,
    const char* subscribedSymbol,
    bool subscribed,
    int quantityInput,
    double priceBuffer,
    double maxPositionDollars,
    uint64_t selectedTraceId
) {
    if (handle == nullptr) {
        return;
    }
    handle->impl.setUIInputs(
        stringOrEmpty(symbolInput),
        stringOrEmpty(subscribedSymbol),
        subscribed,
        quantityInput,
        priceBuffer,
        maxPositionDollars,
        selectedTraceId
    );
}

char* TradingRuntimeBridgeCopyDashboardJSON(TradingRuntimeBridgeHandle* handle) {
    if (handle == nullptr) {
        return copyCString("{}");
    }
    return copyCString(handle->impl.dashboardJson().dump());
}

char* TradingRuntimeBridgeCopyConnectionJSON(TradingRuntimeBridgeHandle* handle) {
    if (handle == nullptr) {
        return copyCString("{}");
    }
    return copyCString(connectionConfigToJson(handle->impl.runtime().captureConnectionConfig()).dump());
}

char* TradingRuntimeBridgeCopyRiskJSON(TradingRuntimeBridgeHandle* handle) {
    if (handle == nullptr) {
        return copyCString("{}");
    }
    return copyCString(riskControlsToJson(handle->impl.runtime().captureRiskControls()).dump());
}

char* TradingRuntimeBridgeUpdateConnectionJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* jsonText
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }

    RuntimeConnectionConfig config = handle->impl.runtime().captureConnectionConfig();
    try {
        const json payload = parseObject(jsonText);
        if (payload.contains("host") && payload.at("host").is_string()) {
            config.host = payload.at("host").get<std::string>();
        }
        if (payload.contains("port") && payload.at("port").is_number_integer()) {
            config.port = payload.at("port").get<int>();
        }
        if (payload.contains("clientId") && payload.at("clientId").is_number_integer()) {
            config.clientId = payload.at("clientId").get<int>();
        }
        if (payload.contains("controllerEnabled") && payload.at("controllerEnabled").is_boolean()) {
            config.controllerEnabled = payload.at("controllerEnabled").get<bool>();
        }
        if (payload.contains("pegBestOffset") && payload.at("pegBestOffset").is_number()) {
            config.pegBestOffset = payload.at("pegBestOffset").get<double>();
        }
        if (payload.contains("pegBestOffsetUpToMid") && payload.at("pegBestOffsetUpToMid").is_boolean()) {
            config.pegBestOffsetUpToMid = payload.at("pegBestOffsetUpToMid").get<bool>();
        }
        if (payload.contains("pegBestMinCompeteSize") && payload.at("pegBestMinCompeteSize").is_number_integer()) {
            config.pegBestMinCompeteSize = payload.at("pegBestMinCompeteSize").get<int>();
        }
        if (payload.contains("pegBestMidOffsetAtWhole") && payload.at("pegBestMidOffsetAtWhole").is_number()) {
            config.pegBestMidOffsetAtWhole = payload.at("pegBestMidOffsetAtWhole").get<double>();
        }
        if (payload.contains("pegBestMidOffsetAtHalf") && payload.at("pegBestMidOffsetAtHalf").is_number()) {
            config.pegBestMidOffsetAtHalf = payload.at("pegBestMidOffsetAtHalf").get<double>();
        }
        if (payload.contains("pegBestRerouteToSmartMinutes") && payload.at("pegBestRerouteToSmartMinutes").is_number_integer()) {
            config.pegBestRerouteToSmartMinutes = payload.at("pegBestRerouteToSmartMinutes").get<int>();
        }
        handle->impl.runtime().updateConnectionConfig(config);
        return copyCString(makeActionResult(true).dump());
    } catch (const std::exception& error) {
        return copyCString(makeActionResult(false, error.what()).dump());
    }
}

char* TradingRuntimeBridgeUpdateRiskJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* jsonText
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }

    RiskControlsSnapshot risk = handle->impl.runtime().captureRiskControls();
    try {
        const json payload = parseObject(jsonText);
        if (payload.contains("staleQuoteThresholdMs") && payload.at("staleQuoteThresholdMs").is_number_integer()) {
            risk.staleQuoteThresholdMs = payload.at("staleQuoteThresholdMs").get<int>();
        }
        if (payload.contains("brokerEchoTimeoutMs") && payload.at("brokerEchoTimeoutMs").is_number_integer()) {
            risk.brokerEchoTimeoutMs = payload.at("brokerEchoTimeoutMs").get<int>();
        }
        if (payload.contains("cancelAckTimeoutMs") && payload.at("cancelAckTimeoutMs").is_number_integer()) {
            risk.cancelAckTimeoutMs = payload.at("cancelAckTimeoutMs").get<int>();
        }
        if (payload.contains("partialFillQuietTimeoutMs") && payload.at("partialFillQuietTimeoutMs").is_number_integer()) {
            risk.partialFillQuietTimeoutMs = payload.at("partialFillQuietTimeoutMs").get<int>();
        }
        if (payload.contains("maxOrderNotional") && payload.at("maxOrderNotional").is_number()) {
            risk.maxOrderNotional = payload.at("maxOrderNotional").get<double>();
        }
        if (payload.contains("maxOpenNotional") && payload.at("maxOpenNotional").is_number()) {
            risk.maxOpenNotional = payload.at("maxOpenNotional").get<double>();
        }
        if (payload.contains("controllerArmMode") && payload.at("controllerArmMode").is_string()) {
            const std::string mode = payload.at("controllerArmMode").get<std::string>();
            risk.controllerArmMode = mode == "manual" ? ControllerArmMode::Manual : ControllerArmMode::OneShot;
        }
        if (payload.contains("controllerArmed") && payload.at("controllerArmed").is_boolean()) {
            risk.controllerArmed = payload.at("controllerArmed").get<bool>();
        }
        if (payload.contains("tradingKillSwitch") && payload.at("tradingKillSwitch").is_boolean()) {
            risk.tradingKillSwitch = payload.at("tradingKillSwitch").get<bool>();
        }
        handle->impl.runtime().updateRiskControls(risk);
        return copyCString(makeActionResult(true).dump());
    } catch (const std::exception& error) {
        return copyCString(makeActionResult(false, error.what()).dump());
    }
}

char* TradingRuntimeBridgeRequestSubscriptionJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* rawSymbol,
    bool recalcQtyFromFirstAsk
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.requestSubscription(stringOrEmpty(rawSymbol), recalcQtyFromFirstAsk).dump());
}

char* TradingRuntimeBridgeSubmitBuyJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* source,
    const char* note
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.submitBuy(stringOrEmpty(source), stringOrEmpty(note)).dump());
}

char* TradingRuntimeBridgeSubmitCloseJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* source,
    const char* note
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.submitClose(stringOrEmpty(source), stringOrEmpty(note)).dump());
}

char* TradingRuntimeBridgeCancelAllJSON(TradingRuntimeBridgeHandle* handle) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.cancelAll().dump());
}

char* TradingRuntimeBridgeCancelSelectedJSON(
    TradingRuntimeBridgeHandle* handle,
    const int64_t* orderIds,
    size_t count
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.cancelSelected(decodeOrderIds(orderIds, count)).dump());
}

char* TradingRuntimeBridgeReconcileSelectedJSON(
    TradingRuntimeBridgeHandle* handle,
    const int64_t* orderIds,
    size_t count
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.reconcileSelected(decodeOrderIds(orderIds, count)).dump());
}

char* TradingRuntimeBridgeAcknowledgeSelectedJSON(
    TradingRuntimeBridgeHandle* handle,
    const int64_t* orderIds,
    size_t count
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.acknowledgeSelected(decodeOrderIds(orderIds, count)).dump());
}

char* TradingRuntimeBridgeLoadRecoveryJSON(TradingRuntimeBridgeHandle* handle) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.loadRecovery().dump());
}

char* TradingRuntimeBridgeDeletePersistentLogsJSON(TradingRuntimeBridgeHandle* handle) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.deletePersistentLogs().dump());
}

char* TradingRuntimeBridgeCopyTraceExportBundleJSON(
    TradingRuntimeBridgeHandle* handle,
    uint64_t traceId
) {
    if (handle == nullptr) {
        return copyCString(makeActionResult(false, "Trading bridge is unavailable").dump());
    }
    return copyCString(handle->impl.traceExportBundle(traceId).dump());
}

char* TradingRuntimeBridgeCopyAllTradesSummaryCSV(TradingRuntimeBridgeHandle* handle) {
    if (handle == nullptr) {
        return copyCString("");
    }
    return copyCString(handle->impl.allTradesSummaryCsv());
}

void TradingRuntimeBridgeSetControllerArmed(TradingRuntimeBridgeHandle* handle, bool armed) {
    if (handle != nullptr) {
        handle->impl.runtime().setControllerArmed(armed);
    }
}

void TradingRuntimeBridgeSetTradingKillSwitch(TradingRuntimeBridgeHandle* handle, bool enabled) {
    if (handle != nullptr) {
        handle->impl.runtime().setTradingKillSwitch(enabled);
    }
}

void TradingRuntimeBridgeAppendMessage(TradingRuntimeBridgeHandle* handle, const char* message) {
    if (handle != nullptr && message != nullptr) {
        handle->impl.runtime().appendMessage(message);
    }
}

void TradingRuntimeBridgeFreeString(char* text) {
    std::free(text);
}

} // extern "C"
