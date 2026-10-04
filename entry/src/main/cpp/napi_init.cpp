#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include "napi/native_api.h"
#include "xray_start_notify.h"
#include "xray_start_lifecycle.h"
#include "app_flow_router.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <thread>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <dlfcn.h>
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 0x00004
#endif
#ifndef RTLD_GLOBAL
#define RTLD_GLOBAL 0x00100
#endif
#include <fcntl.h>
#include <hilog/log.h>
#include <memory>
#include <mutex>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <spawn.h>
#include <sstream>
#include <string>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
#include <arpa/inet.h>
#include <sys/mman.h>

extern char** environ;

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

namespace {

constexpr unsigned int LOG_DOMAIN_ID = 0x0001;
constexpr const char* LOG_TAG_NAME = "HeyNative";
constexpr const char* XRAY_CONFIG_FILE = "hey-xray-config.json";
constexpr const char* XRAY_CORE_LIB = "libxray.so";
constexpr const char* PING_CONFIG_FILE = "hey-ping-config.json";
constexpr const char* TEST_CONFIG_FILE = "hey-xray-test-config.json";

using CGoPingFunc = char* (*)(char*);
using CGoStringFunc = char* (*)(char*);
using CGoStopFunc = char* (*)();
using CGoVersionFunc = char* (*)();
using CGoFreePortsFunc = char* (*)(int64_t);
using CGoSetTunFdFunc = void (*)(int);
// libXray v26.7.28+ 单一分发入口：CGoInvoke(jsonRequest)->jsonResponse（原始 JSON，
// 非 base64），CGoFree 释放返回串。所有 xray 操作经此路由（method 见 invoke_model.go）。
using CGoInvokeFunc = char* (*)(char*);
using CGoFreeFunc = void (*)(char*);

struct XrayStartJob;

XrayCoreIdentity g_xrayCore;
std::atomic_bool g_xrayStarting(false);
std::mutex g_xrayJobMu;
std::shared_ptr<XrayStartJob> g_xrayStartJob;
std::atomic<pid_t> g_xrayPid(0);
std::atomic_bool g_tunRunning(false);
std::atomic_bool g_nativePoisoned(false);
std::mutex g_lifetimeMu;
std::vector<std::shared_ptr<void>> g_orphans;
std::mutex g_hevMu;
std::mutex g_atomicReplaceMu;
std::atomic<int64_t> g_uploadBytes(0);
std::atomic<int64_t> g_downloadBytes(0);
std::string g_lastMessage = "Native bridge ready. Waiting for Xray shared library.";
void* g_xrayHandle = nullptr;
CGoInvokeFunc g_cgoInvoke = nullptr;
CGoFreeFunc g_cgoFree = nullptr;
CGoSetTunFdFunc g_setTunFd = nullptr;
// libXray 20d70a98 / go1.24 路线：独立导出，无 CGoInvoke。
CGoStringFunc g_cgoRunFromJson = nullptr;
CGoStopFunc g_cgoStopLegacy = nullptr;
CGoVersionFunc g_cgoVersionLegacy = nullptr;
CGoVersionFunc g_cgoHello = nullptr;
bool g_xrayLegacyApi = false;
// Optional symbols. Resolved lazily and best-effort: an older libxray.so that
// does not export these (e.g. built before they were added to the version
// script) leaves them null and the bridge degrades gracefully.
CGoStringFunc g_queryStats = nullptr;
CGoStringFunc g_testXray = nullptr;
CGoVersionFunc g_xrayVersion = nullptr;
CGoStringFunc g_countGeoData = nullptr;
CGoStringFunc g_readGeoFiles = nullptr;
CGoFreePortsFunc g_getFreePorts = nullptr;
CGoStringFunc g_convertShareLinksToXrayJson = nullptr;
CGoStringFunc g_convertXrayJsonToShareLinks = nullptr;

// sing-box second core state. Implementation lives in the sing-box block below;
// declared here so GetStats (above that block) can read g_singboxRunning.
std::atomic_bool g_singboxRunning(false);
void* g_singboxHandle = nullptr;
CGoStringFunc g_singboxStart = nullptr;
CGoStopFunc g_singboxStop = nullptr;
CGoSetTunFdFunc g_singboxSetTunFd = nullptr;

// tun2socks 适配器（libheytun2socks.so）：把 Harmony VPN TUN fd 的流量转发到
// Xray 的本地 SOCKS 入站（fd:// -> socks5://127.0.0.1:port）。与 libxray.so 分开
// 编译/加载——各自独立的 Go 运行时 + TLSDESC，规避 xray-core 与 tun2socks 的
// gvisor 版本冲突。
using Tun2SocksStartFunc = int (*)(int, char*, int, int);
using Tun2SocksStopFunc = void (*)();
using Tun2SocksStatsFunc = int64_t (*)();
void* g_tun2socksHandle = nullptr;
Tun2SocksStartFunc g_startTun2Socks = nullptr;
Tun2SocksStopFunc g_stopTun2Socks = nullptr;
Tun2SocksStatsFunc g_tun2SocksUploadBytes = nullptr;
Tun2SocksStatsFunc g_tun2SocksDownloadBytes = nullptr;

// hev-socks5-tunnel 引擎（libhevsocks5tun.so）：「使用 Hev TUN 引擎」开关打开时的高性能
// 数据面，对照默认 gvisor 的 libheytun2socks.so。hev 是纯 C：main 阻塞（跑到 quit 才返回），
// 所以必须放到独立线程跑；stats 是 (tx_pkts, tx_bytes, rx_pkts, rx_bytes) 四个出参。
using HevStartFunc = int (*)(const unsigned char*, unsigned int, int);
using HevQuitFunc = void (*)();
using HevStatsFunc = void (*)(size_t*, size_t*, size_t*, size_t*);
using HevDiagSnapshotFunc = int (*)(char*, int);
void* g_hevHandle = nullptr;
HevStartFunc g_hevStart = nullptr;
HevQuitFunc g_hevQuit = nullptr;
HevStatsFunc g_hevStats = nullptr;
HevDiagSnapshotFunc g_hevDiagSnapshot = nullptr;
std::thread g_hevThread;
std::atomic<int> g_hevMainRc(-2);
std::atomic<uint64_t> g_hevLife(0);

// 当前 TUN 数据面引擎：0=无，1=gvisor(tun2socks)，2=hev。stop/stats 据此分发。
constexpr int TUN_ENGINE_NONE = 0;
constexpr int TUN_ENGINE_GVISOR = 1;
constexpr int TUN_ENGINE_HEV = 2;
std::atomic<int> g_tunEngine(TUN_ENGINE_NONE);

const char* BASE64_TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

void LogInfo(const std::string& message)
{
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN_ID, LOG_TAG_NAME, "%{public}s", message.c_str());
}

void LogWarn(const std::string& message)
{
    OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN_ID, LOG_TAG_NAME, "%{public}s", message.c_str());
}

void LogError(const std::string& message)
{
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN_ID, LOG_TAG_NAME, "%{public}s", message.c_str());
}

std::string ErrnoMessage(const std::string& prefix, int errorCode = errno)
{
    return prefix + ": " + std::strerror(errorCode);
}

std::string DirName(const std::string& path)
{
    size_t slash = path.find_last_of('/');
    if (slash == std::string::npos || slash == 0) {
        return ".";
    }
    return path.substr(0, slash);
}

std::string NativeLibDir()
{
    Dl_info info;
    if (dladdr(reinterpret_cast<void*>(&LogInfo), &info) != 0 && info.dli_fname != nullptr) {
        return DirName(info.dli_fname);
    }
    return ".";
}

std::string ExecPath(const std::string& name)
{
    return NativeLibDir() + "/" + name;
}

bool WriteTextFile(const std::string& path, const std::string& content, std::string& message)
{
    FILE* file = std::fopen(path.c_str(), "wb");
    if (file == nullptr) {
        message = ErrnoMessage("Failed to open file for writing: " + path);
        return false;
    }

    size_t written = std::fwrite(content.data(), 1, content.size(), file);
    std::fclose(file);
    if (written != content.size()) {
        message = ErrnoMessage("Failed to write complete file: " + path);
        return false;
    }
    return true;
}

bool MakeFdInheritable(int fd, std::string& message)
{
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) {
        message = ErrnoMessage("fcntl(F_GETFD) failed for TUN fd");
        return false;
    }
    if (fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC) < 0) {
        message = ErrnoMessage("fcntl(F_SETFD) failed for TUN fd");
        return false;
    }
    return true;
}

std::string GetStringArg(napi_env env, napi_value value)
{
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::string result(length + 1, '\0');
    napi_get_value_string_utf8(env, value, &result[0], result.size(), &length);
    result.resize(length);
    return result;
}

int32_t GetIntArg(napi_env env, napi_value value)
{
    int32_t result = 0;
    napi_get_value_int32(env, value, &result);
    return result;
}

napi_value CreateString(napi_env env, const std::string& value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.length(), &result);
    return result;
}

napi_value CreateBool(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value CreateInt64(napi_env env, int64_t value)
{
    napi_value result = nullptr;
    napi_create_int64(env, value, &result);
    return result;
}

napi_value CreateInt32(napi_env env, int32_t value)
{
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

struct ProtectWaiter {
    int fd = -1;
    std::atomic<int> holdFd{-1};
    int32_t token = 0;
    std::atomic<int> done{0};
    std::atomic<int> taken{0};
    std::atomic<int> claimed{0};
    std::atomic<int> abandoned{0};
    int rc = -1;
    std::mutex mu;
    std::condition_variable cv;
};

void ReleaseProtectHold(const std::shared_ptr<ProtectWaiter>& waiter)
{
    if (!waiter) {
        return;
    }
    const int fd = waiter->holdFd.exchange(-1);
    if (fd >= 0) {
        close(fd);
    }
}

struct ProtectCall {
    int fd = -1;
    int32_t token = 0;
    std::shared_ptr<ProtectWaiter> waiter;
};

static std::mutex g_protectMu;
static std::vector<std::shared_ptr<ProtectWaiter>> g_protectWaiters;
static std::mutex g_tsfnMu;
static napi_threadsafe_function g_protectTsfn = nullptr;
static std::atomic<int64_t> g_protectQueued{0};
static std::atomic<int64_t> g_protectAcked{0};
static std::atomic<int64_t> g_protectTimeout{0};
static std::atomic<int64_t> g_protectMeasured{0};
static std::atomic<int64_t> g_protectTotalUs{0};
static std::atomic<int64_t> g_protectMaxUs{0};
static std::atomic<int64_t> g_protectTcp4{0};
static std::atomic<int64_t> g_protectTcp6{0};
static std::atomic<int64_t> g_protectUdp{0};
static std::atomic<int64_t> g_protectTcp4At{0};
static std::atomic<int64_t> g_protectTcp6At{0};

// Measurement only; do not alter protection, cancellation or fd ownership.
class ProtectDuration {
public:
    ProtectDuration() : started_(std::chrono::steady_clock::now()) {}
    ~ProtectDuration()
    {
        const int64_t elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started_).count();
        g_protectTotalUs.fetch_add(elapsed, std::memory_order_relaxed);
        g_protectMeasured.fetch_add(1, std::memory_order_relaxed);
        int64_t maximum = g_protectMaxUs.load(std::memory_order_relaxed);
        while (elapsed > maximum && !g_protectMaxUs.compare_exchange_weak(
            maximum, elapsed, std::memory_order_relaxed)) {}
    }
private:
    std::chrono::steady_clock::time_point started_;
};
static std::atomic<int32_t> g_protectSeq{1};
static std::atomic<int> g_protectVisible{0};
static std::atomic<int> g_protectPromoteTries{0};
static constexpr int kProtectTimeoutMs = 3000;
static constexpr int kProtectClaimedGraceMs = 3000;

extern "C" __attribute__((visibility("default"))) int hey_protect_socket(int fd);

void NotifyProtectWaiter(const std::shared_ptr<ProtectWaiter>& waiter, int rc)
{
    if (!waiter) {
        return;
    }
    std::lock_guard<std::mutex> lock(waiter->mu);
    if (waiter->done.load() == 0) {
        waiter->rc = waiter->abandoned.load() != 0 ? -1 : rc;
        waiter->done.store(1);
    }
    waiter->cv.notify_one();
}

void ProtectCallJs(napi_env env, napi_value jsCb, void* context, void* data)
{
    (void)context;
    auto* call = static_cast<ProtectCall*>(data);
    if (call == nullptr) {
        return;
    }
    bool proceed = false;
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        if (call->waiter && call->waiter->abandoned.load() == 0 && call->waiter->done.load() == 0) {
            auto it = std::find(g_protectWaiters.begin(), g_protectWaiters.end(), call->waiter);
            if (it != g_protectWaiters.end()) {
                call->waiter->claimed.store(1);
                proceed = true;
            }
        }
    }
    if (!proceed) {
        delete call;
        return;
    }
    if (env == nullptr || jsCb == nullptr) {
        NotifyProtectWaiter(call->waiter, -1);
        delete call;
        return;
    }
    napi_value undefined = nullptr;
    napi_value fdVal = nullptr;
    napi_value tokenVal = nullptr;
    napi_value result = nullptr;
    napi_get_undefined(env, &undefined);
    napi_create_int32(env, call->fd, &fdVal);
    napi_create_int32(env, call->token, &tokenVal);
    napi_value argv[2] = { fdVal, tokenVal };
    const napi_status st = napi_call_function(env, undefined, jsCb, 2, argv, &result);
    if (st != napi_ok) {
        bool pending = false;
        napi_is_exception_pending(env, &pending);
        if (pending) {
            napi_value exc = nullptr;
            napi_get_and_clear_last_exception(env, &exc);
        }
        NotifyProtectWaiter(call->waiter, -1);
    }
    delete call;
}

void AbortProtectTsfnLocked()
{
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        for (auto it = g_protectWaiters.begin(); it != g_protectWaiters.end();) {
            const auto& waiter = *it;
            waiter->abandoned.store(1);
            if (waiter->claimed.load() == 0) {
                ReleaseProtectHold(waiter);
                it = g_protectWaiters.erase(it);
            } else {
                ++it;
            }
        }
    }
    if (g_protectTsfn == nullptr) {
        return;
    }
    napi_threadsafe_function tsfn = g_protectTsfn;
    g_protectTsfn = nullptr;
    napi_release_threadsafe_function(tsfn, napi_tsfn_abort);
}

void PromoteProtectSymbol()
{
    if (g_protectVisible.load() == 1) {
        return;
    }
    if (g_protectPromoteTries.fetch_add(1) > 8) {
        return;
    }
    Dl_info info;
    std::memset(&info, 0, sizeof(info));
    const void* addr = reinterpret_cast<const void*>(hey_protect_socket);
    if (dladdr(addr, &info) == 0 || info.dli_fname == nullptr) {
        LogWarn("dladdr hey_protect_socket failed");
    } else {
        void* handle = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_GLOBAL);
        LogInfo(std::string("promote ") + info.dli_fname + (handle != nullptr ? " GLOBAL ok" : " GLOBAL fail"));
    }
    void* seen = dlsym(RTLD_DEFAULT, "hey_protect_socket");
    g_protectVisible.store(seen != nullptr ? 1 : 0);
    LogInfo(std::string("RTLD_DEFAULT hey_protect_socket ") + (seen != nullptr ? "visible" : "hidden"));
}

extern "C" __attribute__((visibility("default"))) int hey_protect_socket(int fd)
{
    if (fd < 0) {
        return -1;
    }
    ProtectDuration measured;
    sockaddr_storage local{};
    socklen_t localLength = sizeof(local);
    int socketType = 0;
    socklen_t typeLength = sizeof(socketType);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&local), &localLength) == 0 &&
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &socketType, &typeLength) == 0) {
        const int64_t at = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        if (socketType == SOCK_STREAM && local.ss_family == AF_INET) {
            g_protectTcp4.fetch_add(1); g_protectTcp4At.store(at);
        }
        if (socketType == SOCK_STREAM && local.ss_family == AF_INET6) {
            g_protectTcp6.fetch_add(1); g_protectTcp6At.store(at);
        }
        if (socketType == SOCK_DGRAM) { g_protectUdp.fetch_add(1); }
    }
    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_tsfnMu);
        tsfn = g_protectTsfn;
        if (tsfn != nullptr && napi_acquire_threadsafe_function(tsfn) != napi_ok) {
            tsfn = nullptr;
        }
    }
    if (tsfn == nullptr) {
        LogWarn(std::string("protect tsfn missing fd=") + std::to_string(fd));
        return -1;
    }
    const int hold = dup(fd);
    if (hold < 0) {
        LogWarn(std::string("protect dup failed fd=") + std::to_string(fd));
        return -1;
    }
    auto waiter = std::make_shared<ProtectWaiter>();
    waiter->holdFd.store(hold);
    waiter->fd = hold;
    int32_t token = g_protectSeq.fetch_add(1);
    if (token <= 0) {
        g_protectSeq.store(1);
        token = g_protectSeq.fetch_add(1);
    }
    waiter->token = token;
    auto* call = new ProtectCall();
    call->fd = hold;
    call->token = token;
    call->waiter = waiter;
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        g_protectWaiters.push_back(waiter);
    }
    const int64_t queued = g_protectQueued.fetch_add(1) + 1;
    if (queued <= 4 || (queued % 40) == 0) {
        LogInfo(std::string("protect queued fd=") + std::to_string(fd) + " n=" + std::to_string(queued));
    }
    const napi_status callSt = napi_call_threadsafe_function(tsfn, call, napi_tsfn_nonblocking);
    napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    if (callSt != napi_ok) {
        {
            std::lock_guard<std::mutex> lock(g_protectMu);
            auto it = std::find(g_protectWaiters.begin(), g_protectWaiters.end(), waiter);
            if (it != g_protectWaiters.end()) {
                g_protectWaiters.erase(it);
            }
        }
        delete call;
        ReleaseProtectHold(waiter);
        LogWarn(std::string("protect tsfn call failed fd=") + std::to_string(fd));
        return -1;
    }
    {
        std::unique_lock<std::mutex> lock(waiter->mu);
        if (waiter->done.load() == 0) {
            waiter->cv.wait_for(lock, std::chrono::milliseconds(kProtectTimeoutMs),
                [&] { return waiter->done.load() != 0; });
        }
        if (waiter->done.load() == 0 && waiter->claimed.load() != 0) {
            waiter->cv.wait_for(lock, std::chrono::milliseconds(kProtectClaimedGraceMs),
                [&] { return waiter->done.load() != 0; });
        }
    }
    if (waiter->done.load() != 0) {
        {
            std::lock_guard<std::mutex> lock(g_protectMu);
            auto it = std::find(g_protectWaiters.begin(), g_protectWaiters.end(), waiter);
            if (it != g_protectWaiters.end()) {
                g_protectWaiters.erase(it);
            }
        }
        ReleaseProtectHold(waiter);
        g_protectAcked.fetch_add(1);
        return waiter->rc;
    }
    if (waiter->claimed.load() != 0) {
        // Claimed: keep holdFd/waiter until ACK. Returning -1 lets Go close the
        // original fd; JS protect() still owns the dup until ack/abort.
        g_protectTimeout.fetch_add(1);
        LogWarn(std::string("protect claimed timeout holding dup fd=") + std::to_string(hold) +
            " token=" + std::to_string(waiter->token));
        return -1;
    }
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        waiter->abandoned.store(1);
        auto it = std::find(g_protectWaiters.begin(), g_protectWaiters.end(), waiter);
        if (it != g_protectWaiters.end()) {
            g_protectWaiters.erase(it);
        }
    }
    ReleaseProtectHold(waiter);
    g_protectTimeout.fetch_add(1);
    LogWarn(std::string("protect timeout fd=") + std::to_string(fd) +
        " token=" + std::to_string(waiter->token));
    return -1;
}

napi_value SetProtectCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    {
        std::lock_guard<std::mutex> lock(g_tsfnMu);
        AbortProtectTsfnLocked();
    }
    if (argc < 1 || args[0] == nullptr) {
        return CreateInt32(env, 0);
    }
    napi_valuetype valueType = napi_undefined;
    napi_typeof(env, args[0], &valueType);
    if (valueType != napi_function) {
        return CreateInt32(env, -1);
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "heyProtect", NAPI_AUTO_LENGTH, &resourceName);
    napi_threadsafe_function tsfn = nullptr;
    const napi_status st = napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr, ProtectCallJs, &tsfn);
    if (st != napi_ok || tsfn == nullptr) {
        LogWarn("napi_create_threadsafe_function failed");
        return CreateInt32(env, -1);
    }
    {
        std::lock_guard<std::mutex> lock(g_tsfnMu);
        AbortProtectTsfnLocked();
        g_protectTsfn = tsfn;
    }
    LogInfo("protect TSFN ready");
    return CreateInt32(env, 1);
}

napi_value ClearProtectCallback(napi_env env, napi_callback_info info)
{
    (void)info;
    {
        std::lock_guard<std::mutex> lock(g_tsfnMu);
        AbortProtectTsfnLocked();
    }
    return CreateInt32(env, 0);
}

napi_value ClaimProtectFd(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return CreateInt32(env, 0);
    }
    int32_t fd = GetIntArg(env, args[0]);
    int32_t token = GetIntArg(env, args[1]);
    std::lock_guard<std::mutex> lock(g_protectMu);
    for (const auto& waiter : g_protectWaiters) {
        if (waiter->fd == fd && waiter->token == token && waiter->done.load() == 0 &&
            waiter->abandoned.load() == 0) {
            waiter->claimed.store(1);
            return CreateInt32(env, 1);
        }
    }
    return CreateInt32(env, 0);
}

napi_value TakeProtectFd(napi_env env, napi_callback_info info)
{
    (void)info;
    int fd = -1;
    std::lock_guard<std::mutex> lock(g_protectMu);
    for (const auto& waiter : g_protectWaiters) {
        if (waiter->done.load() == 0 && waiter->taken.exchange(1) == 0) {
            fd = waiter->fd;
            break;
        }
    }
    return CreateInt32(env, fd);
}

napi_value AckProtectFd(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return CreateInt32(env, -1);
    }
    int32_t fd = GetIntArg(env, args[0]);
    int32_t rc = GetIntArg(env, args[1]);
    int32_t token = GetIntArg(env, args[2]);
    std::shared_ptr<ProtectWaiter> found;
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        for (auto it = g_protectWaiters.begin(); it != g_protectWaiters.end();) {
            const auto& waiter = *it;
            if (waiter->fd == fd && waiter->token == token && waiter->done.load() == 0) {
                found = waiter;
                it = g_protectWaiters.erase(it);
            } else {
                ++it;
            }
        }
    }
    if (found) {
        NotifyProtectWaiter(found, rc);
        ReleaseProtectHold(found);
        return CreateInt32(env, 0);
    }
    return CreateInt32(env, -1);
}

bool ReadUrandom(unsigned char* buf, size_t n)
{
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return false;
    }
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r <= 0) {
            close(fd);
            return false;
        }
        got += static_cast<size_t>(r);
    }
    close(fd);
    return true;
}

std::string ToHex(const unsigned char* buf, size_t n)
{
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.resize(n * 2);
    for (size_t i = 0; i < n; ++i) {
        out[i * 2] = kHex[(buf[i] >> 4) & 0x0f];
        out[i * 2 + 1] = kHex[buf[i] & 0x0f];
    }
    return out;
}

int BindLoopbackPort()
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    socklen_t len = sizeof(addr);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
        close(fd);
        return -1;
    }
    int port = ntohs(addr.sin_port);
    close(fd);
    return port;
}

napi_value CreateSocksSession(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    napi_create_object(env, &result);
    int port = -1;
    for (int i = 0; i < 5 && port <= 0; ++i) {
        port = BindLoopbackPort();
    }
    unsigned char userBuf[4];
    unsigned char passBuf[8];
    if (port <= 0 || !ReadUrandom(userBuf, sizeof(userBuf)) || !ReadUrandom(passBuf, sizeof(passBuf))) {
        napi_set_named_property(env, result, "ok", CreateBool(env, false));
        napi_set_named_property(env, result, "message", CreateString(env, "urandom/bind(0) failed"));
        napi_set_named_property(env, result, "port", CreateInt32(env, 0));
        napi_set_named_property(env, result, "user", CreateString(env, ""));
        napi_set_named_property(env, result, "pass", CreateString(env, ""));
        return result;
    }
    napi_set_named_property(env, result, "ok", CreateBool(env, true));
    napi_set_named_property(env, result, "message", CreateString(env, "socks session reserved"));
    napi_set_named_property(env, result, "port", CreateInt32(env, port));
    napi_set_named_property(env, result, "user", CreateString(env, ToHex(userBuf, sizeof(userBuf))));
    napi_set_named_property(env, result, "pass", CreateString(env, ToHex(passBuf, sizeof(passBuf))));
    return result;
}

void MarkPoisoned(const std::string& why)
{
    g_nativePoisoned.store(true);
    g_lastMessage = why;
    LogError(std::string("POISONED ") + why);
}

napi_value CreateResult(napi_env env, bool ok, const std::string& message, int64_t ownerSeq = 0)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "ok", CreateBool(env, ok));
    napi_set_named_property(env, result, "message", CreateString(env, message));
    napi_set_named_property(env, result, "poisoned", CreateBool(env, g_nativePoisoned.load()));
    napi_set_named_property(env, result, "ownerSeq", CreateInt64(env, ownerSeq));
    g_lastMessage = message;
    if (ok) {
        LogInfo(message);
    } else {
        LogError(message);
    }
    return result;
}

// Like CreateResult but does not mutate g_lastMessage or log. Used by the
// auxiliary query functions (stats/test/version) so they never clobber the
// connection runtime state that getStats() reports.
napi_value CreateResultQuiet(napi_env env, bool ok, const std::string& message)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "ok", CreateBool(env, ok));
    napi_set_named_property(env, result, "message", CreateString(env, message));
    napi_set_named_property(env, result, "poisoned", CreateBool(env, g_nativePoisoned.load()));
    return result;
}

std::string Base64Encode(const std::string& input)
{
    std::string output;
    int value = 0;
    int bits = -6;
    for (uint8_t ch : input) {
        value = (value << 8) + ch;
        bits += 8;
        while (bits >= 0) {
            output.push_back(BASE64_TABLE[(value >> bits) & 0x3F]);
            bits -= 6;
        }
    }
    if (bits > -6) {
        output.push_back(BASE64_TABLE[((value << 8) >> (bits + 8)) & 0x3F]);
    }
    while (output.size() % 4 != 0) {
        output.push_back('=');
    }
    return output;
}

std::string Base64Decode(const std::string& input)
{
    std::string output;
    std::vector<int> values(256, -1);
    for (int index = 0; index < 64; index++) {
        values[static_cast<uint8_t>(BASE64_TABLE[index])] = index;
    }

    int value = 0;
    int bits = -8;
    for (char ch : input) {
        if (ch == '=') {
            break;
        }
        int decoded = values[static_cast<uint8_t>(ch)];
        if (decoded < 0) {
            continue;
        }
        value = (value << 6) + decoded;
        bits += 6;
        if (bits >= 0) {
            output.push_back(static_cast<char>((value >> bits) & 0xFF));
            bits -= 8;
        }
    }
    return output;
}

std::string JsonEscape(const std::string& input)
{
    std::ostringstream output;
    for (char ch : input) {
        switch (ch) {
            case '\\':
                output << "\\\\";
                break;
            case '"':
                output << "\\\"";
                break;
            case '\n':
                output << "\\n";
                break;
            case '\r':
                output << "\\r";
                break;
            case '\t':
                output << "\\t";
                break;
            default:
                output << ch;
                break;
        }
    }
    return output.str();
}

// Decodes a libXray CGo return value (base64 of a CallResponse JSON
// {"success":bool,"data":...,"err":string}) and reports it back to ArkTS as
// {ok, message} where message is the decoded CallResponse JSON. Callers on the
// ArkTS side JSON.parse the message to read `data`/`err`. Frees the raw pointer
// returned by the Go c-shared library.
napi_value BuildCallResult(napi_env env, char* raw, const std::string& nullMessage)
{
    if (raw == nullptr) {
        return CreateResultQuiet(env, false, nullMessage);
    }
    std::string response(raw);
    std::free(raw);

    std::string decoded = Base64Decode(response);
    if (decoded.find('{') == std::string::npos) {
        decoded = response;
    }
    bool ok = decoded.find("\"success\":true") != std::string::npos;
    return CreateResultQuiet(env, ok, decoded);
}

bool ResponseOk(const std::string& base64Response, std::string& message)
{
    std::string decoded = Base64Decode(base64Response);
    if (decoded.empty()) {
        message = "Empty libXray response.";
        return false;
    }
    if (decoded.find("\"success\":true") != std::string::npos) {
        message = "libXray response: " + decoded;
        return true;
    }

    size_t errorKey = decoded.find("\"error\":\"");
    if (errorKey != std::string::npos) {
        size_t start = errorKey + 9;
        size_t end = decoded.find('"', start);
        message = decoded.substr(start, end == std::string::npos ? std::string::npos : end - start);
    } else {
        message = decoded;
    }
    return false;
}

bool LoadXrayCore(std::string& message);

bool LoadXray()
{
    std::string message;
    bool ok = LoadXrayCore(message);
    if (!ok) {
        g_lastMessage = message;
        LogError(message);
    }
    return ok;
}

bool LoadXrayCore(std::string& message)
{
    if (g_xrayHandle != nullptr &&
        ((g_cgoInvoke != nullptr && g_cgoFree != nullptr) ||
            (g_xrayLegacyApi && g_cgoRunFromJson != nullptr && g_cgoStopLegacy != nullptr))) {
        return true;
    }

    PromoteProtectSymbol();
    const std::string path = ExecPath(XRAY_CORE_LIB);
    LogInfo(std::string("dlopen start ") + path);
    void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        const char* firstError = dlerror();
        LogWarn(std::string("dlopen RTLD_NOW failed: ") +
            (firstError != nullptr ? firstError : "unknown"));
        handle = dlopen(XRAY_CORE_LIB, RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        const char* error = dlerror();
        message = std::string("libXray unavailable: failed to load ") + XRAY_CORE_LIB + ": " +
            (error != nullptr ? error : "unknown error");
        LogError(message);
        return false;
    }
    LogInfo("dlopen ok");

    dlerror();
    // libXray v26.7.28+：所有方法经单一 CGoInvoke 分发，CGoFree 释放返回串。
    g_cgoInvoke = reinterpret_cast<CGoInvokeFunc>(dlsym(handle, "CGoInvoke"));
    g_cgoFree = reinterpret_cast<CGoFreeFunc>(dlsym(handle, "CGoFree"));
    // CGoSetTunFd 为可选：tun2socks（SOCKS 入站）数据面不需要它，SOCKS 版
    // libxray.so 也不导出它。
    g_setTunFd = reinterpret_cast<CGoSetTunFdFunc>(dlsym(handle, "CGoSetTunFd"));
    if (g_cgoInvoke != nullptr && g_cgoFree != nullptr) {
        g_xrayLegacyApi = false;
        g_xrayHandle = handle;
        return true;
    }
    g_cgoRunFromJson = reinterpret_cast<CGoStringFunc>(dlsym(handle, "CGoRunXrayFromJSON"));
    g_cgoStopLegacy = reinterpret_cast<CGoStopFunc>(dlsym(handle, "CGoStopXray"));
    g_cgoVersionLegacy = reinterpret_cast<CGoVersionFunc>(dlsym(handle, "CGoXrayVersion"));
    g_cgoHello = reinterpret_cast<CGoVersionFunc>(dlsym(handle, "CGoHello"));
    if (g_cgoRunFromJson != nullptr && g_cgoStopLegacy != nullptr) {
        g_xrayLegacyApi = true;
        g_xrayHandle = handle;
        LogInfo("libXray legacy CGoRunXrayFromJSON API");
        if (g_cgoHello != nullptr) {
            char* helloRaw = g_cgoHello();
            if (helloRaw != nullptr) {
                LogInfo(std::string("libXray warmup CGoHello=") + helloRaw);
                std::free(helloRaw);
            }
        }
        return true;
    }
    message = "libXray unavailable: neither CGoInvoke nor CGoRunXrayFromJSON.";
    return false;
}

// 懒加载 libheytun2socks.so 并解析 HeyTun2Socks* 符号。独立 handle、独立 Go 运行时。
constexpr const char* TUN2SOCKS_LIB = "libheytun2socks.so";

bool LoadTun2SocksCore(std::string& message)
{
    if (g_tun2socksHandle != nullptr && g_startTun2Socks != nullptr && g_stopTun2Socks != nullptr) {
        return true;
    }
    void* handle = dlopen(ExecPath(TUN2SOCKS_LIB).c_str(), RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
        handle = dlopen(TUN2SOCKS_LIB, RTLD_LAZY | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        const char* error = dlerror();
        message = std::string("tun2socks unavailable: failed to load ") + TUN2SOCKS_LIB + ": " +
            (error != nullptr ? error : "unknown error");
        return false;
    }
    dlerror();
    g_startTun2Socks = reinterpret_cast<Tun2SocksStartFunc>(dlsym(handle, "HeyTun2SocksStart"));
    g_stopTun2Socks = reinterpret_cast<Tun2SocksStopFunc>(dlsym(handle, "HeyTun2SocksStop"));
    g_tun2SocksUploadBytes = reinterpret_cast<Tun2SocksStatsFunc>(dlsym(handle, "HeyTun2SocksUploadBytes"));
    g_tun2SocksDownloadBytes = reinterpret_cast<Tun2SocksStatsFunc>(dlsym(handle, "HeyTun2SocksDownloadBytes"));
    if (g_startTun2Socks == nullptr || g_stopTun2Socks == nullptr) {
        message = "tun2socks unavailable: required HeyTun2Socks symbols missing.";
        return false;
    }
    g_tun2socksHandle = handle;
    return true;
}

// 懒加载 libhevsocks5tun.so 并解析 hev_socks5_tunnel_* 符号。独立 handle。
constexpr const char* HEV_TUN_LIB = "libhevsocks5tun.so";

bool LoadHevCore(std::string& message)
{
    if (g_hevHandle != nullptr && g_hevStart != nullptr && g_hevQuit != nullptr) {
        return true;
    }
    void* handle = dlopen(ExecPath(HEV_TUN_LIB).c_str(), RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
        handle = dlopen(HEV_TUN_LIB, RTLD_LAZY | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        const char* error = dlerror();
        message = std::string("hev tun unavailable: failed to load ") + HEV_TUN_LIB + ": " +
            (error != nullptr ? error : "unknown error");
        return false;
    }
    dlerror();
    g_hevStart = reinterpret_cast<HevStartFunc>(dlsym(handle, "hev_socks5_tunnel_main_from_str"));
    g_hevQuit = reinterpret_cast<HevQuitFunc>(dlsym(handle, "hev_socks5_tunnel_quit"));
    g_hevStats = reinterpret_cast<HevStatsFunc>(dlsym(handle, "hev_socks5_tunnel_stats"));
    // Optional, count-only diagnostic ABI; the unmodified release core has none.
    g_hevDiagSnapshot = reinterpret_cast<HevDiagSnapshotFunc>(dlsym(handle, "hev_socks5_tunnel_diag_snapshot"));
    if (g_hevStart == nullptr || g_hevQuit == nullptr) {
        message = "hev tun unavailable: required hev_socks5_tunnel symbols missing.";
        return false;
    }
    g_hevHandle = handle;
    return true;
}

// 经 libXray 单一分发入口调用一个方法。请求 {apiVersion,method,payload}，
// 返回体（原始 JSON，非 base64）写入 outResponse；失败时置 err 返回 false。
// 返回串由 CGoFree 释放（新库自带的 allocator，勿用 std::free）。
bool InvokeXray(const std::string& method, const std::string& payloadJson,
                std::string& outResponse, std::string& err)
{
    if (!LoadXrayCore(err)) {
        return false;
    }
    std::string request = "{\"apiVersion\":1,\"method\":\"" + method + "\",\"payload\":" +
        (payloadJson.empty() ? std::string("{}") : payloadJson) + "}";
    std::vector<char> buffer(request.begin(), request.end());
    buffer.push_back('\0');
    char* raw = g_cgoInvoke(buffer.data());
    if (raw == nullptr) {
        err = "libXray CGoInvoke(" + method + ") returned null.";
        return false;
    }
    outResponse.assign(raw);
    g_cgoFree(raw);
    return true;
}

// 解析响应信封 {"success":bool,"data":...,"error":"..."}。成功返回 true；
// 否则从 "error" 取消息（naive 定位，与本文件既有解析风格一致）。
bool InvokeSuccess(const std::string& response, std::string& err)
{
    if (response.find("\"success\":true") != std::string::npos) {
        return true;
    }
    size_t key = response.find("\"error\":\"");
    if (key != std::string::npos) {
        size_t start = key + 9;
        size_t end = response.find('"', start);
        err = response.substr(start, end == std::string::npos ? std::string::npos : end - start);
    }
    if (err.empty()) {
        err = "libXray call failed.";
    }
    return false;
}

// 从 ping 响应体里取 data.delay（毫秒）。找 "delay": 后的整数；无则返回 -1。
int64_t ExtractDelay(const std::string& response)
{
    size_t key = response.find("\"delay\":");
    if (key == std::string::npos) {
        return -1;
    }
    size_t start = key + 8;
    while (start < response.size() && response[start] == ' ') {
        start++;
    }
    size_t end = start;
    while (end < response.size() &&
           (std::isdigit(static_cast<unsigned char>(response[end])) != 0 || response[end] == '-')) {
        end++;
    }
    if (end <= start) {
        return -1;
    }
    return std::strtoll(response.substr(start, end - start).c_str(), nullptr, 10);
}

// Best-effort resolution of an optional symbol from the already-loaded core.
// Returns nullptr (without failing the core) when the symbol is not exported.
void* LoadOptionalSymbol(const char* name)
{
    std::string message;
    if (!LoadXrayCore(message) || g_xrayHandle == nullptr) {
        return nullptr;
    }
    dlerror();
    return dlsym(g_xrayHandle, name);
}

CGoStringFunc LoadQueryStats()
{
    if (g_queryStats == nullptr) {
        g_queryStats = reinterpret_cast<CGoStringFunc>(LoadOptionalSymbol("CGoQueryStats"));
    }
    return g_queryStats;
}

CGoStringFunc LoadTestXray()
{
    if (g_testXray == nullptr) {
        g_testXray = reinterpret_cast<CGoStringFunc>(LoadOptionalSymbol("CGoTestXray"));
    }
    return g_testXray;
}

CGoVersionFunc LoadXrayVersion()
{
    if (g_xrayVersion == nullptr) {
        g_xrayVersion = reinterpret_cast<CGoVersionFunc>(LoadOptionalSymbol("CGoXrayVersion"));
    }
    return g_xrayVersion;
}

CGoStringFunc LoadCountGeoData()
{
    if (g_countGeoData == nullptr) {
        g_countGeoData = reinterpret_cast<CGoStringFunc>(LoadOptionalSymbol("CGoCountGeoData"));
    }
    return g_countGeoData;
}

CGoStringFunc LoadReadGeoFiles()
{
    if (g_readGeoFiles == nullptr) {
        g_readGeoFiles = reinterpret_cast<CGoStringFunc>(LoadOptionalSymbol("CGoReadGeoFiles"));
    }
    return g_readGeoFiles;
}

CGoFreePortsFunc LoadGetFreePorts()
{
    if (g_getFreePorts == nullptr) {
        g_getFreePorts = reinterpret_cast<CGoFreePortsFunc>(LoadOptionalSymbol("CGoGetFreePorts"));
    }
    return g_getFreePorts;
}

CGoStringFunc LoadConvertShareLinksToXrayJson()
{
    if (g_convertShareLinksToXrayJson == nullptr) {
        g_convertShareLinksToXrayJson =
            reinterpret_cast<CGoStringFunc>(LoadOptionalSymbol("CGoConvertShareLinksToXrayJson"));
    }
    return g_convertShareLinksToXrayJson;
}

CGoStringFunc LoadConvertXrayJsonToShareLinks()
{
    if (g_convertXrayJsonToShareLinks == nullptr) {
        g_convertXrayJsonToShareLinks =
            reinterpret_cast<CGoStringFunc>(LoadOptionalSymbol("CGOConvertXrayJsonToShareLinks"));
    }
    return g_convertXrayJsonToShareLinks;
}

napi_value CreatePingResult(napi_env env, bool ok, int64_t delayMs, const std::string& message)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "ok", CreateBool(env, ok));
    napi_set_named_property(env, result, "delayMs", CreateInt64(env, delayMs));
    napi_set_named_property(env, result, "message", CreateString(env, message));
    if (ok) {
        LogInfo(message);
    } else {
        LogWarn(message);
    }
    return result;
}

napi_value PingOutbound(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        return CreatePingResult(env, false, -1, "Missing ping arguments.");
    }

    std::string config = GetStringArg(env, args[0]);
    std::string datDir = GetStringArg(env, args[1]);
    std::string url = GetStringArg(env, args[2]);
    int32_t timeoutSeconds = GetIntArg(env, args[3]);
    std::string proxy = argc >= 5 ? GetStringArg(env, args[4]) : "socks5://127.0.0.1:18085";

    if (config.empty()) {
        return CreatePingResult(env, false, -1, "Ping config JSON is empty.");
    }
    if (datDir.empty()) {
        return CreatePingResult(env, false, -1, "Ping requires a data directory.");
    }
    if (url.empty()) {
        return CreatePingResult(env, false, -1, "Ping requires a test URL.");
    }
    if (timeoutSeconds <= 0) {
        timeoutSeconds = 10;
    }

    std::string message;

    // 并发测速时每个 ping 用独立的 socks 端口，按端口区分配置文件名，避免多个并发
    // ping 同时写同一个文件互相覆盖（旧实现固定 PING_CONFIG_FILE 会造成串行/串读）。
    std::string portDigits;
    size_t colonPos = proxy.find_last_of(':');
    if (colonPos != std::string::npos) {
        for (size_t i = colonPos + 1; i < proxy.size(); ++i) {
            char c = proxy[i];
            if (c >= '0' && c <= '9') {
                portDigits.push_back(c);
            }
        }
    }
    std::string configFile = portDigits.empty() ? std::string(PING_CONFIG_FILE) : ("hey-ping-" + portDigits + ".json");
    std::string configPath = datDir + "/" + configFile;
    if (!WriteTextFile(configPath, config, message)) {
        return CreatePingResult(env, false, -1, message);
    }

    // 新版 libXray 的 ping 不再从请求取 datDir，故在此设置 geo 资源目录，
    // 保证 geoip/geosite 解析与旧行为一致。
    setenv("XRAY_LOCATION_ASSET", datDir.c_str(), 1);

    std::ostringstream payload;
    payload << "{\"configPath\":\"" << JsonEscape(configPath) << "\","
            << "\"timeout\":" << timeoutSeconds << ","
            << "\"url\":\"" << JsonEscape(url) << "\","
            << "\"proxy\":\"" << JsonEscape(proxy) << "\"}";

    std::string response;
    if (!InvokeXray("ping", payload.str(), response, message)) {
        return CreatePingResult(env, false, -1, message);
    }
    std::string err;
    if (!InvokeSuccess(response, err)) {
        return CreatePingResult(env, false, -1, err);
    }
    // data.delay：成功为真实毫秒；失败/超时为哨兵 PingDelayError(10000)/PingDelayTimeout(11000)。
    int64_t delay = ExtractDelay(response);
    if (delay < 0 || delay >= 10000) {
        return CreatePingResult(env, false, -1, "libXray ping returned no valid delay.");
    }
    return CreatePingResult(env, true, delay, "libXray ping ok.");
}

// Queries the running Xray metrics endpoint. `server` is the expvar URL, e.g.
// "http://127.0.0.1:18086/debug/vars". libXray's CGoQueryStats simply HTTP GETs
// it and wraps the body in a CallResponse; the body (Go expvar JSON containing
// the per-tag stats) is returned to ArkTS as the result message for parsing.
napi_value QueryStats(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResultQuiet(env, false, "Missing stats server.");
    }

    std::string server = GetStringArg(env, args[0]);
    if (server.empty()) {
        return CreateResultQuiet(env, false, "Stats server is empty.");
    }

    CGoStringFunc query = LoadQueryStats();
    if (query == nullptr) {
        return CreateResultQuiet(env, false, "Stats unavailable: CGoQueryStats not exported by libXray.");
    }

    std::string encoded = Base64Encode(server);
    std::vector<char> buffer(encoded.begin(), encoded.end());
    buffer.push_back('\0');

    char* raw = query(buffer.data());
    return BuildCallResult(env, raw, "CGoQueryStats returned null.");
}

// Pre-connect config validation. Writes the generated config to a file and asks
// libXray to instantiate (but not start) the core, surfacing config errors
// before the VPN tunnel is created. Degrades to success when CGoTestXray is not
// exported so it never blocks startup on an older core build.
napi_value TestXrayConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return CreateResultQuiet(env, false, "Missing test arguments.");
    }

    std::string config = GetStringArg(env, args[0]);
    std::string workDir = GetStringArg(env, args[1]);
    if (config.empty()) {
        return CreateResultQuiet(env, false, "Test config JSON is empty.");
    }
    if (workDir.empty()) {
        return CreateResultQuiet(env, false, "Test requires a work directory.");
    }
    if (config.find("\"inbounds\"") == std::string::npos || config.find("\"outbounds\"") == std::string::npos) {
        return CreateResultQuiet(env, false, "Generated Xray config must contain inbounds and outbounds.");
    }

    CGoStringFunc test = LoadTestXray();
    if (test == nullptr) {
        return CreateResultQuiet(env, false, "Preflight skipped: CGoTestXray not exported by libXray.");
    }

    std::string message;
    std::string configPath = workDir + "/" + TEST_CONFIG_FILE;
    if (!WriteTextFile(configPath, config, message)) {
        return CreateResultQuiet(env, false, message);
    }

    std::ostringstream request;
    request << "{\"datDir\":\"" << JsonEscape(workDir) << "\","
            << "\"configPath\":\"" << JsonEscape(configPath) << "\"}";
    std::string encoded = Base64Encode(request.str());
    std::vector<char> buffer(encoded.begin(), encoded.end());
    buffer.push_back('\0');

    char* raw = test(buffer.data());
    return BuildCallResult(env, raw, "CGoTestXray returned null.");
}

// Returns the bundled Xray core version (CallResponse with the version string in
// `data`). Degrades to ok=false when CGoXrayVersion is not exported.
napi_value XrayVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    CGoVersionFunc version = LoadXrayVersion();
    if (version == nullptr) {
        return CreateResultQuiet(env, false, "Xray version unavailable: CGoXrayVersion not exported by libXray.");
    }
    char* raw = version();
    return BuildCallResult(env, raw, "CGoXrayVersion returned null.");
}

// Counts a geosite/geoip .dat file and lets libXray write the sidecar
// {name}.json into datDir. Request shape matches libXray CountGeoDataRequest:
// {"datDir": "...", "name": "geosite|geoip", "geoType": "domain|ip"}.
napi_value CountGeoData(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return CreateResultQuiet(env, false, "Missing geo count arguments.");
    }

    std::string datDir = GetStringArg(env, args[0]);
    std::string name = GetStringArg(env, args[1]);
    std::string geoType = GetStringArg(env, args[2]);
    if (datDir.empty()) {
        return CreateResultQuiet(env, false, "Geo data directory is empty.");
    }
    if (name.empty()) {
        return CreateResultQuiet(env, false, "Geo data file name is empty.");
    }
    if (geoType != "domain" && geoType != "ip") {
        return CreateResultQuiet(env, false, "Geo data type must be domain or ip.");
    }

    CGoStringFunc count = LoadCountGeoData();
    if (count == nullptr) {
        return CreateResultQuiet(env, false, "Geo count unavailable: CGoCountGeoData not exported by libXray.");
    }

    std::ostringstream request;
    request << "{\"datDir\":\"" << JsonEscape(datDir) << "\","
            << "\"name\":\"" << JsonEscape(name) << "\","
            << "\"geoType\":\"" << JsonEscape(geoType) << "\"}";
    std::string encoded = Base64Encode(request.str());
    std::vector<char> buffer(encoded.begin(), encoded.end());
    buffer.push_back('\0');

    char* raw = count(buffer.data());
    return BuildCallResult(env, raw, "CGoCountGeoData returned null.");
}

// Reads geo resource references from an Xray config JSON. libXray returns a
// CallResponse whose data is {domain:["geosite.dat"], ip:["geoip.dat"]}.
napi_value ReadGeoFiles(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResultQuiet(env, false, "Missing Xray config JSON.");
    }

    std::string config = GetStringArg(env, args[0]);
    if (config.empty()) {
        return CreateResultQuiet(env, false, "Xray config JSON is empty.");
    }

    CGoStringFunc read = LoadReadGeoFiles();
    if (read == nullptr) {
        return CreateResultQuiet(env, false, "Geo file reader unavailable: CGoReadGeoFiles not exported by libXray.");
    }

    std::string encoded = Base64Encode(config);
    std::vector<char> buffer(encoded.begin(), encoded.end());
    buffer.push_back('\0');

    char* raw = read(buffer.data());
    return BuildCallResult(env, raw, "CGoReadGeoFiles returned null.");
}

// Requests free localhost TCP ports from libXray/nodep. The result message is a
// CallResponse whose data is {ports:[...]}.
napi_value GetFreePorts(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResultQuiet(env, false, "Missing free-port count.");
    }

    int32_t count = GetIntArg(env, args[0]);
    if (count <= 0) {
        return CreateResultQuiet(env, false, "Free-port count must be positive.");
    }
    if (count > 16) {
        count = 16;
    }

    CGoFreePortsFunc getFreePorts = LoadGetFreePorts();
    if (getFreePorts == nullptr) {
        return CreateResultQuiet(env, false, "Free ports unavailable: CGoGetFreePorts not exported by libXray.");
    }

    char* raw = getFreePorts(static_cast<int64_t>(count));
    return BuildCallResult(env, raw, "CGoGetFreePorts returned null.");
}

// Converts v2rayN plain/base64 share text, Xray JSON, or Clash.Meta YAML to a
// full Xray JSON config through libXray. ArkTS extracts the returned outbounds
// and stores them as manual nodes.
napi_value ConvertShareLinksToXrayJson(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResultQuiet(env, false, "Missing share text.");
    }

    std::string text = GetStringArg(env, args[0]);
    if (text.empty()) {
        return CreateResultQuiet(env, false, "Share text is empty.");
    }

    CGoStringFunc convert = LoadConvertShareLinksToXrayJson();
    if (convert == nullptr) {
        return CreateResultQuiet(
            env, false, "Share conversion unavailable: CGoConvertShareLinksToXrayJson not exported by libXray.");
    }

    std::string encoded = Base64Encode(text);
    std::vector<char> buffer(encoded.begin(), encoded.end());
    buffer.push_back('\0');

    char* raw = convert(buffer.data());
    return BuildCallResult(env, raw, "CGoConvertShareLinksToXrayJson returned null.");
}

// Converts a full Xray JSON config to share links through libXray. Kept as a
// best-effort bridge for export/share fallbacks; unsupported outbound protocols
// are skipped by libXray.
napi_value ConvertXrayJsonToShareLinks(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResultQuiet(env, false, "Missing Xray config JSON.");
    }

    std::string config = GetStringArg(env, args[0]);
    if (config.empty()) {
        return CreateResultQuiet(env, false, "Xray config JSON is empty.");
    }

    CGoStringFunc convert = LoadConvertXrayJsonToShareLinks();
    if (convert == nullptr) {
        return CreateResultQuiet(
            env, false, "Share export unavailable: CGOConvertXrayJsonToShareLinks not exported by libXray.");
    }

    std::string encoded = Base64Encode(config);
    std::vector<char> buffer(encoded.begin(), encoded.end());
    buffer.push_back('\0');

    char* raw = convert(buffer.data());
    return BuildCallResult(env, raw, "CGOConvertXrayJsonToShareLinks returned null.");
}

napi_value ValidateConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResult(env, false, "Missing Xray config JSON.");
    }

    std::string config = GetStringArg(env, args[0]);
    if (config.empty()) {
        return CreateResult(env, false, "Xray config JSON is empty.");
    }
    if (config.find("\"inbounds\"") == std::string::npos || config.find("\"outbounds\"") == std::string::npos) {
        return CreateResult(env, false, "Generated Xray config must contain inbounds and outbounds.");
    }
    if (LoadXray()) {
        return CreateResult(env, true, "Native config preflight passed. libXray is available.");
    }
    return CreateResult(env, false, g_lastMessage);
}

napi_value SetTunFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResult(env, false, "Missing TUN fd.");
    }

    int32_t tunFd = GetIntArg(env, args[0]);
    if (tunFd < 0) {
        return CreateResult(env, false, "Invalid TUN fd.");
    }
    if (g_xrayCore.running.load()) {
        return CreateResult(env, false, "Cannot set TUN fd while Xray is running.");
    }

    std::string message;
    if (!LoadXrayCore(message)) {
        g_tunRunning.store(false);
        return CreateResult(env, false, message);
    }
    if (!MakeFdInheritable(tunFd, message)) {
        g_tunRunning.store(false);
        return CreateResult(env, false, message);
    }

    g_uploadBytes.store(0);
    g_downloadBytes.store(0);
    g_setTunFd(tunFd);
    g_tunRunning.store(true);
    return CreateResult(env, true, "Xray TUN fd configured.");
}

// Go c-shared 首次进入必须避开 ArkTS/VPN 扩展线程：那些线程的 musl TLS 槽可能
// 不是干净的，CGoInvoke 会 SIGSEGV。独立 pthread + 大栈让 Go runtime 自己 needm。
constexpr size_t GO_WORKER_STACK = 8 * 1024 * 1024;
constexpr int NATIVE_STOP_TIMEOUT_MS = 4000;
constexpr int NATIVE_START_TIMEOUT_MS = 15000;

bool RunOnGoWorker(void* (*fn)(void*), void* arg, std::string& err)
{
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, GO_WORKER_STACK);
    pthread_t tid;
    int rc = pthread_create(&tid, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        err = std::string("pthread_create failed: ") + std::strerror(rc);
        return false;
    }
    pthread_join(tid, nullptr);
    return true;
}

void KeepOrphan(const std::shared_ptr<void>& item)
{
    std::lock_guard<std::mutex> lock(g_lifetimeMu);
    g_orphans.push_back(item);
}

// Never unlink a tmp that another filesDir writer (UI / VPN Ability) still
// owns. Writer A fsyncs tmpA then B rename+cleanup must not delete tmpA,
// or A's later rename returns ENOENT and status/events freeze.
constexpr int TMP_GRACE_SEC = 60;
constexpr size_t TMP_UNLINK_MAX = 32;

void CleanupDestTmp(const std::string& dest)
{
    const auto slash = dest.rfind('/');
    const std::string dir = slash == std::string::npos ? std::string(".") : dest.substr(0, slash);
    const std::string base = slash == std::string::npos ? dest : dest.substr(slash + 1);
    DIR* d = opendir(dir.c_str());
    if (d == nullptr) {
        return;
    }
    const time_t now = time(nullptr);
    std::vector<std::pair<time_t, std::string>> stale;
    while (dirent* ent = readdir(d)) {
        const std::string name = ent->d_name;
        if (name.rfind(base + ".", 0) != 0) {
            continue;
        }
        if (name.size() < 4 || name.compare(name.size() - 4, 4, ".tmp") != 0) {
            continue;
        }
        const std::string full = dir + "/" + name;
        struct stat st {};
        if (stat(full.c_str(), &st) != 0) {
            continue;
        }
        if (now < st.st_mtime + TMP_GRACE_SEC) {
            continue;
        }
        stale.push_back({st.st_mtime, full});
    }
    closedir(d);
    std::sort(stale.begin(), stale.end());
    const size_t n = stale.size() < TMP_UNLINK_MAX ? stale.size() : TMP_UNLINK_MAX;
    for (size_t i = 0; i < n; ++i) {
        unlink(stale[i].second.c_str());
    }
}

int LockDestExclusive(const std::string& dest)
{
    const std::string lockPath = dest + ".lock";
    const int fd = open(lockPath.c_str(), O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        return -1;
    }
    if (flock(fd, LOCK_EX) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

void UnlockDest(int fd)
{
    if (fd < 0) {
        return;
    }
    flock(fd, LOCK_UN);
    close(fd);
}

napi_value AtomicReplaceFile(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return CreateResult(env, false, "atomicReplace missing paths");
    }
    const std::string tmp = GetStringArg(env, args[0]);
    const std::string dest = GetStringArg(env, args[1]);
    if (tmp.empty() || dest.empty()) {
        return CreateResult(env, false, "atomicReplace empty path");
    }
    std::lock_guard<std::mutex> local(g_atomicReplaceMu);
    const int lockFd = LockDestExclusive(dest);
    if (lockFd < 0) {
        return CreateResult(env, false, "atomicReplace flock failed");
    }
    if (rename(tmp.c_str(), dest.c_str()) != 0) {
        const int saved = errno;
        UnlockDest(lockFd);
        return CreateResult(env, false, std::string("posix rename failed: ") + std::strerror(saved));
    }
    const auto slash = dest.rfind('/');
    const std::string dir = slash == std::string::npos ? std::string(".") : dest.substr(0, slash);
    int dfd = open(dir.c_str(), O_RDONLY | O_DIRECTORY);
    if (dfd >= 0) {
        fsync(dfd);
        close(dfd);
    }
    CleanupDestTmp(dest);
    UnlockDest(lockFd);
    return CreateResult(env, true, "atomicReplace ok");
}

napi_value AbortPoisonedNative(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    LogError("abort poisoned ability process");
    _exit(1);
    return nullptr;
}

struct XrayStartJob {
    std::string config;
    std::string workDir;
    std::atomic_bool finished{false};
    std::atomic_bool abandon{false};
    bool ok{false};
    std::string message;
    XraySettleJob notify;
    pthread_t workerTid{};
    std::atomic_bool workerCreated{false};
};

void RequestOwnedCoreStop(uint64_t ownerSeq);

std::atomic<uint64_t> g_xrayNextOwnerSeq{1};

std::atomic_int g_xrayWatchCreateFailInject{0};
std::atomic_int g_xrayTsfnStatusInject{0};
std::atomic_int g_xrayTsfnFailRemaining{0};

napi_status CallXrayStartTsfn(napi_threadsafe_function tsfn, void* data, napi_threadsafe_function_call_mode mode)
{
    const int remaining = g_xrayTsfnFailRemaining.load();
    if (remaining != 0) {
        if (remaining > 0) {
            g_xrayTsfnFailRemaining.fetch_sub(1);
        }
        const int injected = g_xrayTsfnStatusInject.load();
        return static_cast<napi_status>(injected != 0 ? injected : napi_generic_failure);
    }
    const int injected = g_xrayTsfnStatusInject.exchange(0);
    if (injected != 0) {
        return static_cast<napi_status>(injected);
    }
    return napi_call_threadsafe_function(tsfn, data, mode);
}

void ReapXrayStartWorker(const std::shared_ptr<XrayStartJob>& job, bool join)
{
    if (!XrayTakeWorkerReap(job->workerCreated)) {
        return;
    }
    if (join) {
        pthread_join(job->workerTid, nullptr);
    } else {
        pthread_detach(job->workerTid);
    }
}

struct XrayStartJsReply {
    napi_deferred deferred{nullptr};
    napi_threadsafe_function tsfn{nullptr};
    std::shared_ptr<XrayStartJob> job;
    bool ok{false};
    std::string message;
};

struct XrayStopJob {
    std::atomic_bool finished{false};
    bool ok{false};
    std::string message;
    XrayStopPermit permit;
};

void StartXrayCallJs(napi_env env, napi_value jsCb, void* context, void* data)
{
    (void)jsCb;
    (void)context;
    auto* reply = static_cast<XrayStartJsReply*>(data);
    if (env != nullptr && reply != nullptr && reply->deferred != nullptr) {
        const int64_t owner = reply->job ? static_cast<int64_t>(reply->job->notify.ownerSeq) : 0;
        napi_value result = CreateResult(env, reply->ok, reply->message, owner);
        napi_resolve_deferred(env, reply->deferred, result);
        if (reply->job) {
            std::lock_guard<std::mutex> lock(reply->job->notify.notifyMu);
            reply->job->notify.deferred = nullptr;
        }
    }
    if (reply != nullptr && reply->tsfn != nullptr) {
        napi_release_threadsafe_function(reply->tsfn, napi_tsfn_release);
    }
    delete reply;
}

void StartXrayTsfnFinalize(napi_env env, void* data, void* hint)
{
    (void)hint;
    auto* hold = static_cast<std::shared_ptr<XrayStartJob>*>(data);
    std::shared_ptr<XrayStartJob> job = hold != nullptr ? *hold : nullptr;
    delete hold;
    if (!job) {
        return;
    }
    std::string failText;
    void* deferred = nullptr;
    const bool resolve = XrayFinalizeDeferred(job->notify, env != nullptr, &failText, &deferred);
    if (resolve && env != nullptr && deferred != nullptr) {
        napi_value result = CreateResult(env, false, failText, static_cast<int64_t>(job->notify.ownerSeq));
        napi_resolve_deferred(env, static_cast<napi_deferred>(deferred), result);
    }
    XrayReclaimStartJob(job);
}

void* XrayStopWorker(void* arg);

bool NapiPhysicalStopXray(void* user)
{
    auto* job = static_cast<XrayStopJob*>(user);
    std::string message;
    if (!LoadXrayCore(message)) {
        job->ok = false;
        job->message = message;
        return false;
    }
    if (g_xrayLegacyApi) {
        if (g_cgoStopLegacy == nullptr) {
            job->ok = false;
            job->message = "CGoStopXray unavailable";
            return false;
        }
        char* raw = g_cgoStopLegacy();
        if (raw == nullptr) {
            job->ok = false;
            job->message = "CGoStopXray returned null";
            return false;
        }
        std::string response(raw);
        std::free(raw);
        if (!ResponseOk(response, job->message)) {
            job->ok = false;
            return false;
        }
    } else {
        std::string response;
        if (!InvokeXray("stopXray", "{}", response, message)) {
            job->ok = false;
            job->message = message;
            return false;
        }
        if (!InvokeSuccess(response, message)) {
            job->ok = false;
            job->message = message;
            return false;
        }
    }
    job->ok = true;
    job->message = "Xray core stopped.";
    return true;
}

void* OwnedStopWorker(void* arg)
{
    auto* permitHold = static_cast<XrayStopPermit*>(arg);
    const XrayStopPermit permit = permitHold != nullptr ? *permitHold : XrayStopPermit{};
    delete permitHold;
    auto job = std::make_shared<XrayStopJob>();
    job->permit = permit;
    auto* holder = new std::shared_ptr<XrayStopJob>(job);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, GO_WORKER_STACK);
    pthread_t tid;
    const int rc = pthread_create(&tid, &attr, XrayStopWorker, holder);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        delete holder;
        XrayCompleteStopPermit(g_xrayCore, permit, false);
        MarkPoisoned("owned xray stop worker create failed");
        return nullptr;
    }
    const int steps = NATIVE_STOP_TIMEOUT_MS > 0 ? (NATIVE_STOP_TIMEOUT_MS / 50) : 1;
    for (int i = 0; i < steps; ++i) {
        if (job->finished.load()) {
            pthread_join(tid, nullptr);
            if (!job->ok && XrayStillOwnsCore(permit.ownerSeq, g_xrayCore.liveOwner.load())) {
                MarkPoisoned(std::string("owned xray stop failed: ") + job->message);
            }
            return nullptr;
        }
        usleep(50000);
    }
    pthread_detach(tid);
    KeepOrphan(job);
    MarkPoisoned("owned xray stop timed out; core may still be alive");
    return nullptr;
}

void RequestOwnedCoreStop(uint64_t ownerSeq)
{
    const XrayStopPermit permit = XrayAcquireStopPermit(g_xrayCore, ownerSeq);
    if (!permit.allowPhysicalStop) {
        return;
    }
    auto* hold = new XrayStopPermit(permit);
    pthread_t tid;
    if (pthread_create(&tid, nullptr, OwnedStopWorker, hold) != 0) {
        delete hold;
        XrayCompleteStopPermit(g_xrayCore, permit, false);
        MarkPoisoned("owned xray stop spawn failed");
        return;
    }
    pthread_detach(tid);
}

void SettleXrayStartJob(const std::shared_ptr<XrayStartJob>& job, bool ok, const std::string& message)
{
    auto* reply = new XrayStartJsReply();
    reply->deferred = static_cast<napi_deferred>(job->notify.deferred);
    reply->tsfn = static_cast<napi_threadsafe_function>(job->notify.tsfn);
    reply->job = job;
    reply->ok = ok;
    reply->message = message;
    struct SettleUser {
        std::shared_ptr<XrayStartJob> job;
    } user;
    user.job = job;
    XraySettleHooks hooks{};
    hooks.dispatch = [](void* tsfn, void* payload, void* /*user*/) -> int {
        return static_cast<int>(CallXrayStartTsfn(static_cast<napi_threadsafe_function>(tsfn), payload,
            napi_tsfn_blocking));
    };
    hooks.releaseTsfn = [](void* tsfn, void* /*user*/) {
        napi_release_threadsafe_function(static_cast<napi_threadsafe_function>(tsfn), napi_tsfn_release);
    };
    hooks.reclaimJob = [](void* raw) {
        auto* u = static_cast<SettleUser*>(raw);
        XrayReclaimStartJob(u->job);
    };
    hooks.user = &user;
    hooks.napiOk = static_cast<int>(napi_ok);
    hooks.napiClosing = static_cast<int>(napi_closing);
    const XraySettleResult result = XraySettleNotify(job->notify, ok, message, reply, hooks);
    if (!result.payloadQueued) {
        delete reply;
    }
    if (result.action == XrayNotifyAction::ClosingDrop) {
        LogWarn("start notify closing; drop without release");
    } else if (result.action == XrayNotifyAction::Abandon && result.tsfnReleased) {
        LogWarn("start notify failed; tsfn released for finalize");
    } else if (result.action == XrayNotifyAction::Abandon) {
        LogWarn("start notify abandoned without tsfn release");
    } else if (result.action == XrayNotifyAction::AlreadySettled) {
        LogInfo("start notify already settled");
    }
    if (result.stopOwnerSeq != 0) {
        RequestOwnedCoreStop(result.stopOwnerSeq);
    }
}

void* XrayStartWatch(void* arg)
{
    auto* holder = static_cast<std::shared_ptr<XrayStartJob>*>(arg);
    std::shared_ptr<XrayStartJob> job = *holder;
    delete holder;
    const int steps = NATIVE_START_TIMEOUT_MS > 0 ? (NATIVE_START_TIMEOUT_MS / 50) : 1;
    for (int i = 0; i < steps; ++i) {
        if (job->finished.load()) {
            SettleXrayStartJob(job, job->ok, job->message);
            ReapXrayStartWorker(job, true);
            return nullptr;
        }
        usleep(50000);
    }
    job->abandon.store(true);
    if (job->finished.load()) {
        SettleXrayStartJob(job, job->ok, job->message);
        ReapXrayStartWorker(job, true);
        return nullptr;
    }
    SettleXrayStartJob(job, false, "Xray start timed out; job retained");
    ReapXrayStartWorker(job, false);
    return nullptr;
}

struct Tun2SocksJob {
    int tunFd;
    std::string host;
    int port;
    int mtu;
    int result;
    std::string message;
};

void* Tun2SocksStartWorker(void* arg)
{
    auto* job = static_cast<Tun2SocksJob*>(arg);
    if (!LoadTun2SocksCore(job->message)) {
        job->result = -2;
        return nullptr;
    }
    LogInfo("tun2socks worker: HeyTun2SocksStart");
    job->result = g_startTun2Socks(job->tunFd, const_cast<char*>(job->host.c_str()),
        job->port, job->mtu);
    return nullptr;
}

void FinishXrayStartJob(const std::shared_ptr<XrayStartJob>& job, bool ok, const std::string& message)
{
    const bool abandon = job->abandon.load();
    const std::vector<uint16_t> ports = XrayParseInboundListenPorts(job->config);
    const XrayFinishOutcome outcome =
        XrayFinishStartedJob(g_xrayCore, job->notify.ownerSeq, ok, abandon);
    if (ok && (outcome.reportOk || outcome.requestStop)) {
        XrayRememberInboundPorts(g_xrayCore, ports);
    }
    job->ok = outcome.reportOk;
    if (ok && abandon) {
        job->message = "Xray start abandoned after timeout; job retained";
    } else {
        job->message = message;
    }
    if (ok && !outcome.reportOk && !outcome.requestStop && XrayStartBlockedByStop(g_xrayCore)) {
        MarkPoisoned("xray start overlapped an in-flight stop");
    }
    if (!ok) {
        uint16_t livePort = 0;
        if (XrayAnyInboundSocksLive(ports, &livePort)) {
            LogError(std::string("xray start failed with live socks on ") + std::to_string(livePort));
        }
    }
    job->finished.store(true);
    {
        std::lock_guard<std::mutex> lock(g_xrayJobMu);
        g_xrayStarting.store(false);
        if (g_xrayStartJob == job) {
            g_xrayStartJob.reset();
        }
    }
    if (outcome.requestStop) {
        RequestOwnedCoreStop(outcome.stopOwnerSeq);
    }
    SettleXrayStartJob(job, job->ok, job->message);
}

void* XrayStartWorker(void* arg)
{
    auto* holder = static_cast<std::shared_ptr<XrayStartJob>*>(arg);
    std::shared_ptr<XrayStartJob> job = *holder;
    delete holder;
    LogInfo("xray worker: load libxray");
    if (!LoadXray()) {
        FinishXrayStartJob(job, false, g_lastMessage);
        LogError(std::string("xray worker load failed: ") + job->message);
        return nullptr;
    }
    std::string message;
    if (!LoadXrayCore(message)) {
        FinishXrayStartJob(job, false, message);
        LogError(std::string("xray worker symbols failed: ") + message);
        return nullptr;
    }
    setenv("XRAY_LOCATION_ASSET", job->workDir.c_str(), 1);
    if (g_xrayLegacyApi) {
        std::ostringstream req;
        req << "{\"datDir\":\"" << JsonEscape(job->workDir)
            << "\",\"configJSON\":\"" << JsonEscape(job->config) << "\"}";
        std::string b64 = Base64Encode(req.str());
        LogInfo("xray worker: CGoRunXrayFromJSON");
        char* raw = g_cgoRunFromJson(const_cast<char*>(b64.c_str()));
        if (raw == nullptr) {
            FinishXrayStartJob(job, false, "CGoRunXrayFromJSON returned null");
            LogError(job->message);
            return nullptr;
        }
        std::string response(raw);
        std::free(raw);
        if (!ResponseOk(response, job->message)) {
            FinishXrayStartJob(job, false, job->message);
            LogError(std::string("xray worker rejected: ") + job->message);
            return nullptr;
        }
    } else {
        std::ostringstream payload;
        payload << "{\"configJSON\":\"" << JsonEscape(job->config) << "\"}";
        std::string response;
        LogInfo("xray worker: CGoInvoke runXrayFromJson");
        if (!InvokeXray("runXrayFromJson", payload.str(), response, message)) {
            FinishXrayStartJob(job, false, message);
            LogError(std::string("xray worker invoke failed: ") + message);
            return nullptr;
        }
        if (!InvokeSuccess(response, message)) {
            FinishXrayStartJob(job, false, message);
            LogError(std::string("xray worker rejected: ") + message);
            return nullptr;
        }
    }
    FinishXrayStartJob(job, true, "Xray core started.");
    if (!job->ok) {
        LogWarn("xray worker: started but not accepted");
        return nullptr;
    }
    LogInfo("xray worker: started");
    return nullptr;
}

bool WaitLocalTcp(uint16_t port, int timeoutMs)
{
    const int stepMs = 100;
    int waited = 0;
    while (waited < timeoutMs) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            return false;
        }
        sockaddr_in addr;
        std::memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }
        int rc = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        bool ok = false;
        if (rc == 0) {
            ok = true;
        } else if (errno == EINPROGRESS) {
            pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            if (poll(&pfd, 1, stepMs) > 0) {
                int err = 0;
                socklen_t len = sizeof(err);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
                    ok = true;
                }
            }
        }
        close(fd);
        if (ok) {
            return true;
        }
        usleep(static_cast<useconds_t>(stepMs * 1000));
        waited += stepMs;
    }
    return false;
}

void KillXrayChild()
{
    pid_t pid = g_xrayPid.exchange(0);
    if (pid <= 0) {
        return;
    }
    kill(pid, SIGTERM);
    for (int i = 0; i < 30; ++i) {
        int status = 0;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid || (r < 0 && errno == ECHILD)) {
            return;
        }
        usleep(50000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);
}

bool CopyBinaryFile(const std::string& src, const std::string& dst, std::string& message)
{
    FILE* in = std::fopen(src.c_str(), "rb");
    if (in == nullptr) {
        message = ErrnoMessage("open source failed: " + src);
        return false;
    }
    FILE* out = std::fopen(dst.c_str(), "wb");
    if (out == nullptr) {
        std::fclose(in);
        message = ErrnoMessage("open dest failed: " + dst);
        return false;
    }
    char buf[8192];
    size_t n = 0;
    while ((n = std::fread(buf, 1, sizeof(buf), in)) > 0) {
        if (std::fwrite(buf, 1, n, out) != n) {
            std::fclose(in);
            std::fclose(out);
            message = ErrnoMessage("write dest failed: " + dst);
            return false;
        }
    }
    std::fclose(in);
    std::fclose(out);
    return true;
}

int SpawnMemfd(const std::string& runnerPath, char** argvSpawn, pid_t* pid, std::string& message)
{
    int src = open(runnerPath.c_str(), O_RDONLY);
    if (src < 0) {
        message = ErrnoMessage("open bundled runner failed");
        return errno;
    }
    int mem = memfd_create("xrayrun", MFD_CLOEXEC);
    if (mem < 0) {
        close(src);
        message = ErrnoMessage("memfd_create failed");
        return errno;
    }
    char buf[8192];
    ssize_t n = 0;
    while ((n = read(src, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(mem, buf + off, static_cast<size_t>(n - off));
            if (w <= 0) {
                close(src);
                close(mem);
                message = ErrnoMessage("memfd write failed");
                return errno;
            }
            off += w;
        }
    }
    close(src);
    if (fchmod(mem, 0755) != 0) {
        LogWarn(std::string("fchmod memfd: ") + std::strerror(errno));
    }
    std::string proc = std::string("/proc/self/fd/") + std::to_string(mem);
    int rc = posix_spawn(pid, proc.c_str(), nullptr, nullptr, argvSpawn, environ);
    close(mem);
    if (rc != 0) {
        message = std::string("memfd posix_spawn failed: ") + std::strerror(rc);
        return rc;
    }
    message = "spawned via memfd";
    return 0;
}

napi_value StartXray(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    napi_create_promise(env, &deferred, &promise);
    auto rejectNow = [&](bool ok, const std::string& message) -> napi_value {
        napi_value result = CreateResult(env, ok, message);
        napi_resolve_deferred(env, deferred, result);
        return promise;
    };
    if (argc < 1) {
        return rejectNow(false, "Missing Xray config JSON.");
    }

    std::string config = GetStringArg(env, args[0]);
    if (config.empty()) {
        return rejectNow(false, "Xray config JSON is empty.");
    }
    if (g_nativePoisoned.load()) {
        return rejectNow(false, "native poisoned; refuse Xray start");
    }
    std::string workDir = argc >= 2 ? GetStringArg(env, args[1]) : "";
    if (workDir.empty()) {
        return rejectNow(false, "Missing native work directory for Xray config.");
    }

    auto job = std::make_shared<XrayStartJob>();
    job->config = config;
    job->workDir = workDir;
    job->notify.ownerSeq = g_xrayNextOwnerSeq.fetch_add(1);
    job->notify.deferred = deferred;
    {
        const std::string injectPath = workDir + "/tongdao-notify-fail.inject";
        const XrayNotifyInject inject = XrayInspectNotifyInject(injectPath.c_str());
        if (!inject.present) {
            g_xrayTsfnFailRemaining.store(0);
            g_xrayTsfnStatusInject.store(0);
        } else {
            LogWarn("start notify inject file present; test variant only");
            g_xrayTsfnFailRemaining.store(inject.failRemaining);
            g_xrayTsfnStatusInject.store(inject.forceGenericFailure ? static_cast<int>(napi_generic_failure) : 0);
            if (!inject.keepFile) {
                std::remove(injectPath.c_str());
            }
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_xrayJobMu);
        if (g_xrayStarting.load() || g_xrayStartJob) {
            return rejectNow(false, "Xray start still pending; stop first");
        }
        if (XrayStartBlockedByStop(g_xrayCore)) {
            return rejectNow(false, "xray stop still in flight");
        }
        if (g_xrayCore.running.load()) {
            return rejectNow(true, "Xray already running.");
        }
        g_xrayStartJob = job;
        g_xrayStarting.store(true);
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "heyStartXray", NAPI_AUTO_LENGTH, &resourceName);
    napi_threadsafe_function tsfn = nullptr;
    auto* tsfnHold = new std::shared_ptr<XrayStartJob>(job);
    const napi_status ts = napi_create_threadsafe_function(
        env, nullptr, nullptr, resourceName, 0, 1, tsfnHold, StartXrayTsfnFinalize, nullptr, StartXrayCallJs, &tsfn);
    if (ts != napi_ok || tsfn == nullptr) {
        delete tsfnHold;
        std::lock_guard<std::mutex> lock(g_xrayJobMu);
        g_xrayStarting.store(false);
        if (g_xrayStartJob == job) {
            g_xrayStartJob.reset();
        }
        job->notify.deferred = nullptr;
        return rejectNow(false, "startXray promise notify failed");
    }
    {
        std::lock_guard<std::mutex> lock(job->notify.notifyMu);
        job->notify.tsfn = tsfn;
    }
    XrayTrackStartJob(job);
    auto* arg = new std::shared_ptr<XrayStartJob>(job);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, GO_WORKER_STACK);
    LogInfo("start xray in-process CGo");
    const int rc = pthread_create(&job->workerTid, &attr, XrayStartWorker, arg);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        delete arg;
        std::lock_guard<std::mutex> lock(g_xrayJobMu);
        g_xrayStarting.store(false);
        if (g_xrayStartJob == job) {
            g_xrayStartJob.reset();
        }
        {
            std::lock_guard<std::mutex> lock(job->notify.notifyMu);
            job->notify.deferred = nullptr;
            job->notify.tsfn = nullptr;
        }
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
        XrayReclaimStartJob(job);
        return rejectNow(false, std::string("pthread_create failed: ") + std::strerror(rc));
    }
    job->workerCreated.store(true);
    auto* watchArg = new std::shared_ptr<XrayStartJob>(job);
    pthread_t watchTid;
    int watchRc = 0;
    if (g_xrayWatchCreateFailInject.exchange(0) > 0) {
        watchRc = EAGAIN;
    } else {
        watchRc = pthread_create(&watchTid, nullptr, XrayStartWatch, watchArg);
    }
    if (watchRc != 0) {
        delete watchArg;
        job->abandon.store(true);
        ReapXrayStartWorker(job, false);
        SettleXrayStartJob(job, false, "Xray start watcher create failed; job retained");
        return promise;
    }
    pthread_detach(watchTid);
    return promise;
}

void* XrayStopWorker(void* arg)
{
    auto* holder = static_cast<std::shared_ptr<XrayStopJob>*>(arg);
    std::shared_ptr<XrayStopJob> job = *holder;
    delete holder;
    XrayPhysicalStopHooks hooks;
    hooks.cgoStop = NapiPhysicalStopXray;
    hooks.user = job.get();
    std::string detail;
    const XrayPhysicalStopResult result = XrayRunPermittedStop(g_xrayCore, job->permit, hooks, &detail);
    if (result == XrayPhysicalStopResult::Skipped) {
        job->ok = true;
        job->message = "xray owner mismatch; not stopped";
    } else if (result == XrayPhysicalStopResult::Failed) {
        job->ok = false;
        if (!detail.empty()) {
            job->message = detail;
        } else if (job->message.empty()) {
            job->message = "Xray stop failed";
        }
    } else if (!detail.empty()) {
        job->message = std::string("Xray core stopped; ") + detail;
        LogWarn(detail);
    }
    job->finished.store(true);
    return nullptr;
}

napi_value WaitXrayStopJob(napi_env env, const std::shared_ptr<XrayStopJob>& job, pthread_t tid,
    const XrayStopPermit& permit)
{
    const int steps = NATIVE_STOP_TIMEOUT_MS > 0 ? (NATIVE_STOP_TIMEOUT_MS / 50) : 1;
    for (int i = 0; i < steps; ++i) {
        if (job->finished.load()) {
            pthread_join(tid, nullptr);
            if (!job->ok) {
                MarkPoisoned(std::string("Xray stop failed: ") + job->message);
                return CreateResult(env, false, job->message, static_cast<int64_t>(permit.ownerSeq));
            }
            return CreateResult(env, true, job->message, static_cast<int64_t>(permit.ownerSeq));
        }
        usleep(50000);
    }
    pthread_detach(tid);
    KeepOrphan(job);
    MarkPoisoned("Xray stop timed out; core may still be alive");
    return CreateResult(env, false, "Xray stop timed out", static_cast<int64_t>(permit.ownerSeq));
}

napi_value DispatchPermittedXrayStop(napi_env env, XrayStopPermit permit)
{
    auto job = std::make_shared<XrayStopJob>();
    job->permit = permit;
    auto* arg = new std::shared_ptr<XrayStopJob>(job);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, GO_WORKER_STACK);
    pthread_t tid;
    const int rc = pthread_create(&tid, &attr, XrayStopWorker, arg);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        delete arg;
        XrayCompleteStopPermit(g_xrayCore, permit, false);
        MarkPoisoned(std::string("Xray stop worker create failed: ") + std::strerror(rc));
        return CreateResult(env, false, g_lastMessage, static_cast<int64_t>(permit.ownerSeq));
    }
    return WaitXrayStopJob(env, job, tid, permit);
}

bool WaitCoreIdleLocked(int timeoutMs)
{
    const int steps = timeoutMs > 0 ? (timeoutMs / 50) : 1;
    for (int i = 0; i < steps; ++i) {
        if (!g_xrayCore.running.load() && !XrayStartBlockedByStop(g_xrayCore)) {
            return true;
        }
        usleep(50000);
    }
    return !g_xrayCore.running.load() && !XrayStartBlockedByStop(g_xrayCore);
}

napi_value StopXrayOwned(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t seq = 0;
    if (argc >= 1 && args[0] != nullptr) {
        napi_get_value_int64(env, args[0], &seq);
    }
    if (seq <= 0) {
        return CreateResult(env, true, "xray owner mismatch; not stopped", seq);
    }
    const XrayStopPermit permit = XrayAcquireStopPermit(g_xrayCore, static_cast<uint64_t>(seq));
    if (!permit.allowPhysicalStop) {
        return CreateResult(env, true, permit.alreadyInFlight ? "xray stop already in flight"
                                                              : "xray owner mismatch; not stopped",
            seq);
    }
    return DispatchPermittedXrayStop(env, permit);
}

napi_value StopXray(napi_env env, napi_callback_info info)
{
    (void)info;
    KillXrayChild();
    if (g_nativePoisoned.load()) {
        return CreateResult(env, false, "native poisoned; refuse Xray stop restart path");
    }
    std::shared_ptr<XrayStartJob> pending;
    bool starting = false;
    {
        std::lock_guard<std::mutex> lock(g_xrayJobMu);
        pending = g_xrayStartJob;
        starting = g_xrayStarting.load();
    }
    uint64_t requiredOwner = 0;
    if (starting || pending) {
        if (pending) {
            pending->abandon.store(true);
            requiredOwner = pending->notify.ownerSeq;
            const int steps = NATIVE_STOP_TIMEOUT_MS > 0 ? (NATIVE_STOP_TIMEOUT_MS / 50) : 1;
            for (int i = 0; i < steps && !pending->finished.load(); ++i) {
                usleep(50000);
            }
            if (!pending->finished.load()) {
                MarkPoisoned("Xray start still pending after stop");
                return CreateResult(env, false, g_lastMessage);
            }
        }
    }
    if (g_xrayCore.running.load() && g_xrayCore.liveOwner.load() == 0) {
        MarkPoisoned("xray running without owner");
        return CreateResult(env, false, g_lastMessage);
    }
    const XrayStopPermit permit = XrayAcquireStopPermit(g_xrayCore, requiredOwner);
    if (permit.allowPhysicalStop) {
        return DispatchPermittedXrayStop(env, permit);
    }
    if (permit.alreadyInFlight || g_xrayCore.running.load() || XrayStartBlockedByStop(g_xrayCore)) {
        if (!WaitCoreIdleLocked(NATIVE_STOP_TIMEOUT_MS)) {
            if (g_xrayCore.running.load() || XrayStartBlockedByStop(g_xrayCore)) {
                MarkPoisoned("Xray stop still pending after wait");
                return CreateResult(env, false, g_lastMessage);
            }
        }
    }
    if (!g_xrayCore.running.load()) {
        std::lock_guard<std::mutex> lock(g_xrayJobMu);
        g_xrayStarting.store(false);
        if (g_xrayStartJob == pending) {
            g_xrayStartJob.reset();
        }
        if (pending) {
            return CreateResult(env, true, "Xray start abandoned");
        }
        if (g_xrayStarting.load() || g_xrayStartJob) {
            return CreateResult(env, false, "Xray start still in progress");
        }
        return CreateResult(env, true, "Xray already stopped.");
    }
    MarkPoisoned("xray still running after stop permit denied");
    return CreateResult(env, false, g_lastMessage);
}

bool ReadVpnTunProc(int64_t* rxBytes, int64_t* txBytes)
{
    if (rxBytes == nullptr || txBytes == nullptr) {
        return false;
    }
    FILE* fp = fopen("/proc/net/dev", "r");
    if (fp == nullptr) {
        return false;
    }
    char line[512];
    bool found = false;
    while (fgets(line, sizeof(line), fp) != nullptr) {
        if (std::strstr(line, "vpn-tun") == nullptr) {
            continue;
        }
        char* colon = std::strchr(line, ':');
        if (colon == nullptr) {
            break;
        }
        unsigned long long fields[16] = {0};
        int n = std::sscanf(colon + 1,
            "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
            &fields[0], &fields[1], &fields[2], &fields[3], &fields[4], &fields[5],
            &fields[6], &fields[7], &fields[8], &fields[9], &fields[10], &fields[11]);
        if (n >= 12) {
            *rxBytes = static_cast<int64_t>(fields[0]);
            *txBytes = static_cast<int64_t>(fields[8]);
            found = true;
        }
        break;
    }
    fclose(fp);
    return found;
}

bool SkipPhysicalIface(const char* name)
{
    if (name == nullptr || name[0] == '\0') {
        return true;
    }
    static const char* kSkip[] = {
        "lo", "vpn-tun", "dummy", "ifb", "tunl", "sit", "ip6", "p2p", "nan", "chba",
        "rmnet_tun", "rmnet_ims", "rmnet_emc", "rmnet_r_", "rmnet_d2d", "rmnet_mbs",
        "CPU", "Hisilicon", "hw_sate", "ip_vti", "ip6_vti", "ip6tnl", "ancowlan", nullptr
    };
    for (int i = 0; kSkip[i] != nullptr; ++i) {
        if (std::strncmp(name, kSkip[i], std::strlen(kSkip[i])) == 0) {
            return true;
        }
    }
    return false;
}

std::string DetectPhysicalIface()
{
    FILE* fp = fopen("/proc/net/dev", "r");
    if (fp == nullptr) {
        return "";
    }
    char line[512];
    std::string wlan;
    std::string other;
    while (fgets(line, sizeof(line), fp) != nullptr) {
        char* colon = std::strchr(line, ':');
        if (colon == nullptr) {
            continue;
        }
        *colon = '\0';
        char* name = line;
        while (*name == ' ' || *name == '\t') {
            ++name;
        }
        if (SkipPhysicalIface(name)) {
            continue;
        }
        unsigned long long rx = 0;
        unsigned long long tx = 0;
        if (std::sscanf(colon + 1, "%llu %*u %*u %*u %*u %*u %*u %*u %llu", &rx, &tx) < 1) {
            continue;
        }
        if (rx == 0 && tx == 0) {
            continue;
        }
        if (std::strncmp(name, "wlan", 4) == 0) {
            if (wlan.empty() || std::strcmp(name, "wlan0") == 0) {
                wlan = name;
            }
        } else if (other.empty()) {
            other = name;
        }
    }
    fclose(fp);
    if (!wlan.empty()) {
        return wlan;
    }
    return other;
}

napi_value GetStats(napi_env env, napi_callback_info info)
{
    (void)info;

    napi_value result = nullptr;
    napi_create_object(env, &result);
    PromoteProtectSymbol();
    // TUN 数据面运行时，用当前引擎的字节计数刷新流量统计（仅在已加载引擎的 VPN 扩展
    // 进程里命中；主进程指针为 null，自动跳过）。注：这只是兜底，真实分流量优先取
    // queryNativeTraffic（Xray metrics）。
    if (g_tunRunning.load()) {
        const int engine = g_tunEngine.load();
        if (engine == TUN_ENGINE_HEV && g_hevStats != nullptr) {
            // hev_socks5_tunnel_stats(tx_pkts, tx_bytes, rx_pkts, rx_bytes)，相对 TUN 网卡：
            // tx=从 TUN 收到上行、rx=回写 TUN 的下行。若真机方向相反，调换这两行即可。
            size_t txPackets = 0;
            size_t txBytes = 0;
            size_t rxPackets = 0;
            size_t rxBytes = 0;
            g_hevStats(&txPackets, &txBytes, &rxPackets, &rxBytes);
            g_uploadBytes.store(static_cast<int64_t>(txBytes));
            g_downloadBytes.store(static_cast<int64_t>(rxBytes));
        } else if (g_tun2SocksUploadBytes != nullptr && g_tun2SocksDownloadBytes != nullptr) {
            g_uploadBytes.store(g_tun2SocksUploadBytes());
            g_downloadBytes.store(g_tun2SocksDownloadBytes());
        }
    }
    napi_set_named_property(env, result, "uploadBytes", CreateInt64(env, g_uploadBytes.load()));
    napi_set_named_property(env, result, "downloadBytes", CreateInt64(env, g_downloadBytes.load()));
    napi_set_named_property(env, result, "xrayRunning", CreateBool(env, g_xrayCore.running.load()));
    napi_set_named_property(env, result, "xrayStarting", CreateBool(env, g_xrayStarting.load()));
    napi_set_named_property(env, result, "poisoned", CreateBool(env, g_nativePoisoned.load()));
    napi_set_named_property(env, result, "tunRunning", CreateBool(env, g_tunRunning.load()));
    napi_set_named_property(env, result, "lastMessage", CreateString(env, g_lastMessage));
    int64_t tunRx = 0;
    int64_t tunTx = 0;
    const bool tunFound = ReadVpnTunProc(&tunRx, &tunTx);
    napi_set_named_property(env, result, "tunFound", CreateBool(env, tunFound));
    napi_set_named_property(env, result, "tunRxBytes", CreateInt64(env, tunRx));
    napi_set_named_property(env, result, "tunTxBytes", CreateInt64(env, tunTx));
    napi_set_named_property(env, result, "physicalIface", CreateString(env, DetectPhysicalIface()));
    napi_set_named_property(env, result, "protectQueued", CreateInt64(env, g_protectQueued.load()));
    napi_set_named_property(env, result, "protectAcked", CreateInt64(env, g_protectAcked.load()));
    napi_set_named_property(env, result, "protectTimeout", CreateInt64(env, g_protectTimeout.load()));
    napi_set_named_property(env, result, "protectVisible", CreateInt32(env, g_protectVisible.load()));
    napi_set_named_property(env, result, "protectMeasured", CreateInt64(env, g_protectMeasured.load()));
    napi_set_named_property(env, result, "protectTotalUs", CreateInt64(env, g_protectTotalUs.load()));
    napi_set_named_property(env, result, "protectMaxUs", CreateInt64(env, g_protectMaxUs.load()));
    napi_set_named_property(env, result, "protectTcp4", CreateInt64(env, g_protectTcp4.load()));
    napi_set_named_property(env, result, "protectTcp6", CreateInt64(env, g_protectTcp6.load()));
    napi_set_named_property(env, result, "protectUdp", CreateInt64(env, g_protectUdp.load()));
    napi_set_named_property(env, result, "protectTcp4At", CreateInt64(env, g_protectTcp4At.load()));
    napi_set_named_property(env, result, "protectTcp6At", CreateInt64(env, g_protectTcp6At.load()));
    char hevDiag[2048] = {};
    if (g_hevDiagSnapshot != nullptr && g_tunEngine.load() == TUN_ENGINE_HEV) {
        if (g_hevDiagSnapshot(hevDiag, sizeof(hevDiag)) < 0) {
            hevDiag[0] = '\0';
        }
    }
    napi_set_named_property(env, result, "hevDiagnostics", CreateString(env, hevDiag));
    return result;
}

// 启动 tun2socks 适配器：把 TUN fd 的流量转发到 socks5://host:port。必须在 Xray 的
// SOCKS 入站已监听之后调用。
napi_value StartTun2Socks(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        return CreateResult(env, false, "Missing tun2socks arguments.");
    }
    int32_t tunFd = GetIntArg(env, args[0]);
    std::string host = GetStringArg(env, args[1]);
    int32_t port = GetIntArg(env, args[2]);
    int32_t mtu = GetIntArg(env, args[3]);
    if (tunFd < 0) {
        return CreateResult(env, false, "Invalid TUN fd.");
    }
    if (g_nativePoisoned.load()) {
        return CreateResult(env, false, "native poisoned; refuse tun2socks start");
    }
    if (host.empty() || port <= 0 || port > 65535 || mtu < 576 || mtu > 1500) {
        return CreateResult(env, false, "Invalid tun2socks host, port, or MTU.");
    }
    if (g_tunRunning.load()) {
        return CreateResult(env, true, "tun2socks already running.");
    }
    g_uploadBytes.store(0);
    g_downloadBytes.store(0);

    std::string message;
    if (!MakeFdInheritable(tunFd, message)) {
        return CreateResult(env, false, message);
    }

    Tun2SocksJob job;
    job.tunFd = tunFd;
    job.host = host;
    job.port = port;
    job.mtu = mtu;
    job.result = -1;
    std::string threadErr;
    if (!RunOnGoWorker(Tun2SocksStartWorker, &job, threadErr)) {
        return CreateResult(env, false, threadErr);
    }
    if (job.result == -2) {
        g_lastMessage = job.message;
        LogError(job.message);
        return CreateResult(env, false, job.message);
    }
    if (job.result != 0) {
        return CreateResult(env, false, "tun2socks adapter start failed.");
    }
    g_tunRunning.store(true);
    g_tunEngine.store(TUN_ENGINE_GVISOR);
    return CreateResult(env, true, "tun2socks adapter started.");
}

// 启动 hev-socks5-tunnel 引擎：把 TUN fd 的流量按 yaml 配置转发到本地 SOCKS。与
// StartTun2Socks 互斥（同一时刻只跑一条数据面）。hev 的 main 阻塞，放到独立线程。
napi_value StartHevTun(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return CreateResult(env, false, "Missing hev tun arguments.");
    }
    int32_t tunFd = GetIntArg(env, args[0]);
    std::string configYaml = GetStringArg(env, args[1]);
    if (tunFd < 0) {
        return CreateResult(env, false, "Invalid TUN fd.");
    }
    if (configYaml.empty()) {
        return CreateResult(env, false, "Empty hev tun config.");
    }
    if (g_nativePoisoned.load()) {
        return CreateResult(env, false, "native poisoned; refuse hev start");
    }
    std::string message;
    if (!LoadHevCore(message)) {
        g_lastMessage = message;
        LogError(message);
        return CreateResult(env, false, message);
    }
    if (!MakeFdInheritable(tunFd, message)) {
        return CreateResult(env, false, message);
    }

    HevStartFunc start = nullptr;
    uint64_t life = 0;
    {
        std::lock_guard<std::mutex> hevLock(g_hevMu);
        if (g_tunRunning.load() || (g_hevThread.joinable() && g_hevMainRc.load() == -2)) {
            return CreateResult(env, false, "tun data plane already running.");
        }
        if (g_hevThread.joinable()) {
            g_hevThread.join();
        }
        start = g_hevStart;
        if (start == nullptr) {
            return CreateResult(env, false, "hev start symbol missing");
        }
        using SetAppRoutes = void (*)(AppFlowBeginFn, AppFlowCancelFn, void*);
        auto setAppRoutes = reinterpret_cast<SetAppRoutes>(dlsym(g_hevHandle,
            "hev_socks5_tunnel_set_app_route_callbacks"));
        if (!setAppRoutes && AppFlowEnabled()) {
            return CreateResult(env, false, "HEV does not support App routing");
        }
        if (setAppRoutes) {
            setAppRoutes(AppFlowEnabled() ? AppFlowBegin : nullptr,
                AppFlowEnabled() ? AppFlowCancel : nullptr, nullptr);
        }
        g_uploadBytes.store(0);
        g_downloadBytes.store(0);
        g_hevMainRc.store(-2);
        life = g_hevLife.fetch_add(1) + 1;
        g_tunEngine.store(TUN_ENGINE_HEV);
        g_hevThread = std::thread([start, configYaml, tunFd, life]() {
            const int rc = start(reinterpret_cast<const unsigned char*>(configYaml.c_str()),
                static_cast<unsigned int>(configYaml.size()), tunFd);
            std::lock_guard<std::mutex> hevLock(g_hevMu);
            if (g_hevLife.load() != life) {
                return;
            }
            g_hevMainRc.store(rc);
            g_tunRunning.store(false);
            g_tunEngine.store(TUN_ENGINE_NONE);
        });
    }
    // rc stays -2 while main() blocks. Init failure returns -1 quickly.
    // Require ~400ms still-blocked before declaring running; wait up to 1s for -1.
    // Do not hold g_hevMu across the wait: stop must be able to take the HEV path.
    bool started = false;
    for (int i = 0; i < 20; ++i) {
        usleep(50000);
        const int rc = g_hevMainRc.load();
        if (rc == -1) {
            std::lock_guard<std::mutex> hevLock(g_hevMu);
            if (g_hevThread.joinable()) {
                g_hevThread.join();
            }
            g_tunEngine.store(TUN_ENGINE_NONE);
            g_tunRunning.store(false);
            return CreateResult(env, false, "hev tun failed during init");
        }
        if (rc != -2) {
            std::lock_guard<std::mutex> hevLock(g_hevMu);
            if (g_hevThread.joinable()) {
                g_hevThread.join();
            }
            g_tunEngine.store(TUN_ENGINE_NONE);
            g_tunRunning.store(false);
            return CreateResult(env, false, "hev tun exited before running");
        }
        if (i >= 7) {
            started = true;
            break;
        }
    }
    if (!started) {
        return CreateResult(env, false, "hev tun start timed out");
    }
    {
        std::lock_guard<std::mutex> hevLock(g_hevMu);
        if (g_hevLife.load() != life) {
            return CreateResult(env, false, "hev life epoch mismatch");
        }
        if (g_hevMainRc.load() != -2) {
            if (g_hevThread.joinable()) {
                g_hevThread.join();
            }
            g_tunEngine.store(TUN_ENGINE_NONE);
            g_tunRunning.store(false);
            return CreateResult(env, false, "hev tun exited before running");
        }
        g_tunRunning.store(true);
        g_tunEngine.store(TUN_ENGINE_HEV);
    }
    return CreateResult(env, true, "hev tun engine started.");
}

struct HevStopJob {
    std::atomic_bool finished{false};
    bool ok{false};
    std::string message;
};

void* HevStopWorker(void* arg)
{
    auto* holder = static_cast<std::shared_ptr<HevStopJob>*>(arg);
    std::shared_ptr<HevStopJob> job = *holder;
    delete holder;
    HevQuitFunc quit = nullptr;
    {
        std::lock_guard<std::mutex> hevLock(g_hevMu);
        quit = g_hevQuit;
    }
    if (quit != nullptr) {
        quit();
    }
    while (g_hevMainRc.load() == -2) {
        usleep(50000);
    }
    {
        std::lock_guard<std::mutex> hevLock(g_hevMu);
        if (g_hevThread.joinable()) {
            g_hevThread.join();
        }
        g_hevLife.fetch_add(1);
        g_tunEngine.store(TUN_ENGINE_NONE);
        g_tunRunning.store(false);
    }
    job->ok = true;
    job->message = "hev tun stopped.";
    job->finished.store(true);
    return nullptr;
}

struct Tun2SocksStopJob {
    std::atomic_bool finished{false};
    bool ok{false};
    std::string message;
};

void* Tun2SocksStopWorker(void* arg)
{
    auto* holder = static_cast<std::shared_ptr<Tun2SocksStopJob>*>(arg);
    std::shared_ptr<Tun2SocksStopJob> job = *holder;
    delete holder;
    std::string message;
    if (!LoadTun2SocksCore(message)) {
        job->ok = false;
        job->message = message;
        job->finished.store(true);
        return nullptr;
    }
    Tun2SocksStopFunc stop = g_stopTun2Socks;
    if (stop != nullptr) {
        stop();
    }
    g_tunEngine.store(TUN_ENGINE_NONE);
    g_tunRunning.store(false);
    job->ok = true;
    job->message = "tun2socks stopped.";
    job->finished.store(true);
    return nullptr;
}

napi_value StopTun2Socks(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_nativePoisoned.load()) {
        return CreateResult(env, false, "native poisoned; refuse hev stop restart path");
    }
    bool alreadyStopped = false;
    int engine = TUN_ENGINE_NONE;
    bool hevThreadLive = false;
    {
        std::lock_guard<std::mutex> hevLock(g_hevMu);
        hevThreadLive = g_hevThread.joinable();
        if (!g_tunRunning.load() && !hevThreadLive) {
            alreadyStopped = true;
        } else {
            engine = g_tunEngine.load();
        }
    }
    if (alreadyStopped) {
        return CreateResult(env, true, "tun data plane already stopped.");
    }
    if (engine == TUN_ENGINE_HEV || (engine == TUN_ENGINE_NONE && hevThreadLive)) {
        auto job = std::make_shared<HevStopJob>();
        auto* arg = new std::shared_ptr<HevStopJob>(job);
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, GO_WORKER_STACK);
        pthread_t tid;
        const int rc = pthread_create(&tid, &attr, HevStopWorker, arg);
        pthread_attr_destroy(&attr);
        if (rc != 0) {
            delete arg;
            MarkPoisoned(std::string("hev stop worker create failed: ") + std::strerror(rc));
            return CreateResult(env, false, g_lastMessage);
        }
        const int steps = NATIVE_STOP_TIMEOUT_MS > 0 ? (NATIVE_STOP_TIMEOUT_MS / 50) : 1;
        for (int i = 0; i < steps; ++i) {
            if (job->finished.load()) {
                pthread_join(tid, nullptr);
                if (!job->ok) {
                    MarkPoisoned(std::string("hev stop failed: ") + job->message);
                    return CreateResult(env, false, job->message);
                }
                return CreateResult(env, true, job->message);
            }
            usleep(50000);
        }
        pthread_detach(tid);
        KeepOrphan(job);
        MarkPoisoned("hev stop timed out; worker detached, restart forbidden");
        return CreateResult(env, false, "hev stop timed out");
    }
    auto job = std::make_shared<Tun2SocksStopJob>();
    auto* arg = new std::shared_ptr<Tun2SocksStopJob>(job);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, GO_WORKER_STACK);
    pthread_t tid;
    const int rc = pthread_create(&tid, &attr, Tun2SocksStopWorker, arg);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        delete arg;
        MarkPoisoned(std::string("tun2socks stop worker create failed: ") + std::strerror(rc));
        return CreateResult(env, false, g_lastMessage);
    }
    const int steps = NATIVE_STOP_TIMEOUT_MS > 0 ? (NATIVE_STOP_TIMEOUT_MS / 50) : 1;
    for (int i = 0; i < steps; ++i) {
        if (job->finished.load()) {
            pthread_join(tid, nullptr);
            if (!job->ok) {
                MarkPoisoned(std::string("tun2socks stop failed: ") + job->message);
                return CreateResult(env, false, job->message);
            }
            return CreateResult(env, true, job->message);
        }
        usleep(50000);
    }
    pthread_detach(tid);
    KeepOrphan(job);
    MarkPoisoned("tun2socks stop timed out; worker detached, restart forbidden");
    return CreateResult(env, false, "tun2socks stop timed out");
}

// ===================== sing-box second core (optional, preview) =====================
// libsingbox.so 是 sing-box 内核的 c-shared 封装（见 libsingbox/）。与上面的 Xray 核
// 平行：start/stop/setTunFd 必须从 VPN 原生线程调用（GOOS=android 下唯一安全的
// cgo->Go 上下文）。SingboxProbe 只 dlopen+dlsym、不触发 cgo，UI 线程点按也安全。
constexpr const char* SINGBOX_CORE_LIB = "libsingbox.so";

void* OpenSingbox(std::string& message)
{
    void* handle = dlopen(ExecPath(SINGBOX_CORE_LIB).c_str(), RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
        handle = dlopen(SINGBOX_CORE_LIB, RTLD_LAZY | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        const char* error = dlerror();
        message = std::string("dlopen ") + SINGBOX_CORE_LIB + " failed: " +
            (error != nullptr ? error : "unknown error");
    }
    return handle;
}

// 懒加载 libsingbox.so 并解析生命周期符号。只应从 VPN 原生线程调用。
bool LoadSingboxCore(std::string& message)
{
    if (g_singboxHandle != nullptr && g_singboxStart != nullptr && g_singboxStop != nullptr &&
        g_singboxSetTunFd != nullptr) {
        return true;
    }
    void* handle = OpenSingbox(message);
    if (handle == nullptr) {
        return false;
    }
    dlerror();
    g_singboxStart = reinterpret_cast<CGoStringFunc>(dlsym(handle, "CGoStartSingBox"));
    g_singboxStop = reinterpret_cast<CGoStopFunc>(dlsym(handle, "CGoStopSingBox"));
    g_singboxSetTunFd = reinterpret_cast<CGoSetTunFdFunc>(dlsym(handle, "CGoSetTunFd"));
    if (g_singboxStart == nullptr || g_singboxStop == nullptr || g_singboxSetTunFd == nullptr) {
        message = "libsingbox unavailable: required CGo symbols missing.";
        return false;
    }
    g_singboxHandle = handle;
    return true;
}

// 诊断用：只 dlopen+dlsym，不触发 cgo，UI 线程安全（关于页探测按钮用）。
napi_value SingboxProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string message;
    void* handle = OpenSingbox(message);
    if (handle == nullptr) {
        return CreateResultQuiet(env, false, message);
    }
    dlerror();
    bool hasVersion = dlsym(handle, "CGoSingBoxVersion") != nullptr;
    bool hasStart = dlsym(handle, "CGoStartSingBox") != nullptr;
    bool hasStop = dlsym(handle, "CGoStopSingBox") != nullptr;
    bool hasSetTun = dlsym(handle, "CGoSetTunFd") != nullptr;
    std::ostringstream out;
    out << "libsingbox.so loaded. symbols: "
        << "Version=" << (hasVersion ? "yes" : "no")
        << " Start=" << (hasStart ? "yes" : "no")
        << " Stop=" << (hasStop ? "yes" : "no")
        << " SetTunFd=" << (hasSetTun ? "yes" : "no");
    bool ok = hasVersion && hasStart && hasStop && hasSetTun;
    return CreateResultQuiet(env, ok, out.str());
}

// 真调 CGoSingBoxVersion —— 仅限 VPN 原生线程（UI 线程冷调可能 SIGSEGV）。
napi_value SingboxVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string message;
    void* handle = OpenSingbox(message);
    if (handle == nullptr) {
        return CreateResultQuiet(env, false, message);
    }
    dlerror();
    CGoVersionFunc version = reinterpret_cast<CGoVersionFunc>(dlsym(handle, "CGoSingBoxVersion"));
    if (version == nullptr) {
        return CreateResultQuiet(env, false, "CGoSingBoxVersion not exported by libsingbox.so.");
    }
    char* raw = version();
    return BuildCallResult(env, raw, "CGoSingBoxVersion returned null.");
}

napi_value SingboxSetTunFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResult(env, false, "Missing TUN fd.");
    }

    int32_t tunFd = GetIntArg(env, args[0]);
    if (tunFd < 0) {
        return CreateResult(env, false, "Invalid TUN fd.");
    }
    if (g_singboxRunning.load()) {
        return CreateResult(env, false, "Cannot set TUN fd while sing-box is running.");
    }

    std::string message;
    if (!LoadSingboxCore(message)) {
        g_tunRunning.store(false);
        return CreateResult(env, false, message);
    }
    if (!MakeFdInheritable(tunFd, message)) {
        g_tunRunning.store(false);
        return CreateResult(env, false, message);
    }

    g_uploadBytes.store(0);
    g_downloadBytes.store(0);
    // sing-box 自己管 tun：把 fd 存进 Go wrapper，CGoStartSingBox 时由 OpenTun 取用。
    g_singboxSetTunFd(tunFd);
    g_tunRunning.store(true);
    return CreateResult(env, true, "sing-box TUN fd configured.");
}

napi_value SingboxStart(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResult(env, false, "Missing sing-box config JSON.");
    }

    std::string config = GetStringArg(env, args[0]);
    if (config.empty()) {
        return CreateResult(env, false, "sing-box config JSON is empty.");
    }
    if (g_singboxRunning.load()) {
        return CreateResult(env, true, "sing-box already running.");
    }

    std::string workDir = argc >= 2 ? GetStringArg(env, args[1]) : "";
    if (workDir.empty()) {
        return CreateResult(env, false, "Missing native work directory for sing-box config.");
    }

    std::string message;
    if (!LoadSingboxCore(message)) {
        g_singboxRunning.store(false);
        return CreateResult(env, false, message);
    }

    // 请求体对齐 libsingbox/main.go 的 startRequest：{"basePath":..,"config":..}
    std::ostringstream request;
    request << "{\"basePath\":\"" << JsonEscape(workDir) << "\","
            << "\"config\":\"" << JsonEscape(config) << "\"}";
    std::string encoded = Base64Encode(request.str());
    std::vector<char> buffer(encoded.begin(), encoded.end());
    buffer.push_back('\0');

    char* raw = g_singboxStart(buffer.data());
    if (raw == nullptr) {
        g_singboxRunning.store(false);
        return CreateResult(env, false, "libsingbox start returned null.");
    }
    std::string response(raw);
    std::free(raw);
    if (!ResponseOk(response, message)) {
        g_singboxRunning.store(false);
        return CreateResult(env, false, message);
    }

    g_singboxRunning.store(true);
    return CreateResult(env, true, "sing-box core started.");
}

napi_value SingboxStop(napi_env env, napi_callback_info info)
{
    (void)info;
    if (!g_singboxRunning.load()) {
        g_tunRunning.store(false);
        return CreateResult(env, true, "sing-box already stopped.");
    }

    std::string message;
    if (!LoadSingboxCore(message)) {
        return CreateResult(env, false, message);
    }

    char* raw = g_singboxStop();
    if (raw == nullptr) {
        return CreateResult(env, false, "libsingbox stop returned null.");
    }
    std::string response(raw);
    std::free(raw);
    if (!ResponseOk(response, message)) {
        return CreateResult(env, false, message);
    }

    g_singboxRunning.store(false);
    g_tunRunning.store(false);
    return CreateResult(env, true, "sing-box core stopped.");
}
// =================== [end sing-box second core] ===================

std::atomic_bool g_sniffRunning(false);
std::thread g_sniffThread;
std::mutex g_sniffMutex;
std::vector<std::string> g_sniffEvents;
int g_sniffFd = -1;
constexpr int SNIFF_EVENT_LIMIT = 64;

void RecordSniff(const std::string& event)
{
    std::lock_guard<std::mutex> lock(g_sniffMutex);
    g_sniffEvents.push_back(event);
    if (static_cast<int>(g_sniffEvents.size()) > SNIFF_EVENT_LIMIT) {
        g_sniffEvents.erase(g_sniffEvents.begin(), g_sniffEvents.begin() + 16);
    }
}

std::string Ipv4Text(const uint8_t* bytes)
{
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%u.%u.%u.%u", bytes[0], bytes[1], bytes[2], bytes[3]);
    return std::string(buf);
}

std::string ParseDnsQname(const uint8_t* payload, size_t length)
{
    if (length < 12) {
        return "";
    }
    size_t offset = 12;
    std::string name;
    while (offset < length) {
        uint8_t label = payload[offset];
        if (label == 0) {
            break;
        }
        if ((label & 0xc0) == 0xc0) {
            break;
        }
        offset += 1;
        if (offset + label > length) {
            break;
        }
        if (!name.empty()) {
            name.append(".");
        }
        name.append(reinterpret_cast<const char*>(payload + offset), label);
        offset += label;
    }
    return name;
}

void ParsePacket(const uint8_t* data, ssize_t length)
{
    if (length < 20) {
        return;
    }
    size_t ipOff = 0;
    uint8_t version = data[0] >> 4;
    if (version != 4 && version != 6 && length > 4) {
        ipOff = 4;
        version = data[4] >> 4;
    }
    if (version == 4) {
        if (ipOff + 20 > static_cast<size_t>(length)) {
            return;
        }
        const uint8_t* ip = data + ipOff;
        std::string dest = Ipv4Text(ip + 16);
        uint8_t ihl = (ip[0] & 0x0f) * 4;
        uint8_t proto = ip[9];
        RecordSniff(std::string("v4-dst=") + dest + " proto=" + std::to_string(proto));
        if (proto == 17 && ipOff + ihl + 8 <= static_cast<size_t>(length)) {
            const uint8_t* udp = ip + ihl;
            uint16_t dport = static_cast<uint16_t>((udp[2] << 8) | udp[3]);
            if (dport == 53) {
                std::string qname = ParseDnsQname(udp + 8, static_cast<size_t>(length) - (ipOff + ihl + 8));
                if (!qname.empty()) {
                    RecordSniff(std::string("dns-q=") + qname);
                }
            }
        }
        return;
    }
    if (version == 6) {
        RecordSniff("v6-packet");
    }
}

void SniffLoop(int fd)
{
    std::vector<uint8_t> buf(2048);
    while (g_sniffRunning.load()) {
        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int ready = poll(&pfd, 1, 200);
        if (ready <= 0) {
            continue;
        }
        ssize_t n = read(fd, buf.data(), buf.size());
        if (n <= 0) {
            if (!g_sniffRunning.load()) {
                break;
            }
            if (errno == EAGAIN || errno == EINTR) {
                continue;
            }
            RecordSniff(std::string("sniff-read-end errno=") + std::to_string(errno));
            break;
        }
        ParsePacket(buf.data(), n);
    }
}

napi_value StartTunSniffer(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return CreateResult(env, false, "Missing TUN fd.");
    }
    int32_t tunFd = GetIntArg(env, args[0]);
    if (tunFd < 0) {
        return CreateResult(env, false, "Invalid TUN fd.");
    }
    if (g_sniffRunning.load()) {
        return CreateResult(env, true, "TUN sniffer already running.");
    }
    {
        std::lock_guard<std::mutex> lock(g_sniffMutex);
        g_sniffEvents.clear();
    }
    g_sniffFd = tunFd;
    g_sniffRunning.store(true);
    g_sniffThread = std::thread(SniffLoop, tunFd);
    return CreateResult(env, true, "TUN sniffer started. Packets have no UID field.");
}

napi_value StopTunSniffer(napi_env env, napi_callback_info info)
{
    (void)info;
    if (!g_sniffRunning.exchange(false)) {
        return CreateResult(env, true, "TUN sniffer already stopped.");
    }
    if (g_sniffThread.joinable()) {
        g_sniffThread.join();
    }
    g_sniffFd = -1;
    return CreateResult(env, true, "TUN sniffer stopped.");
}

napi_value GetTunSniffLog(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_sniffMutex);
    std::ostringstream out;
    for (size_t i = 0; i < g_sniffEvents.size(); ++i) {
        if (i > 0) {
            out << "\n";
        }
        out << g_sniffEvents[i];
    }
    return CreateResult(env, true, out.str());
}

} // namespace

struct GoHelloJob {
    bool ok;
    std::string message;
};

void* GoHelloWorker(void* arg)
{
    auto* job = static_cast<GoHelloJob*>(arg);
    LogInfo("gotest worker: dlopen libgotest.so");
    void* handle = dlopen(ExecPath("libgotest.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        handle = dlopen("libgotest.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        const char* error = dlerror();
        job->ok = false;
        job->message = std::string("dlopen libgotest.so failed: ") + (error != nullptr ? error : "unknown");
        LogError(job->message);
        return nullptr;
    }
    using GoHelloFunc = char* (*)();
    auto hello = reinterpret_cast<GoHelloFunc>(dlsym(handle, "GoHello"));
    if (hello == nullptr) {
        job->ok = false;
        job->message = "GoHello symbol missing";
        LogError(job->message);
        return nullptr;
    }
    LogInfo("gotest worker: calling GoHello");
    char* raw = hello();
    if (raw == nullptr) {
        job->ok = false;
        job->message = "GoHello returned null";
        LogError(job->message);
        return nullptr;
    }
    job->ok = true;
    job->message = std::string("GoHello=") + raw;
    LogInfo(job->message);
    return nullptr;
}

napi_value ProbeGoHello(napi_env env, napi_callback_info info)
{
    (void)info;
    GoHelloJob job;
    job.ok = false;
    std::string threadErr;
    if (!RunOnGoWorker(GoHelloWorker, &job, threadErr)) {
        return CreateResult(env, false, threadErr);
    }
    return CreateResult(env, job.ok, job.message);
}

struct XrayVersionJob {
    bool ok;
    std::string message;
};

void* XrayVersionWorker(void* arg)
{
    auto* job = static_cast<XrayVersionJob*>(arg);
    std::string message;
    LogInfo("xray version worker: load libxray");
    if (!LoadXrayCore(message)) {
        job->ok = false;
        job->message = message;
        LogError(job->message);
        return nullptr;
    }
    if (g_xrayLegacyApi) {
        std::string helloMsg;
        if (g_cgoHello != nullptr) {
            LogInfo("xray version worker: CGoHello");
            char* helloRaw = g_cgoHello();
            if (helloRaw == nullptr) {
                job->ok = false;
                job->message = "CGoHello returned null";
                LogError(job->message);
                return nullptr;
            }
            helloMsg = std::string("CGoHello=") + helloRaw;
            LogInfo(helloMsg);
            std::free(helloRaw);
        }
        if (g_cgoVersionLegacy == nullptr) {
            job->ok = !helloMsg.empty();
            job->message = helloMsg.empty() ? "CGoXrayVersion symbol missing" : helloMsg;
            return nullptr;
        }
        LogInfo("xray version worker: CGoXrayVersion");
        char* raw = g_cgoVersionLegacy();
        if (raw == nullptr) {
            job->ok = false;
            job->message = "CGoXrayVersion returned null";
            LogError(job->message);
            return nullptr;
        }
        std::string response(raw);
        std::free(raw);
        std::string decoded = Base64Decode(response);
        if (decoded.empty()) {
            decoded = response;
        }
        job->ok = decoded.find("\"success\":true") != std::string::npos;
        job->message = std::string("legacy ") + decoded;
        LogInfo(job->message);
        return nullptr;
    }
    std::string response;
    LogInfo("xray version worker: CGoInvoke xrayVersion");
    if (!InvokeXray("xrayVersion", "{}", response, message)) {
        job->ok = false;
        job->message = message;
        LogError(job->message);
        return nullptr;
    }
    job->ok = InvokeSuccess(response, message);
    job->message = response;
    LogInfo(job->message);
    return nullptr;
}

napi_value ProbeXrayVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    XrayVersionJob job;
    job.ok = false;
    std::string threadErr;
    if (!RunOnGoWorker(XrayVersionWorker, &job, threadErr)) {
        return CreateResult(env, false, threadErr);
    }
    return CreateResult(env, job.ok, job.message);
}

void* XrayVersionDetached(void* arg)
{
    auto* job = static_cast<XrayVersionJob*>(arg);
    XrayVersionWorker(job);
    LogInfo(std::string("xray async probe done ok=") + (job->ok ? "true" : "false") +
        " msg=" + job->message);
    delete job;
    return nullptr;
}

napi_value ProbeXrayVersionAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    auto* job = new XrayVersionJob();
    job->ok = false;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, GO_WORKER_STACK);
    pthread_t tid;
    int rc = pthread_create(&tid, &attr, XrayVersionDetached, job);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        delete job;
        return CreateResult(env, false, std::string("pthread_create failed: ") + std::strerror(rc));
    }
    return CreateResult(env, true, "xray probe started");
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    RegisterAppFlowRouter(env, exports);
    napi_property_descriptor desc[] = {
        { "createSocksSession", nullptr, CreateSocksSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "validateConfig", nullptr, ValidateConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setTunFd", nullptr, SetTunFd, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startXray", nullptr, StartXray, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopXray", nullptr, StopXray, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopXrayOwned", nullptr, StopXrayOwned, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getStats", nullptr, GetStats, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startTun2Socks", nullptr, StartTun2Socks, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startHevTun", nullptr, StartHevTun, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopTun2Socks", nullptr, StopTun2Socks, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "atomicReplaceFile", nullptr, AtomicReplaceFile, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "abortPoisonedNative", nullptr, AbortPoisonedNative, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pingOutbound", nullptr, PingOutbound, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "queryStats", nullptr, QueryStats, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "testXrayConfig", nullptr, TestXrayConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "xrayVersion", nullptr, XrayVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "countGeoData", nullptr, CountGeoData, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "readGeoFiles", nullptr, ReadGeoFiles, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getFreePorts", nullptr, GetFreePorts, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "convertShareLinksToXrayJson", nullptr, ConvertShareLinksToXrayJson, nullptr, nullptr, nullptr,
            napi_default, nullptr },
        { "convertXrayJsonToShareLinks", nullptr, ConvertXrayJsonToShareLinks, nullptr, nullptr, nullptr,
            napi_default, nullptr },
        { "setProtectCallback", nullptr, SetProtectCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "clearProtectCallback", nullptr, ClearProtectCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "takeProtectFd", nullptr, TakeProtectFd, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "claimProtectFd", nullptr, ClaimProtectFd, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "ackProtectFd", nullptr, AckProtectFd, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module heyVpnModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "heyvpn",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterHeyVpnModule(void)
{
    napi_module_register(&heyVpnModule);
}
