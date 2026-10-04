#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include <deque>
#include <map>
#include <string>
#include <vector>

#include <napi/native_api.h>

struct napi_env__ {};
struct napi_value__ {
  int type = napi_undefined;
  double number = 0;
  std::string text;
  std::map<std::string, napi_value> props;
};
struct napi_callback_info__ { std::vector<napi_value> args; };
struct napi_threadsafe_function__ {
  napi_env env = nullptr;
  napi_value js = nullptr;
  napi_threadsafe_function_call_js dispatch = nullptr;
  bool released = false;
  std::deque<void*> queued;
};

#include "../entry/src/main/cpp/app_flow_router.cpp"

namespace {
std::map<std::string, napi_callback> exported;
std::vector<napi_value> delivered;
std::vector<napi_threadsafe_function> functions;
napi_value MakeNumber(double value) { auto* out = new napi_value__(); out->type = 1; out->number = value; return out; }
napi_value MakeFunction() { auto* out = new napi_value__(); out->type = napi_function; return out; }
napi_value MakeString(const char* text) { auto* out = new napi_value__(); out->type = 2; out->text = text; return out; }
double NumberOf(napi_value value) { assert(value != nullptr); return value->number; }
napi_value Call(napi_callback callback, napi_env env, std::vector<napi_value> args) {
  napi_callback_info__ info; info.args = std::move(args); return callback(env, &info);
}
void Deliver(napi_threadsafe_function fn) {
  assert(!fn->queued.empty());
  void* data = fn->queued.front(); fn->queued.pop_front();
  fn->dispatch(fn->env, fn->js, nullptr, data);
}
AppFlowTuple Tuple() {
  AppFlowTuple tuple{};
  tuple.family = 4; tuple.protocol = 6; tuple.source_port = 17000; tuple.destination_port = 443;
  tuple.source[0] = 10; tuple.source[3] = 9;
  tuple.destination[0] = 1; tuple.destination[1] = 1; tuple.destination[2] = 1; tuple.destination[3] = 1;
  return tuple;
}
void AssertClosed(int fd) { char byte = 0; assert(read(fd, &byte, 1) == 0); close(fd); }
void Ack(napi_env env, uint64_t id, int status, int port, int expected = 0) {
  assert(NumberOf(Call(exported["ackAppRoute"], env, {MakeNumber(static_cast<double>(id)), MakeNumber(status), MakeNumber(port)})) == expected);
}
} // namespace

napi_status napi_create_double(napi_env, double value, napi_value* out) { *out = MakeNumber(value); return napi_ok; }
napi_status napi_set_named_property(napi_env, napi_value object, const char* key, napi_value value) { object->props[key] = value; return napi_ok; }
napi_status napi_create_string_utf8(napi_env, const char* value, size_t, napi_value* out) { *out = MakeString(value); return napi_ok; }
napi_status napi_create_object(napi_env, napi_value* out) { *out = new napi_value__(); return napi_ok; }
napi_status napi_get_undefined(napi_env, napi_value* out) { *out = new napi_value__(); return napi_ok; }
napi_status napi_call_function(napi_env, napi_value, napi_value, size_t argc, const napi_value* argv, napi_value* result) {
  assert(argc == 1); delivered.push_back(argv[0]); if (result) *result = nullptr; return napi_ok;
}
napi_status napi_release_threadsafe_function(napi_threadsafe_function fn, napi_threadsafe_function_release_mode) { fn->released = true; return napi_ok; }
napi_status napi_get_cb_info(napi_env, napi_callback_info info, size_t* argc, napi_value* argv, napi_value*, void**) {
  const size_t n = *argc < info->args.size() ? *argc : info->args.size();
  for (size_t i = 0; i < n; ++i) argv[i] = info->args[i];
  *argc = info->args.size(); return napi_ok;
}
napi_status napi_typeof(napi_env, napi_value value, napi_valuetype* out) { *out = value->type; return napi_ok; }
napi_status napi_create_threadsafe_function(napi_env env, napi_value js, napi_value, napi_value, size_t, size_t, void*, void*, void*, napi_threadsafe_function_call_js dispatch, napi_threadsafe_function* out) {
  auto* fn = new napi_threadsafe_function__(); fn->env = env; fn->js = js; fn->dispatch = dispatch; functions.push_back(fn); *out = fn; return napi_ok;
}
napi_status napi_get_value_double(napi_env, napi_value value, double* out) { *out = value->number; return value->type == 1 ? napi_ok : napi_invalid_arg; }
napi_status napi_get_value_int32(napi_env, napi_value value, int32_t* out) { *out = static_cast<int32_t>(value->number); return value->type == 1 ? napi_ok : napi_invalid_arg; }
napi_status napi_define_properties(napi_env, napi_value, size_t n, const napi_property_descriptor* descriptors) { for (size_t i = 0; i < n; ++i) exported[descriptors[i].utf8name] = descriptors[i].method; return napi_ok; }
napi_status napi_add_env_cleanup_hook(napi_env, napi_cleanup_hook, void*) { return napi_ok; }
napi_status napi_call_threadsafe_function(napi_threadsafe_function fn, void* data, napi_threadsafe_function_call_mode) { if (fn->released) return napi_generic_failure; fn->queued.push_back(data); return napi_ok; }

int main() {
  napi_env__ rawEnvA, rawEnvB; napi_env envA = &rawEnvA; napi_env envB = &rawEnvB; napi_value exports = nullptr;
  RegisterAppFlowRouter(envA, exports);
  assert(!AppFlowEnabled());
  assert(NumberOf(Call(exported["setAppRouteCallback"], envA, {MakeFunction()})) == 0);
  assert(AppFlowEnabled()); napi_threadsafe_function first = functions.back();

  AppFlowTuple tuple = Tuple(); uint64_t firstId = 0;
  const int firstFd = AppFlowBegin(&tuple, &firstId, nullptr);
  assert(firstFd >= 0 && firstId > 0 && (fcntl(firstFd, F_GETFL) & O_NONBLOCK) && (fcntl(firstFd, F_GETFD) & FD_CLOEXEC));
  Deliver(first);
  assert(delivered.size() == 1 && NumberOf(delivered.back()->props["requestId"]) == static_cast<double>(firstId));
  assert(NumberOf(delivered.back()->props["protocol"]) == 6 && NumberOf(delivered.back()->props["destinationPort"]) == 443);
  Ack(envA, firstId, 0, 34567);
  AppFlowReply reply{}; assert(read(firstFd, &reply, sizeof(reply)) == sizeof(reply)); close(firstFd);
  assert(reply.status == 0 && reply.socks_port == 34567 && reply.reserved == 0);

  uint64_t canceledId = 0; const int canceledFd = AppFlowBegin(&tuple, &canceledId, nullptr); assert(canceledFd >= 0);
  AppFlowCancel(canceledId, nullptr); AssertClosed(canceledFd); Deliver(first); Ack(envA, canceledId, 0, 1234, -1);

  uint64_t oldId = 0; const int oldFd = AppFlowBegin(&tuple, &oldId, nullptr); assert(oldFd >= 0);
  assert(NumberOf(Call(exported["clearAppRouteCallback"], envA, {})) == 0); AssertClosed(oldFd); assert(!AppFlowEnabled());
  assert(NumberOf(Call(exported["setAppRouteCallback"], envB, {MakeFunction()})) == 0); napi_threadsafe_function second = functions.back();
  uint64_t newId = 0; const int newFd = AppFlowBegin(&tuple, &newId, nullptr); assert(newFd >= 0 && newId != oldId);
  const size_t beforeLate = delivered.size(); Deliver(first); assert(delivered.size() == beforeLate);
  Ack(envB, oldId, 0, 4567, -1);
  char noWrite = 0; assert(read(newFd, &noWrite, 1) < 0);
  Deliver(second); Ack(envB, newId, 1, 0); assert(read(newFd, &reply, sizeof(reply)) == sizeof(reply)); close(newFd); assert(reply.status == 1 && reply.socks_port == 0);

  std::vector<int> capacityFds;
  for (size_t i = 0; i < 128; ++i) { uint64_t id = 0; int fd = AppFlowBegin(&tuple, &id, nullptr); assert(fd >= 0); capacityFds.push_back(fd); }
  uint64_t rejected = 0; assert(AppFlowBegin(&tuple, &rejected, nullptr) == -1);
  assert(NumberOf(Call(exported["clearAppRouteCallback"], envB, {})) == 0);
  for (int fd : capacityFds) { AssertClosed(fd); }
  while (!second->queued.empty()) Deliver(second);
  assert(AppFlowBegin(&tuple, &rejected, nullptr) == -1);
  return 0;
}
