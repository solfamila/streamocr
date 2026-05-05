#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TradingRuntimeBridgeHandle TradingRuntimeBridgeHandle;
typedef void (*TradingRuntimeBridgeInvalidationCallback)(void* context);

TradingRuntimeBridgeHandle* TradingRuntimeBridgeCreate(void);
void TradingRuntimeBridgeDestroy(TradingRuntimeBridgeHandle* handle);

bool TradingRuntimeBridgeStart(TradingRuntimeBridgeHandle* handle);
void TradingRuntimeBridgeShutdown(TradingRuntimeBridgeHandle* handle);

void TradingRuntimeBridgeSetInvalidationCallback(
    TradingRuntimeBridgeHandle* handle,
    TradingRuntimeBridgeInvalidationCallback callback,
    void* context
);

void TradingRuntimeBridgeSetUIInputs(
    TradingRuntimeBridgeHandle* handle,
    const char* symbolInput,
    const char* subscribedSymbol,
    bool subscribed,
    int quantityInput,
    double priceBuffer,
    double maxPositionDollars,
    uint64_t selectedTraceId
);
void TradingRuntimeBridgeSetQuantityInput(
    TradingRuntimeBridgeHandle* handle,
    int quantityInput
);

char* TradingRuntimeBridgeCopyDashboardJSON(TradingRuntimeBridgeHandle* handle);
char* TradingRuntimeBridgeCopyConnectionJSON(TradingRuntimeBridgeHandle* handle);
char* TradingRuntimeBridgeCopyRiskJSON(TradingRuntimeBridgeHandle* handle);

char* TradingRuntimeBridgeUpdateConnectionJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* jsonText
);
char* TradingRuntimeBridgeUpdateRiskJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* jsonText
);

char* TradingRuntimeBridgeRequestSubscriptionJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* rawSymbol,
    bool recalcQtyFromFirstAsk
);
char* TradingRuntimeBridgeSubmitBuyJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* source,
    const char* note
);
char* TradingRuntimeBridgeSubmitCloseJSON(
    TradingRuntimeBridgeHandle* handle,
    const char* source,
    const char* note
);
char* TradingRuntimeBridgeCancelAllJSON(TradingRuntimeBridgeHandle* handle);
char* TradingRuntimeBridgeCancelSelectedJSON(
    TradingRuntimeBridgeHandle* handle,
    const int64_t* orderIds,
    size_t count
);
char* TradingRuntimeBridgeReconcileSelectedJSON(
    TradingRuntimeBridgeHandle* handle,
    const int64_t* orderIds,
    size_t count
);
char* TradingRuntimeBridgeAcknowledgeSelectedJSON(
    TradingRuntimeBridgeHandle* handle,
    const int64_t* orderIds,
    size_t count
);
char* TradingRuntimeBridgeLoadRecoveryJSON(TradingRuntimeBridgeHandle* handle);
char* TradingRuntimeBridgeDeletePersistentLogsJSON(TradingRuntimeBridgeHandle* handle);
char* TradingRuntimeBridgeCopyTraceExportBundleJSON(
    TradingRuntimeBridgeHandle* handle,
    uint64_t traceId
);
char* TradingRuntimeBridgeCopyAllTradesSummaryCSV(TradingRuntimeBridgeHandle* handle);

void TradingRuntimeBridgeSetControllerArmed(TradingRuntimeBridgeHandle* handle, bool armed);
void TradingRuntimeBridgeSetTradingKillSwitch(TradingRuntimeBridgeHandle* handle, bool enabled);
void TradingRuntimeBridgeAppendMessage(TradingRuntimeBridgeHandle* handle, const char* message);

void TradingRuntimeBridgeFreeString(char* text);

#ifdef __cplusplus
}
#endif
