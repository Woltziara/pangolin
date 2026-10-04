#include "xray_start_lifecycle.h"

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {

std::mutex g_trackMu;
std::vector<std::shared_ptr<void>> g_trackedStartJobs;

}  // namespace

XraySettleResult XraySettleNotify(XraySettleJob& job, bool ok, const std::string& message,
    void* payload, const XraySettleHooks& hooks)
{
    XraySettleResult out;
    void* tsfnToRelease = nullptr;
    bool reclaim = false;
    {
        std::lock_guard<std::mutex> lock(job.notifyMu);
        if (job.settled.load()) {
            out.action = XrayNotifyAction::AlreadySettled;
            return out;
        }
        if (job.tsfn == nullptr || job.deferred == nullptr) {
            out.action = XrayNotifyAction::AlreadySettled;
            return out;
        }
        job.ok = ok;
        job.message = message;
        while (true) {
            const int status = hooks.dispatch != nullptr ? hooks.dispatch(job.tsfn, payload, hooks.user)
                                                         : hooks.napiClosing;
            out.dispatchCalls += 1;
            const XrayTsfnFate fate = XrayClassifyTsfnStatus(status, hooks.napiOk, hooks.napiClosing);
            const XrayNotifyAction action = XrayAdvanceNotify(job.notifyRetriesLeft, fate);
            out.action = action;
            if (action == XrayNotifyAction::Dispatched) {
                job.settled.store(true);
                job.deferred = nullptr;
                job.tsfn = nullptr;
                out.payloadQueued = true;
                return out;
            }
            if (action == XrayNotifyAction::ClosingDrop) {
                job.settled.store(true);
                job.deferred = nullptr;
                job.tsfn = nullptr;
                reclaim = true;
                break;
            }
            if (action == XrayNotifyAction::Abandon) {
                job.settled.store(true);
                job.ok = false;
                job.message = "Xray start notify failed";
                tsfnToRelease = job.tsfn;
                job.tsfn = nullptr;
                out.stopOwnerSeq = job.ownerSeq;
                reclaim = true;
                break;
            }
            usleep(2000);
        }
    }
    if (tsfnToRelease != nullptr && hooks.releaseTsfn != nullptr) {
        hooks.releaseTsfn(tsfnToRelease, hooks.user);
        out.tsfnReleased = true;
    }
    if (reclaim && hooks.reclaimJob != nullptr) {
        hooks.reclaimJob(hooks.user);
        out.jobReclaimed = true;
    }
    return out;
}

bool XrayFinalizeDeferred(XraySettleJob& job, bool envAlive, std::string* outMessage, void** outDeferred)
{
    std::lock_guard<std::mutex> lock(job.notifyMu);
    job.tsfn = nullptr;
    if (outDeferred != nullptr) {
        *outDeferred = nullptr;
    }
    if (!envAlive || job.deferred == nullptr) {
        job.deferred = nullptr;
        return false;
    }
    if (outMessage != nullptr) {
        *outMessage = job.message.length() > 0 ? job.message : "Xray start notify failed";
    }
    if (outDeferred != nullptr) {
        *outDeferred = job.deferred;
    }
    job.deferred = nullptr;
    return true;
}

void XrayTrackStartJob(const std::shared_ptr<void>& job)
{
    if (!job) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_trackMu);
    g_trackedStartJobs.push_back(job);
}

void XrayReclaimStartJob(const std::shared_ptr<void>& job)
{
    if (!job) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_trackMu);
    g_trackedStartJobs.erase(std::remove(g_trackedStartJobs.begin(), g_trackedStartJobs.end(), job),
        g_trackedStartJobs.end());
}

size_t XrayTrackedStartJobCount()
{
    std::lock_guard<std::mutex> lock(g_trackMu);
    return g_trackedStartJobs.size();
}

void XrayClearTrackedStartJobs()
{
    std::lock_guard<std::mutex> lock(g_trackMu);
    g_trackedStartJobs.clear();
}

uint64_t XrayClaimOwner(std::atomic<uint64_t>& liveOwner, uint64_t jobOwner)
{
    if (jobOwner == 0) {
        return liveOwner.load();
    }
    uint64_t expected = 0;
    if (liveOwner.compare_exchange_strong(expected, jobOwner)) {
        return jobOwner;
    }
    if (expected == jobOwner) {
        return jobOwner;
    }
    return expected;
}

bool XrayReleaseOwner(std::atomic<uint64_t>& liveOwner, uint64_t jobOwner)
{
    uint64_t expected = jobOwner;
    return liveOwner.compare_exchange_strong(expected, 0);
}

XrayFinishOutcome XrayFinishStartedJob(XrayCoreIdentity& core, uint64_t ownerSeq, bool cgoOk, bool abandon)
{
    XrayFinishOutcome out;
    if (!cgoOk) {
        return out;
    }
    const uint64_t inFlight = core.stopInFlight.load();
    if (inFlight != 0 && inFlight != ownerSeq) {
        return out;
    }
    if (XrayClaimOwner(core.liveOwner, ownerSeq) != ownerSeq) {
        return out;
    }
    core.running.store(true);
    if (abandon) {
        out.requestStop = true;
        out.stopOwnerSeq = ownerSeq;
        return out;
    }
    out.reportOk = true;
    return out;
}

XrayStopPermit XrayAcquireStopPermit(XrayCoreIdentity& core, uint64_t requiredOwner)
{
    XrayStopPermit permit;
    const uint64_t live = core.liveOwner.load();
    const uint64_t ticket = requiredOwner != 0 ? requiredOwner : live;
    if (ticket == 0) {
        return permit;
    }
    if (requiredOwner != 0 && live != requiredOwner) {
        return permit;
    }
    uint64_t expected = 0;
    if (core.stopInFlight.compare_exchange_strong(expected, ticket)) {
        permit.allowPhysicalStop = true;
        permit.ownerSeq = ticket;
        return permit;
    }
    if (expected == ticket) {
        permit.alreadyInFlight = true;
        permit.ownerSeq = ticket;
        return permit;
    }
    return permit;
}

bool XrayStopPermitStillValid(const XrayCoreIdentity& core, XrayStopPermit permit)
{
    if (!permit.allowPhysicalStop || permit.ownerSeq == 0) {
        return false;
    }
    if (core.stopInFlight.load() != permit.ownerSeq) {
        return false;
    }
    return XrayStillOwnsCore(permit.ownerSeq, core.liveOwner.load());
}

void XrayCompleteStopPermit(XrayCoreIdentity& core, XrayStopPermit permit, bool physicalStopped)
{
    if (permit.ownerSeq == 0) {
        return;
    }
    if (physicalStopped) {
        if (XrayReleaseOwner(core.liveOwner, permit.ownerSeq)) {
            core.running.store(false);
        }
    }
    uint64_t expected = permit.ownerSeq;
    core.stopInFlight.compare_exchange_strong(expected, 0);
}

bool XrayStartBlockedByStop(const XrayCoreIdentity& core)
{
    return core.stopInFlight.load() != 0;
}

XrayNotifyInject XrayInspectNotifyInject(const char* path)
{
    XrayNotifyInject out;
    if (path == nullptr || path[0] == '\0') {
        return out;
    }
    FILE* inject = std::fopen(path, "r");
    if (inject == nullptr) {
        return out;
    }
    char buf[32] = {0};
    std::fread(buf, 1, sizeof(buf) - 1, inject);
    std::fclose(inject);
    out.present = true;
    if (std::strncmp(buf, "forever", 7) == 0) {
        out.keepFile = true;
        out.failRemaining = -1;
        out.forceGenericFailure = true;
    }
    return out;
}

std::vector<uint16_t> XrayParseInboundListenPorts(const std::string& json)
{
    std::vector<uint16_t> ports;
    const auto inbounds = json.find("\"inbounds\"");
    if (inbounds == std::string::npos) {
        return ports;
    }
    const auto arrayStart = json.find('[', inbounds);
    if (arrayStart == std::string::npos) {
        return ports;
    }
    int depth = 0;
    bool inString = false;
    bool escape = false;
    for (size_t i = arrayStart; i < json.size(); ++i) {
        const char c = json[i];
        if (inString) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') {
                inString = false;
            }
            continue;
        }
        if (c == '"') {
            inString = true;
            if (json.compare(i, 6, "\"port\"") == 0 && depth >= 1) {
                size_t colon = json.find(':', i + 6);
                if (colon != std::string::npos) {
                    char* end = nullptr;
                    const long value = std::strtol(json.c_str() + colon + 1, &end, 10);
                    if (end != json.c_str() + colon + 1 && value > 0 && value <= 65535) {
                        const auto port = static_cast<uint16_t>(value);
                        if (std::find(ports.begin(), ports.end(), port) == ports.end()) {
                            ports.push_back(port);
                        }
                    }
                }
            }
            continue;
        }
        if (c == '[' || c == '{') {
            depth += 1;
        } else if (c == ']' || c == '}') {
            depth -= 1;
            if (c == ']' && depth == 0) {
                break;
            }
        }
    }
    return ports;
}

void XrayRememberInboundPorts(XrayCoreIdentity& core, const std::vector<uint16_t>& ports)
{
    std::lock_guard<std::mutex> lock(core.inboundMu);
    core.inboundPorts = ports;
}

std::vector<uint16_t> XrayCopyInboundPorts(XrayCoreIdentity& core)
{
    std::lock_guard<std::mutex> lock(core.inboundMu);
    return core.inboundPorts;
}

void XrayClearInboundPorts(XrayCoreIdentity& core)
{
    std::lock_guard<std::mutex> lock(core.inboundMu);
    core.inboundPorts.clear();
}

bool XrayLoopbackSocksLive(uint16_t port, int timeoutMs)
{
    if (port == 0) {
        return false;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const int rc = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    if (rc != 0 && errno != EINPROGRESS) {
        close(fd);
        return false;
    }
    pollfd pfd {};
    pfd.fd = fd;
    pfd.events = POLLOUT;
    if (poll(&pfd, 1, timeoutMs) <= 0) {
        close(fd);
        return false;
    }
    int err = 0;
    socklen_t errLen = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) != 0 || err != 0) {
        close(fd);
        return false;
    }
    const unsigned char hello[3] = {0x05, 0x01, 0x00};
    if (send(fd, hello, sizeof(hello), 0) != static_cast<ssize_t>(sizeof(hello))) {
        close(fd);
        return false;
    }
    pfd.events = POLLIN;
    if (poll(&pfd, 1, timeoutMs) <= 0) {
        close(fd);
        return false;
    }
    unsigned char reply[2] = {0, 0};
    const ssize_t n = recv(fd, reply, sizeof(reply), 0);
    close(fd);
    return n >= 1 && reply[0] == 0x05;
}

bool XrayAnyInboundSocksLive(const std::vector<uint16_t>& ports, uint16_t* livePort)
{
    for (uint16_t port : ports) {
        if (XrayLoopbackSocksLive(port, 200)) {
            if (livePort != nullptr) {
                *livePort = port;
            }
            return true;
        }
    }
    return false;
}

XrayPhysicalStopResult XrayRunPermittedStop(XrayCoreIdentity& core, XrayStopPermit permit,
    const XrayPhysicalStopHooks& hooks, std::string* detail)
{
    if (!XrayStopPermitStillValid(core, permit)) {
        XrayCompleteStopPermit(core, permit, false);
        return XrayPhysicalStopResult::Skipped;
    }
    bool ok = hooks.cgoStop != nullptr ? hooks.cgoStop(hooks.user) : true;
    const std::vector<uint16_t> ports = XrayCopyInboundPorts(core);
    uint16_t livePort = 0;
    if (XrayAnyInboundSocksLive(ports, &livePort)) {
        ok = false;
        if (detail != nullptr) {
            *detail = std::string("xray stop left live socks on ") + std::to_string(livePort);
        }
    } else if (ok) {
        XrayClearInboundPorts(core);
    }
    XrayCompleteStopPermit(core, permit, ok);
    return ok ? XrayPhysicalStopResult::Stopped : XrayPhysicalStopResult::Failed;
}
