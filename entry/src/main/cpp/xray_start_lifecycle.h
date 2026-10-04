#ifndef TONGDAO_XRAY_START_LIFECYCLE_H
#define TONGDAO_XRAY_START_LIFECYCLE_H

#include "xray_start_notify.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct XraySettleJob {
    uint64_t ownerSeq = 0;
    std::atomic_bool settled{false};
    int notifyRetriesLeft = XRAY_NOTIFY_RETRY_LIMIT;
    void* tsfn = nullptr;
    void* deferred = nullptr;
    std::mutex notifyMu;
    std::string message;
    bool ok = false;
};

struct XraySettleHooks {
    int (*dispatch)(void* tsfn, void* payload, void* user);
    void (*releaseTsfn)(void* tsfn, void* user);
    void (*reclaimJob)(void* user);
    void* user;
    int napiOk;
    int napiClosing;
};

struct XraySettleResult {
    XrayNotifyAction action = XrayNotifyAction::KeepRetrying;
    int dispatchCalls = 0;
    bool payloadQueued = false;
    bool tsfnReleased = false;
    bool jobReclaimed = false;
    uint64_t stopOwnerSeq = 0;
};

inline bool XrayStillOwnsCore(uint64_t jobOwner, uint64_t liveOwner)
{
    return jobOwner != 0 && liveOwner == jobOwner;
}

XraySettleResult XraySettleNotify(XraySettleJob& job, bool ok, const std::string& message,
    void* payload, const XraySettleHooks& hooks);

bool XrayFinalizeDeferred(XraySettleJob& job, bool envAlive, std::string* outMessage, void** outDeferred);

void XrayTrackStartJob(const std::shared_ptr<void>& job);
void XrayReclaimStartJob(const std::shared_ptr<void>& job);
size_t XrayTrackedStartJobCount();
void XrayClearTrackedStartJobs();

uint64_t XrayClaimOwner(std::atomic<uint64_t>& liveOwner, uint64_t jobOwner);
bool XrayReleaseOwner(std::atomic<uint64_t>& liveOwner, uint64_t jobOwner);

struct XrayCoreIdentity {
    std::atomic<uint64_t> liveOwner{0};
    std::atomic<uint64_t> stopInFlight{0};
    std::atomic_bool running{false};
    std::mutex inboundMu;
    std::vector<uint16_t> inboundPorts;
};

struct XrayFinishOutcome {
    bool reportOk = false;
    bool requestStop = false;
    uint64_t stopOwnerSeq = 0;
};

XrayFinishOutcome XrayFinishStartedJob(XrayCoreIdentity& core, uint64_t ownerSeq, bool cgoOk, bool abandon);

struct XrayStopPermit {
    bool allowPhysicalStop = false;
    bool alreadyInFlight = false;
    uint64_t ownerSeq = 0;
};

XrayStopPermit XrayAcquireStopPermit(XrayCoreIdentity& core, uint64_t requiredOwner);
bool XrayStopPermitStillValid(const XrayCoreIdentity& core, XrayStopPermit permit);
void XrayCompleteStopPermit(XrayCoreIdentity& core, XrayStopPermit permit, bool physicalStopped);
bool XrayStartBlockedByStop(const XrayCoreIdentity& core);

struct XrayPhysicalStopHooks {
    bool (*cgoStop)(void* user);
    void* user;
};

enum class XrayPhysicalStopResult {
    Stopped = 0,
    Skipped = 1,
    Failed = 2
};

XrayPhysicalStopResult XrayRunPermittedStop(XrayCoreIdentity& core, XrayStopPermit permit,
    const XrayPhysicalStopHooks& hooks, std::string* detail = nullptr);

std::vector<uint16_t> XrayParseInboundListenPorts(const std::string& json);
void XrayRememberInboundPorts(XrayCoreIdentity& core, const std::vector<uint16_t>& ports);
std::vector<uint16_t> XrayCopyInboundPorts(XrayCoreIdentity& core);
void XrayClearInboundPorts(XrayCoreIdentity& core);
bool XrayLoopbackSocksLive(uint16_t port, int timeoutMs = 200);
bool XrayAnyInboundSocksLive(const std::vector<uint16_t>& ports, uint16_t* livePort);

struct XrayNotifyInject {
    bool present = false;
    bool keepFile = false;
    int failRemaining = 0;
    bool forceGenericFailure = false;
};

XrayNotifyInject XrayInspectNotifyInject(const char* path);

#endif
