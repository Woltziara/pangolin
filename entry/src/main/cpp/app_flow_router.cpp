#include "app_flow_router.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <map>
#include <mutex>
#include <memory>

namespace {
struct Pending {
    uint64_t id;
    AppFlowTuple tuple;
    int writer;
    ~Pending() { if (writer >= 0) close(writer); }
};
std::mutex mu;
std::map<uint64_t, std::shared_ptr<Pending>> pending;
napi_threadsafe_function callback = nullptr;
napi_env owner = nullptr;
uint64_t nextId = 0; // Never reused, including across callbacks / VPN generations.
bool deniedWhileStopping = false;
constexpr size_t MAX_PENDING = 128;

napi_value Number(napi_env env, double value) {
    napi_value out; napi_create_double(env, value, &out); return out;
}
void SetNumber(napi_env env, napi_value obj, const char* key, double value) {
    napi_set_named_property(env, obj, key, Number(env, value));
}
void SetAddress(napi_env env, napi_value obj, const char* key, const uint8_t* addr, int family) {
    char text[INET6_ADDRSTRLEN] = {};
    inet_ntop(family == 4 ? AF_INET : AF_INET6, addr, text, sizeof(text));
    napi_value value; napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, obj, key, value);
}
void Dispatch(napi_env env, napi_value fn, void*, void* data) {
    std::unique_ptr<std::shared_ptr<Pending>> holder(static_cast<std::shared_ptr<Pending>*>(data));
    if (!env || !fn) return;
    const auto job = *holder;
    {
        std::lock_guard<std::mutex> lock(mu);
        if (pending.find(job->id) == pending.end()) return;
    }
    napi_value arg; napi_create_object(env, &arg);
    SetNumber(env, arg, "requestId", job->id);
    SetNumber(env, arg, "protocol", job->tuple.protocol);
    SetNumber(env, arg, "family", job->tuple.family);
    SetNumber(env, arg, "sourcePort", job->tuple.source_port);
    SetNumber(env, arg, "destinationPort", job->tuple.destination_port);
    SetAddress(env, arg, "sourceAddress", job->tuple.source, job->tuple.family);
    SetAddress(env, arg, "destinationAddress", job->tuple.destination, job->tuple.family);
    napi_value receiver, result;
    napi_get_undefined(env, &receiver);
    if (napi_call_function(env, receiver, fn, 1, &arg, &result) != napi_ok) AppFlowCancel(job->id, nullptr);
}
void Clear(napi_env env, bool stopping) {
    std::lock_guard<std::mutex> lock(mu);
    if (owner && env != owner) return;
    deniedWhileStopping = stopping && (callback != nullptr || deniedWhileStopping);
    for (auto& entry : pending) {
        if (entry.second->writer >= 0) close(entry.second->writer);
        entry.second->writer = -1;
    }
    pending.clear();
    if (callback) napi_release_threadsafe_function(callback, napi_tsfn_abort);
    callback = nullptr;
    owner = nullptr;
}
void Cleanup(void* env) { Clear(static_cast<napi_env>(env), true); }
napi_value SetCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_valuetype type = napi_undefined;
    if (argc == 1) napi_typeof(env, args[0], &type);
    if (type != napi_function) return Number(env, -1);
    {
        std::lock_guard<std::mutex> lock(mu);
        if (owner && owner != env) return Number(env, -1);
    }
    Clear(env, true);
    napi_value name; napi_create_string_utf8(env, "app-flow-owner", NAPI_AUTO_LENGTH, &name);
    std::lock_guard<std::mutex> lock(mu);
    napi_threadsafe_function next = nullptr;
    if (napi_create_threadsafe_function(env, args[0], nullptr, name, MAX_PENDING, 1,
        nullptr, nullptr, nullptr, Dispatch, &next) != napi_ok) return Number(env, -1);
    callback = next; owner = env; deniedWhileStopping = false;
    return Number(env, 0);
}
napi_value ClearCallback(napi_env env, napi_callback_info) {
    Clear(env, true); return Number(env, 0);
}
napi_value Ack(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double value = 0; int32_t status = -1, port = 0;
    if (argc != 3 || napi_get_value_double(env, args[0], &value) != napi_ok ||
        value <= 0 || value > 9007199254740991.0 ||
        napi_get_value_int32(env, args[1], &status) != napi_ok ||
        napi_get_value_int32(env, args[2], &port) != napi_ok) return Number(env, -1);
    std::lock_guard<std::mutex> lock(mu);
    auto it = pending.find(static_cast<uint64_t>(value));
    if (env != owner || it == pending.end()) return Number(env, -1);
    if (status > 1 || (status == 0 && (port < 1 || port > 65535))) status = -1;
    const AppFlowReply reply{status, static_cast<uint16_t>(status == 0 ? port : 0), 0};
    // send and close are under the same lock as cancel: no fd-reuse race.
    const ssize_t sent = send(it->second->writer, &reply, sizeof(reply), MSG_NOSIGNAL);
    close(it->second->writer); it->second->writer = -1;
    pending.erase(it);
    return Number(env, sent == sizeof(reply) ? 0 : -1);
}
}

bool AppFlowEnabled() {
    std::lock_guard<std::mutex> lock(mu); return callback != nullptr;
}
int AppFlowBegin(const AppFlowTuple* tuple, uint64_t* id, void*) {
    if (!tuple || !id || (tuple->family != 4 && tuple->family != 6) ||
        (tuple->protocol != 6 && tuple->protocol != 17) || !tuple->source_port || !tuple->destination_port) return -1;
    std::lock_guard<std::mutex> lock(mu);
    if (!callback) return deniedWhileStopping ? -1 : -2;
    if (pending.size() >= MAX_PENDING || nextId >= 9007199254740991ULL) return -1;
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -1;
    for (int fd : fds) {
        if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
            close(fds[0]); close(fds[1]); return -1;
        }
    }
    auto job = std::make_shared<Pending>();
    job->id = ++nextId; job->tuple = *tuple; job->writer = fds[1];
    pending.emplace(job->id, job);
    auto* data = new std::shared_ptr<Pending>(job);
    // The sole TSFN thread ref is owned by callback; mu excludes release.
    if (napi_call_threadsafe_function(callback, data, napi_tsfn_nonblocking) != napi_ok) {
        delete data; pending.erase(job->id); close(fds[0]); return -1;
    }
    *id = job->id;
    return fds[0];
}
void AppFlowCancel(uint64_t id, void*) {
    std::lock_guard<std::mutex> lock(mu);
    auto it = pending.find(id);
    if (it == pending.end()) return;
    close(it->second->writer); it->second->writer = -1;
    pending.erase(it);
}
void RegisterAppFlowRouter(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"setAppRouteCallback", nullptr, SetCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearAppRouteCallback", nullptr, ClearCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ackAppRoute", nullptr, Ack, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    napi_add_env_cleanup_hook(env, Cleanup, env);
}
