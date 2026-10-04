#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <netinet/in.h>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <arpa/inet.h>

#include "../entry/src/main/cpp/xray_start_lifecycle.h"

namespace {

constexpr int kNapiOk = 0;
constexpr int kNapiClosing = 16;
constexpr int kNapiGeneric = 9;

struct Harness {
    int failBudget = 0;
    int alwaysStatus = kNapiOk;
    int dispatchCalls = 0;
    int releaseCalls = 0;
    int reclaimCalls = 0;
    std::shared_ptr<void> tracked;
};

int DispatchFromHarness(void* tsfn, void* payload, void* user)
{
    (void)tsfn;
    (void)payload;
    auto* h = static_cast<Harness*>(user);
    h->dispatchCalls += 1;
    if (h->alwaysStatus != kNapiOk) {
        return h->alwaysStatus;
    }
    if (h->failBudget > 0) {
        h->failBudget -= 1;
        return kNapiGeneric;
    }
    return kNapiOk;
}

void ReleaseFromHarness(void* tsfn, void* user)
{
    (void)tsfn;
    auto* h = static_cast<Harness*>(user);
    h->releaseCalls += 1;
}

void ReclaimFromHarness(void* user)
{
    auto* h = static_cast<Harness*>(user);
    h->reclaimCalls += 1;
    XrayReclaimStartJob(h->tracked);
}

XraySettleHooks MakeHooks(Harness* h)
{
    XraySettleHooks hooks{};
    hooks.dispatch = DispatchFromHarness;
    hooks.releaseTsfn = ReleaseFromHarness;
    hooks.reclaimJob = ReclaimFromHarness;
    hooks.user = h;
    hooks.napiOk = kNapiOk;
    hooks.napiClosing = kNapiClosing;
    return hooks;
}

std::shared_ptr<XraySettleJob> NewJob(uint64_t owner)
{
    auto job = std::make_shared<XraySettleJob>();
    job->ownerSeq = owner;
    job->tsfn = job.get();
    job->deferred = job.get();
    return job;
}

bool CountingCgoStop(void* user)
{
    auto* count = static_cast<std::atomic<int>*>(user);
    count->fetch_add(1);
    return true;
}

XrayPhysicalStopHooks CountingHooks(std::atomic<int>* count)
{
    XrayPhysicalStopHooks hooks{};
    hooks.cgoStop = CountingCgoStop;
    hooks.user = count;
    return hooks;
}

}  // namespace

int main(void)
{
    XrayClearTrackedStartJobs();

    {
        Harness h;
        auto job = NewJob(1);
        h.tracked = job;
        XrayTrackStartJob(job);
        int payload = 1;
        const XraySettleResult r = XraySettleNotify(*job, true, "Xray core started.", &payload, MakeHooks(&h));
        assert(r.action == XrayNotifyAction::Dispatched);
        assert(r.payloadQueued);
        assert(r.dispatchCalls == 1);
        assert(!r.tsfnReleased);
        assert(r.stopOwnerSeq == 0);
        assert(job->settled.load());
        assert(job->tsfn == nullptr);
        assert(XrayTrackedStartJobCount() == 1);
        XrayReclaimStartJob(job);
        assert(XrayTrackedStartJobCount() == 0);
    }

    {
        Harness h;
        h.failBudget = 2;
        auto job = NewJob(2);
        h.tracked = job;
        XrayTrackStartJob(job);
        int payload = 1;
        const XraySettleResult r = XraySettleNotify(*job, true, "Xray core started.", &payload, MakeHooks(&h));
        assert(r.action == XrayNotifyAction::Dispatched);
        assert(r.dispatchCalls == 3);
        assert(r.stopOwnerSeq == 0);
        assert(!r.tsfnReleased);
        XrayReclaimStartJob(job);
    }

    {
        Harness h;
        h.alwaysStatus = kNapiGeneric;
        auto job = NewJob(11);
        h.tracked = job;
        XrayTrackStartJob(job);
        assert(XrayTrackedStartJobCount() == 1);
        int payload = 1;
        const auto started = std::chrono::steady_clock::now();
        const XraySettleResult r = XraySettleNotify(*job, true, "Xray core started.", &payload, MakeHooks(&h));
        const auto elapsed = std::chrono::steady_clock::now() - started;
        assert(r.action == XrayNotifyAction::Abandon);
        assert(r.dispatchCalls == XRAY_NOTIFY_RETRY_LIMIT);
        assert(r.tsfnReleased);
        assert(h.releaseCalls == 1);
        assert(r.jobReclaimed);
        assert(h.reclaimCalls == 1);
        assert(!r.payloadQueued);
        assert(r.stopOwnerSeq == 11);
        assert(job->ok == false);
        assert(job->message == "Xray start notify failed");
        assert(job->tsfn == nullptr);
        assert(job->deferred != nullptr);
        assert(XrayTrackedStartJobCount() == 0);
        assert(elapsed < std::chrono::milliseconds(200));

        std::string failText;
        void* deferred = nullptr;
        assert(XrayFinalizeDeferred(*job, true, &failText, &deferred));
        assert(failText == "Xray start notify failed");
        assert(deferred == job.get());
        assert(job->deferred == nullptr);
        assert(!XrayFinalizeDeferred(*job, true, &failText, &deferred));

        const XraySettleResult again = XraySettleNotify(*job, true, "late", &payload, MakeHooks(&h));
        assert(again.action == XrayNotifyAction::AlreadySettled);
        assert(again.dispatchCalls == 0);
        assert(!again.tsfnReleased);
        assert(h.releaseCalls == 1);
        assert(XrayTrackedStartJobCount() == 0);

        XrayCoreIdentity core;
        const XrayFinishOutcome startedCore = XrayFinishStartedJob(core, r.stopOwnerSeq, true, false);
        assert(startedCore.reportOk);
        std::atomic<int> cgo{0};
        const XrayStopPermit permit = XrayAcquireStopPermit(core, r.stopOwnerSeq);
        assert(permit.allowPhysicalStop);
        assert(XrayRunPermittedStop(core, permit, CountingHooks(&cgo)) == XrayPhysicalStopResult::Stopped);
        assert(cgo.load() == 1);
        assert(!core.running.load());
        assert(core.liveOwner.load() == 0);
    }

    {
        Harness h;
        h.alwaysStatus = kNapiGeneric;
        auto jobA = NewJob(1);
        h.tracked = jobA;
        XrayTrackStartJob(jobA);
        int payload = 1;
        const XraySettleResult r = XraySettleNotify(*jobA, true, "Xray core started.", &payload, MakeHooks(&h));
        assert(r.action == XrayNotifyAction::Abandon);
        assert(r.stopOwnerSeq == 1);
        XrayCoreIdentity core;
        assert(XrayFinishStartedJob(core, 2, true, false).reportOk);
        std::atomic<int> cgo{0};
        const XrayStopPermit permit = XrayAcquireStopPermit(core, r.stopOwnerSeq);
        assert(!permit.allowPhysicalStop);
        assert(XrayRunPermittedStop(core, permit, CountingHooks(&cgo)) == XrayPhysicalStopResult::Skipped);
        assert(cgo.load() == 0);
        assert(core.liveOwner.load() == 2);
        assert(core.running.load());
        assert(XrayStillOwnsCore(2, core.liveOwner.load()));
        assert(!XrayStillOwnsCore(1, core.liveOwner.load()));
        assert(XrayTrackedStartJobCount() == 0);
    }

    {
        Harness h;
        h.alwaysStatus = kNapiClosing;
        auto job = NewJob(3);
        h.tracked = job;
        XrayTrackStartJob(job);
        int payload = 1;
        const XraySettleResult r = XraySettleNotify(*job, true, "Xray core started.", &payload, MakeHooks(&h));
        assert(r.action == XrayNotifyAction::ClosingDrop);
        assert(!r.tsfnReleased);
        assert(h.releaseCalls == 0);
        assert(r.jobReclaimed);
        assert(r.stopOwnerSeq == 0);
        assert(job->deferred == nullptr);
        std::string failText;
        void* deferred = nullptr;
        assert(!XrayFinalizeDeferred(*job, true, &failText, &deferred));
        assert(XrayTrackedStartJobCount() == 0);
    }

    {
        Harness h;
        h.alwaysStatus = kNapiGeneric;
        auto job = NewJob(4);
        h.tracked = job;
        XrayTrackStartJob(job);
        int payload = 1;
        const auto started = std::chrono::steady_clock::now();
        const XraySettleResult r = XraySettleNotify(*job, true, "Xray core started.", &payload, MakeHooks(&h));
        const auto elapsed = std::chrono::steady_clock::now() - started;
        assert(r.action == XrayNotifyAction::Abandon);
        assert(r.tsfnReleased);
        assert(r.jobReclaimed);
        assert(r.stopOwnerSeq == 4);
        assert(elapsed < std::chrono::milliseconds(200));
        assert(XrayTrackedStartJobCount() == 0);
        XrayCoreIdentity core;
        assert(XrayFinishStartedJob(core, r.stopOwnerSeq, true, false).reportOk);
        std::atomic<int> cgo{0};
        std::thread hungStop([&]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(400));
            const XrayStopPermit permit = XrayAcquireStopPermit(core, r.stopOwnerSeq);
            XrayRunPermittedStop(core, permit, CountingHooks(&cgo));
        });
        assert(job->tsfn == nullptr);
        assert(cgo.load() == 0);
        hungStop.join();
        assert(cgo.load() == 1);
        assert(!core.running.load());
    }

    {
        std::atomic_bool owned{true};
        assert(XrayTakeWorkerReap(owned));
        assert(!XrayTakeWorkerReap(owned));
    }

    {
        std::atomic<uint64_t> live{0};
        assert(XrayClaimOwner(live, 9) == 9);
        assert(!XrayReleaseOwner(live, 8));
        assert(live.load() == 9);
        assert(XrayReleaseOwner(live, 9));
        assert(live.load() == 0);
        assert(XrayClaimOwner(live, 3) == 3);
        assert(XrayClaimOwner(live, 4) == 3);
        assert(live.load() == 3);
    }

    {
        XrayCoreIdentity core;
        const XrayFinishOutcome out = XrayFinishStartedJob(core, 11, true, true);
        assert(!out.reportOk);
        assert(out.requestStop);
        assert(out.stopOwnerSeq == 11);
        assert(core.running.load());
        assert(core.liveOwner.load() == 11);
        std::atomic<int> cgo{0};
        const XrayStopPermit permit = XrayAcquireStopPermit(core, 11);
        assert(permit.allowPhysicalStop);
        assert(XrayStartBlockedByStop(core));
        assert(XrayRunPermittedStop(core, permit, CountingHooks(&cgo)) == XrayPhysicalStopResult::Stopped);
        assert(cgo.load() == 1);
        assert(!core.running.load());
        assert(core.liveOwner.load() == 0);
        assert(!XrayStartBlockedByStop(core));
    }

    {
        XrayCoreIdentity failed;
        const XrayFinishOutcome out = XrayFinishStartedJob(failed, 8, false, true);
        assert(!out.reportOk);
        assert(!out.requestStop);
        assert(!failed.running.load());
        const XrayStopPermit permit = XrayAcquireStopPermit(failed, 8);
        assert(!permit.allowPhysicalStop);
    }

    {
        XrayCoreIdentity core;
        assert(XrayFinishStartedJob(core, 1, true, false).reportOk);
        const XrayStopPermit permitA = XrayAcquireStopPermit(core, 1);
        assert(permitA.allowPhysicalStop);
        assert(XrayStartBlockedByStop(core));
        const XrayFinishOutcome b = XrayFinishStartedJob(core, 2, true, false);
        assert(!b.reportOk);
        assert(core.liveOwner.load() == 1);
        std::atomic<int> cgo{0};
        std::atomic_bool go{false};
        XrayPhysicalStopResult stopResult = XrayPhysicalStopResult::Failed;
        std::thread stopper([&]() {
            while (!go.load()) {
                std::this_thread::yield();
            }
            stopResult = XrayRunPermittedStop(core, permitA, CountingHooks(&cgo));
        });
        core.liveOwner.store(2);
        core.running.store(true);
        go.store(true);
        stopper.join();
        assert(stopResult == XrayPhysicalStopResult::Skipped);
        assert(cgo.load() == 0);
        assert(core.liveOwner.load() == 2);
        assert(core.running.load());
    }

    {
        XrayCoreIdentity core;
        assert(XrayFinishStartedJob(core, 1, true, false).reportOk);
        const XrayStopPermit permitA = XrayAcquireStopPermit(core, 1);
        std::atomic<int> cgo{0};
        assert(XrayRunPermittedStop(core, permitA, CountingHooks(&cgo)) == XrayPhysicalStopResult::Stopped);
        assert(cgo.load() == 1);
        assert(XrayFinishStartedJob(core, 2, true, false).reportOk);
        assert(core.liveOwner.load() == 2);
        const XrayStopPermit lateA = XrayAcquireStopPermit(core, 1);
        assert(!lateA.allowPhysicalStop);
        assert(XrayRunPermittedStop(core, lateA, CountingHooks(&cgo)) == XrayPhysicalStopResult::Skipped);
        assert(cgo.load() == 1);
        assert(core.running.load());
        assert(core.liveOwner.load() == 2);
    }

    {
        const char* path = "/tmp/tongdao-notify-fail-test.inject";
        FILE* f = std::fopen(path, "w");
        assert(f != nullptr);
        std::fwrite("forever\n", 1, 8, f);
        std::fclose(f);
        const XrayNotifyInject first = XrayInspectNotifyInject(path);
        assert(first.present);
        assert(first.keepFile);
        assert(first.failRemaining == -1);
        assert(first.forceGenericFailure);
        const XrayNotifyInject second = XrayInspectNotifyInject(path);
        assert(second.present);
        assert(second.keepFile);
        FILE* still = std::fopen(path, "r");
        assert(still != nullptr);
        std::fclose(still);
        std::remove(path);
        const XrayNotifyInject gone = XrayInspectNotifyInject(path);
        assert(!gone.present);
        assert(!gone.keepFile);
    }

    {
        const std::string json =
            "{\"inbounds\":[{\"listen\":\"127.0.0.1\",\"port\":38455,\"protocol\":\"socks\"}],"
            "\"outbounds\":[{\"protocol\":\"trojan\",\"settings\":{\"servers\":[{\"port\":443}]}}]}";
        const auto ports = XrayParseInboundListenPorts(json);
        assert(ports.size() == 1);
        assert(ports[0] == 38455);
    }

    {
        struct LiveSocks {
            int listenFd = -1;
            uint16_t port = 0;
            std::atomic_bool run{true};
            std::thread th;
            void start()
            {
                listenFd = socket(AF_INET, SOCK_STREAM, 0);
                assert(listenFd >= 0);
                int yes = 1;
                setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
                sockaddr_in addr {};
                addr.sin_family = AF_INET;
                addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                addr.sin_port = 0;
                assert(bind(listenFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
                assert(listen(listenFd, 8) == 0);
                socklen_t len = sizeof(addr);
                assert(getsockname(listenFd, reinterpret_cast<sockaddr*>(&addr), &len) == 0);
                port = ntohs(addr.sin_port);
                const int flags = fcntl(listenFd, F_GETFL, 0);
                if (flags >= 0) {
                    fcntl(listenFd, F_SETFL, flags | O_NONBLOCK);
                }
                th = std::thread([this]() {
                    while (run.load()) {
                        pollfd pfd {};
                        pfd.fd = listenFd;
                        pfd.events = POLLIN;
                        if (poll(&pfd, 1, 50) <= 0) {
                            continue;
                        }
                        const int client = accept(listenFd, nullptr, nullptr);
                        if (client < 0) {
                            continue;
                        }
                        unsigned char buf[3] = {0, 0, 0};
                        recv(client, buf, sizeof(buf), 0);
                        const unsigned char reply[2] = {0x05, 0xff};
                        send(client, reply, sizeof(reply), 0);
                        close(client);
                    }
                });
            }
            void join()
            {
                run.store(false);
                if (th.joinable()) {
                    th.join();
                }
                listenFd = -1;
            }
        };

        // CGoStop/hook success with a live SOCKS greeting must not publish
        // stopped. This adapter does not close Go sockets; the real Close is
        // libxray single-start. Probe requires a 0x05 reply, not TCP connect.
        LiveSocks socks;
        socks.start();
        assert(socks.port != 0);
        assert(XrayLoopbackSocksLive(socks.port, 300));

        XrayCoreIdentity core;
        assert(XrayFinishStartedJob(core, 12, true, false).reportOk);
        XrayRememberInboundPorts(core, {socks.port});
        std::atomic<int> cgo{0};
        const XrayStopPermit permit = XrayAcquireStopPermit(core, 12);
        assert(permit.allowPhysicalStop);
        std::string detail;
        const XrayPhysicalStopResult result = XrayRunPermittedStop(core, permit, CountingHooks(&cgo), &detail);
        assert(cgo.load() == 1);
        assert(result == XrayPhysicalStopResult::Failed);
        assert(core.running.load());
        assert(detail.find("live socks") != std::string::npos);
        assert(XrayLoopbackSocksLive(socks.port, 300));
        socks.run.store(false);
        shutdown(socks.listenFd, SHUT_RDWR);
        close(socks.listenFd);
        socks.listenFd = -1;
        socks.join();
        assert(!XrayLoopbackSocksLive(socks.port, 300));
    }

    XrayClearTrackedStartJobs();
    return 0;
}
