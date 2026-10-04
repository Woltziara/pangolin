#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include "napi/native_api.h"
#include "xray_start_notify.h"
#include "xray_start_lifecycle.h"
#include "app_flow_router.h"
#include "protect_lease.h"
#include "atomic_cas.h"

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
#include <signal.h>
#include <sstream>
#include <string>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <arpa/inet.h>

#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

namespace {

constexpr unsigned int LOG_DOMAIN_ID = 0x0001;
constexpr const char* LOG_TAG_NAME = "HeyNative";
constexpr const char* XRAY_CORE_LIB = "libxray.so";

using CGoStringFunc = char* (*)(char*);
using CGoStopFunc = char* (*)();
using CGoVersionFunc = char* (*)();

struct XrayStartJob;

XrayCoreIdentity g_xrayCore;
std::atomic_bool g_xrayStarting(false);
std::mutex g_xrayJobMu;
std::shared_ptr<XrayStartJob> g_xrayStartJob;
std::atomic_bool g_tunRunning(false);
std::atomic_bool g_nativePoisoned(false);
std::mutex g_lifetimeMu;
std::vector<std::shared_ptr<void>> g_orphans;
std::mutex g_hevMu;
std::mutex g_atomicReplaceMu;
std::atomic<int64_t> g_uploadBytes(0);
std::atomic<int64_t> g_downloadBytes(0);
std::mutex g_messageMu;
std::string g_lastMessage = "Native bridge ready. Waiting for Xray shared library.";
void* g_xrayHandle = nullptr;
// Pinned libXray ABI; startup and stop use the same version lock.
CGoStringFunc g_cgoRunFromJson = nullptr;
CGoStopFunc g_cgoStop = nullptr;
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

const char* BASE64_TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string LastMessage() { std::lock_guard<std::mutex> lock(g_messageMu); return g_lastMessage; }
void SetLastMessage(const std::string& value) { std::lock_guard<std::mutex> lock(g_messageMu); g_lastMessage = value; }

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
    int fd;
    int32_t token = 0;
    std::atomic<int> taken{0};
    ProtectLease lease;
    explicit ProtectWaiter(int hold) : fd(hold), lease(hold) {}
};

void MarkPoisoned(const std::string& why);
constexpr size_t MAX_PROTECT_PENDING = 128;

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

void ForgetCompletedProtect(const std::shared_ptr<ProtectWaiter>& waiter)
{
    std::lock_guard<std::mutex> lock(g_protectMu);
    if (!waiter->lease.Done()) return;
    g_protectWaiters.erase(std::remove(g_protectWaiters.begin(), g_protectWaiters.end(), waiter),
        g_protectWaiters.end());
}

void ProtectCallJs(napi_env env, napi_value jsCb, void* context, void* data)
{
    (void)context;
    std::unique_ptr<ProtectCall> call(static_cast<ProtectCall*>(data));
    if (!call || !call->waiter || !call->waiter->lease.Available()) return;
    if (env == nullptr || jsCb == nullptr) {
        call->waiter->lease.Retire();
        ForgetCompletedProtect(call->waiter);
        return;
    }
    napi_value undefined = nullptr, fdVal = nullptr, tokenVal = nullptr, result = nullptr;
    napi_get_undefined(env, &undefined);
    napi_create_int32(env, call->fd, &fdVal);
    napi_create_int32(env, call->token, &tokenVal);
    napi_value argv[2] = { fdVal, tokenVal };
    const napi_status st = napi_call_function(env, undefined, jsCb, 2, argv, &result);
    if (st != napi_ok) {
        bool pending = false;
        napi_is_exception_pending(env, &pending);
        if (pending) { napi_value exc = nullptr; napi_get_and_clear_last_exception(env, &exc); }
        // JS may have claimed and initiated protect before throwing. An
        // exception is not a platform ACK and cannot release that descriptor.
        if (call->waiter->lease.Retire()) MarkPoisoned("protect callback failed with borrowed fd");
        ForgetCompletedProtect(call->waiter);
    }
}

void AbortProtectTsfnLocked()
{
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        for (auto it = g_protectWaiters.begin(); it != g_protectWaiters.end();) {
            if ((*it)->lease.Retire()) {
                // Cancellation retires authority, not the platform borrow.
                // Its bounded Wait/real ACK decides quarantine after grace.
                ++it;
            } else { it = g_protectWaiters.erase(it); }
        }
    }
    if (g_protectTsfn == nullptr) return;
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
        if (tsfn != nullptr) {
            const napi_status acquiredStatus = napi_acquire_threadsafe_function(tsfn);
            if (acquiredStatus != napi_ok) {
                if (acquiredStatus == napi_closing) g_protectTsfn = nullptr;
                tsfn = nullptr;
            }
        }
    }
    if (tsfn == nullptr) {
        LogWarn(std::string("protect tsfn missing fd=") + std::to_string(fd));
        return -1;
    }
    ProtectCallbackLease acquired(tsfn, [](void* handle) {
        napi_release_threadsafe_function(static_cast<napi_threadsafe_function>(handle), napi_tsfn_release);
    });
    std::shared_ptr<ProtectWaiter> waiter;
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        if (g_nativePoisoned.load() || g_protectWaiters.size() >= MAX_PROTECT_PENDING) {
            // Do not allocate another lease once bounded storage is exhausted.
            return -1;
        }
        const int hold = dup(fd);
        if (hold < 0) return -1; // acquired's destructor releases the TSFN ref.
        try { waiter = std::make_shared<ProtectWaiter>(hold); }
        catch (...) { close(hold); return -1; }
        int32_t token = g_protectSeq.fetch_add(1);
        if (token <= 0) { g_protectSeq.store(1); token = g_protectSeq.fetch_add(1); }
        waiter->token = token;
        try { g_protectWaiters.push_back(waiter); }
        catch (...) { return -1; } // queued lease destructor owns the duplicate
    }
    auto* call = new (std::nothrow) ProtectCall();
    if (call == nullptr) {
        waiter->lease.Retire(); ForgetCompletedProtect(waiter); return -1;
    }
    call->fd = waiter->fd; call->token = waiter->token; call->waiter = waiter;
    g_protectQueued.fetch_add(1);
    const napi_status callSt = napi_call_threadsafe_function(tsfn, call, napi_tsfn_nonblocking);
    if (callSt != napi_ok) {
        if (callSt == napi_closing) {
            acquired.Closing();
            std::lock_guard<std::mutex> lock(g_tsfnMu);
            if (g_protectTsfn == tsfn) g_protectTsfn = nullptr;
        }
        delete call;
        waiter->lease.Retire(); ForgetCompletedProtect(waiter);
        return -1;
    }
    bool retained = false;
    const int rc = waiter->lease.Wait(kProtectTimeoutMs, kProtectClaimedGraceMs, &retained);
    if (retained) {
        // A platform Promise with no ACK cannot safely be force-closed. Bound
        // exposure to this process and forbid reuse; VPN supervisor cleans up
        // and exits the poisoned process. Until then the registry owns the fd.
        g_protectTimeout.fetch_add(1);
        MarkPoisoned("protect ACK deadline exceeded; retained fd, restart forbidden");
    } else {
        // ACK is completion (including an explicit API rejection), not success.
        // Cancellation and an API error must not be labelled a timeout.
        if (waiter->lease.Acknowledged()) g_protectAcked.fetch_add(1);
        if (waiter->lease.TimedOut()) g_protectTimeout.fetch_add(1);
        ForgetCompletedProtect(waiter);
    }
    return rc;
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
        env, args[0], nullptr, resourceName, MAX_PROTECT_PENDING, 1, nullptr, nullptr, nullptr, ProtectCallJs, &tsfn);
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
    size_t argc = 2; napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return CreateInt32(env, 0);
    const int fd = GetIntArg(env, args[0]); const int32_t token = GetIntArg(env, args[1]);
    std::lock_guard<std::mutex> lock(g_protectMu);
    for (const auto& waiter : g_protectWaiters) {
        if (waiter->fd == fd && waiter->token == token)
            return CreateInt32(env, waiter->lease.Claim() ? 1 : 0);
    }
    return CreateInt32(env, 0);
}

napi_value AckProtectFd(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return CreateInt32(env, -1);
    const int fd = GetIntArg(env, args[0]), rc = GetIntArg(env, args[1]);
    const int32_t token = GetIntArg(env, args[2]);
    std::lock_guard<std::mutex> lock(g_protectMu);
    for (auto it = g_protectWaiters.begin(); it != g_protectWaiters.end(); ++it) {
        if ((*it)->fd == fd && (*it)->token == token) {
            const bool completed = (*it)->lease.Complete(rc);
            g_protectWaiters.erase(it);
            return CreateInt32(env, completed ? 0 : -1);
        }
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
    SetLastMessage(why);
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
    SetLastMessage(message);
    if (ok) {
        LogInfo(message);
    } else {
        LogError(message);
    }
    return result;
}

// Like CreateResult but does not mutate LastMessage() or log. Used by the
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

bool LoadXrayCore(std::string& message)
{
    if (g_xrayHandle != nullptr) { return true; }
    PromoteProtectSymbol();
    void* handle = dlopen(ExecPath(XRAY_CORE_LIB).c_str(), RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) { handle = dlopen(XRAY_CORE_LIB, RTLD_NOW | RTLD_LOCAL); }
    if (handle == nullptr) {
        const char* error = dlerror();
        message = std::string("libXray load failed: ") + (error ? error : "unknown error");
        return false;
    }
    auto run = reinterpret_cast<CGoStringFunc>(dlsym(handle, "CGoRunXrayFromJSON"));
    auto stop = reinterpret_cast<CGoStopFunc>(dlsym(handle, "CGoStopXray"));
    auto hello = reinterpret_cast<CGoVersionFunc>(dlsym(handle, "CGoHello"));
    if (run == nullptr || stop == nullptr || hello == nullptr) {
        message = "libXray does not match the pinned CGo ABI";
        dlclose(handle);
        return false;
    }
    char* warmup = hello();
    if (warmup == nullptr) {
        message = "libXray warmup failed";
        return false;
    }
    std::free(warmup);
    g_cgoRunFromJson = run;
    g_cgoStop = stop;
    g_xrayHandle = handle;
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

constexpr size_t GO_WORKER_STACK = 8 * 1024 * 1024;
constexpr int NATIVE_STOP_TIMEOUT_MS = 4000;
constexpr int NATIVE_START_TIMEOUT_MS = 15000;

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

pangolin::FileLeases g_userDataLeases;
napi_value AcquireUserDataLease(napi_env env, napi_callback_info info) {
    size_t argc=1; napi_value args[1]={nullptr}; napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    return CreateInt32(env,argc==1?g_userDataLeases.acquire(GetStringArg(env,args[0])):0);
}
napi_value ReleaseUserDataLease(napi_env env, napi_callback_info info) {
    size_t argc=1; napi_value args[1]={nullptr}; napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    return CreateBool(env,argc==1 && g_userDataLeases.release(GetIntArg(env,args[0])));
}

napi_value CompareReplaceText(napi_env env, napi_callback_info info)
{
    size_t argc=3; napi_value args[3]={nullptr,nullptr,nullptr};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=3) return CreateResultQuiet(env,false,"missing compare/replace arguments");
    std::string error;
    const int rc=pangolin::CompareReplace(GetStringArg(env,args[0]),GetStringArg(env,args[1]),GetStringArg(env,args[2]),error);
    return CreateResultQuiet(env,rc==0,error);
}

napi_value MonotonicMillis(napi_env env, napi_callback_info info)
{
    (void)info;
    const auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    return CreateInt64(env,ms);
}

napi_value SystemBootId(napi_env env, napi_callback_info info)
{
    (void)info;
    char buf[80]={};
    int fd=open("/proc/sys/kernel/random/boot_id",O_RDONLY|O_CLOEXEC);
    if(fd<0) return CreateString(env,"");
    ssize_t n=read(fd,buf,sizeof(buf)-1); close(fd);
    std::string id=n>0?std::string(buf,static_cast<size_t>(n)):"";
    while(!id.empty() && (id.back()=='\n' || id.back()=='\r'))id.pop_back();
    return CreateString(env,id);
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
    if (!LoadXrayCore(job->message)) { job->ok = false; return false; }
    char* raw = g_cgoStop();
    if (raw == nullptr) {
        job->ok = false; job->message = "CGoStopXray returned null"; return false;
    }
    const std::string response(raw);
    std::free(raw);
    job->ok = ResponseOk(response, job->message);
    if (job->ok) { job->message = "Xray core stopped."; }
    return job->ok;
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
    {
        std::lock_guard<std::mutex> lock(job->notify.notifyMu);
        reply->deferred = static_cast<napi_deferred>(job->notify.deferred);
        reply->tsfn = static_cast<napi_threadsafe_function>(job->notify.tsfn);
    }
    reply->job = job;
    reply->ok = ok;
    reply->message = message;
    struct SettleUser {
        std::shared_ptr<XrayStartJob> job;
    } user;
    user.job = job;
    XraySettleHooks hooks{};
    hooks.dispatch = [](void* tsfn, void* payload, void* /*user*/) -> int {
        auto* queued = static_cast<XrayStartJsReply*>(payload);
        queued->deferred = static_cast<napi_deferred>(queued->job->notify.deferred);
        queued->tsfn = static_cast<napi_threadsafe_function>(tsfn);
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
            MarkPoisoned("xray start failed with live socks; refuse reuse, owner cleanup required");
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
    std::string message;
    if (!LoadXrayCore(message)) {
        FinishXrayStartJob(job, false, message);
        return nullptr;
    }
    setenv("XRAY_LOCATION_ASSET", job->workDir.c_str(), 1);
    std::ostringstream req;
    req << "{\"datDir\":\"" << JsonEscape(job->workDir)
        << "\",\"configJSON\":\"" << JsonEscape(job->config) << "\"}";
    std::string encoded = Base64Encode(req.str());
    char* raw = g_cgoRunFromJson(const_cast<char*>(encoded.c_str()));
    if (raw == nullptr) {
        FinishXrayStartJob(job, false, "CGoRunXrayFromJSON returned null");
        return nullptr;
    }
    const std::string response(raw);
    std::free(raw);
    if (!ResponseOk(response, message)) {
        FinishXrayStartJob(job, false, message);
        return nullptr;
    }
    FinishXrayStartJob(job, true, "Xray core started.");
    return nullptr;
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
#if defined(PANGOLIN_ENABLE_FAULT_INJECTION)
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
#endif
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
        return CreateResult(env, false, LastMessage(), static_cast<int64_t>(permit.ownerSeq));
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
                return CreateResult(env, false, LastMessage());
            }
        }
    }
    if (g_xrayCore.running.load() && g_xrayCore.liveOwner.load() == 0) {
        MarkPoisoned("xray running without owner");
        return CreateResult(env, false, LastMessage());
    }
    const XrayStopPermit permit = XrayAcquireStopPermit(g_xrayCore, requiredOwner);
    if (permit.allowPhysicalStop) {
        return DispatchPermittedXrayStop(env, permit);
    }
    if (permit.alreadyInFlight || g_xrayCore.running.load() || XrayStartBlockedByStop(g_xrayCore)) {
        if (!WaitCoreIdleLocked(NATIVE_STOP_TIMEOUT_MS)) {
            if (g_xrayCore.running.load() || XrayStartBlockedByStop(g_xrayCore)) {
                MarkPoisoned("Xray stop still pending after wait");
                return CreateResult(env, false, LastMessage());
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
    return CreateResult(env, false, LastMessage());
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
        if (g_hevStats != nullptr) {
            // hev_socks5_tunnel_stats(tx_pkts, tx_bytes, rx_pkts, rx_bytes)，相对 TUN 网卡：
            // tx=从 TUN 收到上行、rx=回写 TUN 的下行。若真机方向相反，调换这两行即可。
            size_t txPackets = 0;
            size_t txBytes = 0;
            size_t rxPackets = 0;
            size_t rxBytes = 0;
            g_hevStats(&txPackets, &txBytes, &rxPackets, &rxBytes);
            g_uploadBytes.store(static_cast<int64_t>(txBytes));
            g_downloadBytes.store(static_cast<int64_t>(rxBytes));
        }
    }
    napi_set_named_property(env, result, "uploadBytes", CreateInt64(env, g_uploadBytes.load()));
    napi_set_named_property(env, result, "downloadBytes", CreateInt64(env, g_downloadBytes.load()));
    napi_set_named_property(env, result, "xrayRunning", CreateBool(env, g_xrayCore.running.load()));
    napi_set_named_property(env, result, "xrayStarting", CreateBool(env, g_xrayStarting.load()));
    napi_set_named_property(env, result, "xrayOwnerSeq", CreateInt64(env, g_xrayCore.liveOwner.load()));
    napi_set_named_property(env, result, "xrayStopPending", CreateBool(env, XrayStartBlockedByStop(g_xrayCore)));
    {
        std::lock_guard<std::mutex> lock(g_protectMu);
        napi_set_named_property(env, result, "protectPending", CreateInt64(env, g_protectWaiters.size()));
    }

    napi_set_named_property(env, result, "poisoned", CreateBool(env, g_nativePoisoned.load()));
    napi_set_named_property(env, result, "tunRunning", CreateBool(env, g_tunRunning.load()));
    napi_set_named_property(env, result, "lastMessage", CreateString(env, LastMessage()));
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
    if (g_hevDiagSnapshot != nullptr && g_tunRunning.load()) {
        if (g_hevDiagSnapshot(hevDiag, sizeof(hevDiag)) < 0) {
            hevDiag[0] = '\0';
        }
    }
    napi_set_named_property(env, result, "hevDiagnostics", CreateString(env, hevDiag));
    return result;
}

// 启动 hev-socks5-tunnel 引擎：把 TUN fd 的流量按 yaml 配置转发到本地 SOCKS。与
// HEV 的 main 阻塞，放到独立线程；停止确认后才允许重启。
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
        SetLastMessage(message);
        LogError(message);
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

        g_hevThread = std::thread([start, configYaml, tunFd, life]() {
            const int rc = start(reinterpret_cast<const unsigned char*>(configYaml.c_str()),
                static_cast<unsigned int>(configYaml.size()), tunFd);
            std::lock_guard<std::mutex> hevLock(g_hevMu);
            if (g_hevLife.load() != life) {
                return;
            }
            g_hevMainRc.store(rc);
            g_tunRunning.store(false);

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

            g_tunRunning.store(false);
            return CreateResult(env, false, "hev tun failed during init");
        }
        if (rc != -2) {
            std::lock_guard<std::mutex> hevLock(g_hevMu);
            if (g_hevThread.joinable()) {
                g_hevThread.join();
            }

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

            g_tunRunning.store(false);
            return CreateResult(env, false, "hev tun exited before running");
        }
        g_tunRunning.store(true);

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

        g_tunRunning.store(false);
    }
    job->ok = true;
    job->message = "hev tun stopped.";
    job->finished.store(true);
    return nullptr;
}

napi_value StopHevTun(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_nativePoisoned.load()) {
        return CreateResult(env, false, "native poisoned; refuse hev stop restart path");
    }
    bool alreadyStopped = false;
    bool hevThreadLive = false;
    {
        std::lock_guard<std::mutex> hevLock(g_hevMu);
        hevThreadLive = g_hevThread.joinable();
        if (!g_tunRunning.load() && !hevThreadLive) {
            alreadyStopped = true;
        }
    }
    if (alreadyStopped) {
        return CreateResult(env, true, "tun data plane already stopped.");
    }
    {
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
            return CreateResult(env, false, LastMessage());
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
}

static napi_value Init(napi_env env, napi_value exports)
{
    RegisterAppFlowRouter(env, exports);
    napi_property_descriptor desc[] = {
        { "createSocksSession", nullptr, CreateSocksSession, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startXray", nullptr, StartXray, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopXray", nullptr, StopXray, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopXrayOwned", nullptr, StopXrayOwned, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getStats", nullptr, GetStats, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startHevTun", nullptr, StartHevTun, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopHevTun", nullptr, StopHevTun, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "acquireUserDataLease", nullptr, AcquireUserDataLease, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "releaseUserDataLease", nullptr, ReleaseUserDataLease, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "compareReplaceText", nullptr, CompareReplaceText, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "monotonicMillis", nullptr, MonotonicMillis, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "systemBootId", nullptr, SystemBootId, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "atomicReplaceFile", nullptr, AtomicReplaceFile, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "abortPoisonedNative", nullptr, AbortPoisonedNative, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setProtectCallback", nullptr, SetProtectCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "clearProtectCallback", nullptr, ClearProtectCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
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
