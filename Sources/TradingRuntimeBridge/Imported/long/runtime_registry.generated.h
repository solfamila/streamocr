#pragma once

#include <array>
#include <string_view>

namespace runtime_registry {

inline constexpr int kRegistryVersion = 1;

enum class SubsystemId {
    LongBridge,
    TapeEngine,
    Tapescope,
    TapeMcp,
};

constexpr std::string_view subsystemName(SubsystemId id) {
    switch (id) {
        case SubsystemId::LongBridge:
            return "com.foxy.long.bridge";
        case SubsystemId::TapeEngine:
            return "com.foxy.tape-engine";
        case SubsystemId::Tapescope:
            return "com.foxy.tapescope";
        case SubsystemId::TapeMcp:
            return "com.foxy.tape-mcp";
        default:
            return "";
    }
}

enum class LogCategory {
    Bridge,
    Ingest,
    Sequencer,
    Recorder,
    Revision,
    Replay,
    Analyzer,
    Rpc,
    Ui,
    Metal,
    Export,
    Housekeeping,
};

constexpr std::string_view logCategoryName(LogCategory category) {
    switch (category) {
        case LogCategory::Bridge:
            return "bridge";
        case LogCategory::Ingest:
            return "ingest";
        case LogCategory::Sequencer:
            return "sequencer";
        case LogCategory::Recorder:
            return "recorder";
        case LogCategory::Revision:
            return "revision";
        case LogCategory::Replay:
            return "replay";
        case LogCategory::Analyzer:
            return "analyzer";
        case LogCategory::Rpc:
            return "rpc";
        case LogCategory::Ui:
            return "ui";
        case LogCategory::Metal:
            return "metal";
        case LogCategory::Export:
            return "export";
        case LogCategory::Housekeeping:
            return "housekeeping";
        default:
            return "";
    }
}

enum class QueueId {
    BridgeCapture,
    BridgeSender,
    OutboxJournal,
    OutboxDrain,
    EngineAcceptLoop,
    EngineSequencer,
    EngineSegmentWriter,
    EngineReplay,
    EngineAnalyzerDeferred,
    TapescopeMainUi,
    TapescopeSnapshotDecode,
    TapescopeReplayScrub,
    TapescopeMetalPrep,
    TapescopeReportRender,
    TapeMcpRequestLoop,
    TapeMcpReads,
    TapeMcpExports,
};

struct QueueSpec {
    QueueId id;
    SubsystemId subsystem;
    LogCategory category;
    std::string_view label;
    std::string_view qosName;
};

inline constexpr std::array<QueueSpec, 17> kQueueSpecs = {{
    {QueueId::BridgeCapture, SubsystemId::LongBridge, LogCategory::Bridge, "com.foxy.long.bridge.capture", "inherited"},
    {QueueId::BridgeSender, SubsystemId::LongBridge, LogCategory::Bridge, "com.foxy.long.bridge.sender", "userInitiated"},
    {QueueId::OutboxJournal, SubsystemId::LongBridge, LogCategory::Bridge, "com.foxy.long.bridge.outbox-journal", "utility"},
    {QueueId::OutboxDrain, SubsystemId::LongBridge, LogCategory::Bridge, "com.foxy.long.bridge.outbox-drain", "utility"},
    {QueueId::EngineAcceptLoop, SubsystemId::TapeEngine, LogCategory::Rpc, "com.foxy.tape-engine.accept-loop", "utility"},
    {QueueId::EngineSequencer, SubsystemId::TapeEngine, LogCategory::Sequencer, "com.foxy.tape-engine.sequencer", "userInitiated"},
    {QueueId::EngineSegmentWriter, SubsystemId::TapeEngine, LogCategory::Recorder, "com.foxy.tape-engine.segment-writer", "utility"},
    {QueueId::EngineReplay, SubsystemId::TapeEngine, LogCategory::Replay, "com.foxy.tape-engine.replay", "utility"},
    {QueueId::EngineAnalyzerDeferred, SubsystemId::TapeEngine, LogCategory::Analyzer, "com.foxy.tape-engine.analyzer-deferred", "utility"},
    {QueueId::TapescopeMainUi, SubsystemId::Tapescope, LogCategory::Ui, "com.foxy.tapescope.main", "userInteractive"},
    {QueueId::TapescopeSnapshotDecode, SubsystemId::Tapescope, LogCategory::Ui, "com.foxy.tapescope.snapshot-decode", "userInitiated"},
    {QueueId::TapescopeReplayScrub, SubsystemId::Tapescope, LogCategory::Replay, "com.foxy.tapescope.replay-scrub", "userInitiated"},
    {QueueId::TapescopeMetalPrep, SubsystemId::Tapescope, LogCategory::Metal, "com.foxy.tapescope.metal-prep", "utility"},
    {QueueId::TapescopeReportRender, SubsystemId::Tapescope, LogCategory::Export, "com.foxy.tapescope.report-render", "utility"},
    {QueueId::TapeMcpRequestLoop, SubsystemId::TapeMcp, LogCategory::Rpc, "com.foxy.tape-mcp.request-loop", "utility"},
    {QueueId::TapeMcpReads, SubsystemId::TapeMcp, LogCategory::Rpc, "com.foxy.tape-mcp.reads", "userInitiated"},
    {QueueId::TapeMcpExports, SubsystemId::TapeMcp, LogCategory::Export, "com.foxy.tape-mcp.exports", "utility"},
}};

constexpr QueueSpec queueSpec(QueueId id) {
    switch (id) {
        case QueueId::BridgeCapture:
            return kQueueSpecs[0];
        case QueueId::BridgeSender:
            return kQueueSpecs[1];
        case QueueId::OutboxJournal:
            return kQueueSpecs[2];
        case QueueId::OutboxDrain:
            return kQueueSpecs[3];
        case QueueId::EngineAcceptLoop:
            return kQueueSpecs[4];
        case QueueId::EngineSequencer:
            return kQueueSpecs[5];
        case QueueId::EngineSegmentWriter:
            return kQueueSpecs[6];
        case QueueId::EngineReplay:
            return kQueueSpecs[7];
        case QueueId::EngineAnalyzerDeferred:
            return kQueueSpecs[8];
        case QueueId::TapescopeMainUi:
            return kQueueSpecs[9];
        case QueueId::TapescopeSnapshotDecode:
            return kQueueSpecs[10];
        case QueueId::TapescopeReplayScrub:
            return kQueueSpecs[11];
        case QueueId::TapescopeMetalPrep:
            return kQueueSpecs[12];
        case QueueId::TapescopeReportRender:
            return kQueueSpecs[13];
        case QueueId::TapeMcpRequestLoop:
            return kQueueSpecs[14];
        case QueueId::TapeMcpReads:
            return kQueueSpecs[15];
        case QueueId::TapeMcpExports:
            return kQueueSpecs[16];
        default:
            return kQueueSpecs[0];
    }
}

inline constexpr std::string_view kObservabilitySubsystem = subsystemName(SubsystemId::LongBridge);

} // namespace runtime_registry
