// Host boundary shim; all ownership, timeout, registry, dup and ACK logic is
// the byte-for-byte production region extracted by run_protect_bridge.py.
#include <node_api.h>
#include "protect_lease.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <vector>
#include <string>
#include <functional>
#include <iostream>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <thread>
#include <future>

struct napi_env__ {};
struct napi_value__ { int n = 0; bool fn = false; };
struct napi_callback_info__ { std::vector<napi_value> args; };
struct napi_threadsafe_function__ {
    std::atomic<int> refs{1}; bool closing = false; size_t capacity = 0;
    std::mutex mu; std::condition_variable cv; std::vector<void*> queued;
};
static napi_env__ envObject;
static napi_env env = &envObject;
static napi_threadsafe_function__ fake;
static std::vector<std::unique_ptr<napi_value__>> values;
static std::mutex valuesMu;
static std::function<void(int,int)> platform;
static int platformCalls = 0;
static int capturedFd = -1, capturedToken = 0;
static std::atomic_bool g_nativePoisoned{false};
static napi_value val(int n, bool fn=false) {
    std::lock_guard<std::mutex> lock(valuesMu);
    auto v = std::make_unique<napi_value__>(); v->n=n; v->fn=fn;
    auto p=v.get(); values.push_back(std::move(v)); return p;
}
void LogInfo(const std::string&) {} void LogWarn(const std::string&) {}
void MarkPoisoned(const std::string&) { g_nativePoisoned.store(true); }
napi_value CreateInt32(napi_env, int n) { return val(n); }
int32_t GetIntArg(napi_env, napi_value v) { return v->n; }
#include "protect-production.inc"

extern "C" {
napi_status napi_get_cb_info(napi_env,napi_callback_info info,size_t* argc,napi_value* out,napi_value*,void**) {
    *argc=std::min(*argc,info->args.size()); for(size_t i=0;i<*argc;++i)out[i]=info->args[i];return napi_ok;
}
napi_status napi_typeof(napi_env,napi_value v,napi_valuetype* type) { *type=v->fn?napi_function:napi_number;return napi_ok; }
napi_status napi_create_string_utf8(napi_env,const char*,size_t,napi_value* v) { *v=val(0);return napi_ok; }
napi_status napi_get_undefined(napi_env,napi_value* v) { *v=val(0);return napi_ok; }
napi_status napi_create_int32(napi_env,int32_t n,napi_value* v) { *v=val(n);return napi_ok; }
napi_status napi_is_exception_pending(napi_env,bool* pending) { *pending=false;return napi_ok; }
napi_status napi_get_and_clear_last_exception(napi_env,napi_value* v) { *v=val(0);return napi_ok; }
napi_status napi_call_function(napi_env,napi_value,napi_value,size_t argc,const napi_value* args,napi_value* v) {
    assert(argc==2); ++platformCalls; platform(args[0]->n,args[1]->n); *v=val(0);return napi_ok;
}
napi_status napi_acquire_threadsafe_function(napi_threadsafe_function f) {
    if(f->closing)return napi_closing;f->refs.fetch_add(1);return napi_ok;
}
napi_status napi_release_threadsafe_function(napi_threadsafe_function f,napi_threadsafe_function_release_mode m) {
    assert(f->refs.load()>0);if(m==napi_tsfn_abort)f->closing=true;f->refs.fetch_sub(1);return napi_ok;
}
napi_status napi_call_threadsafe_function(napi_threadsafe_function f,void* data,napi_threadsafe_function_call_mode) {
    std::lock_guard<std::mutex> lock(f->mu);if(f->closing)return napi_closing;
    if(f->queued.size()>=f->capacity)return napi_queue_full;
    f->queued.push_back(data);f->cv.notify_all();return napi_ok;
}
napi_status napi_create_threadsafe_function(napi_env,napi_value,napi_value,napi_value,size_t max,size_t refs,
    void*,napi_finalize,void*,napi_threadsafe_function_call_js,napi_threadsafe_function* f) {
    fake.capacity=max;fake.refs=static_cast<int>(refs);fake.closing=false;*f=&fake;return napi_ok;
}
}
static int claim(int fd,int token) { napi_callback_info__ info{{val(fd),val(token)}};return ClaimProtectFd(env,&info)->n; }
static int ack(int fd,int token,int rc) { napi_callback_info__ info{{val(fd),val(rc),val(token)}};return AckProtectFd(env,&info)->n; }
static void setup() {
    assert(g_protectWaiters.empty());assert(fake.queued.empty());
    g_nativePoisoned=false; platformCalls=0;capturedFd=-1;
    napi_callback_info__ info{{val(0,true)}};assert(SetProtectCallback(env,&info)->n==1);
    assert(fake.capacity==MAX_PROTECT_PENDING);
    platform=[](int fd,int token){ assert(claim(fd,token)==1);capturedFd=fd;capturedToken=token; };
}
static void waitQueued() { std::unique_lock<std::mutex> l(fake.mu);
    assert(fake.cv.wait_for(l,std::chrono::seconds(2),[]{return !fake.queued.empty();})); }
static void dispatch(bool alive=true) { void* data;
    { std::lock_guard<std::mutex> l(fake.mu);assert(!fake.queued.empty());data=fake.queued.front();fake.queued.erase(fake.queued.begin()); }
    ProtectCallJs(alive?env:nullptr,alive?val(0,true):nullptr,nullptr,data);
}
static void clear() { ClearProtectCallback(env,nullptr); }
static void claimCancelReuse() {
    setup();int pair[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,pair)==0);
    auto work=std::async(std::launch::async,[&]{return hey_protect_socket(pair[0]);});
    waitQueued();dispatch();assert(capturedFd>=0);const int old=capturedFd;
    clear();assert(work.get()==-1);assert(g_nativePoisoned);assert(g_protectWaiters.size()==1);
    assert(fcntl(old,F_GETFD)>=0);assert(ack(old,capturedToken,0)==0);assert(g_protectWaiters.empty());
    assert(dup2(pair[0],old)==old);assert(ack(old,capturedToken,0)==-1);assert(fcntl(old,F_GETFD)>=0);
    close(old);close(pair[0]);close(pair[1]);assert(fake.refs==0);
}
static void cancelledBorrowCompletesWithinGrace() {
    setup();int pair[2];assert(pipe(pair)==0);
    auto work=std::async(std::launch::async,[&]{return hey_protect_socket(pair[0]);});waitQueued();dispatch();
    const int old=capturedFd;clear();assert(fcntl(old,F_GETFD)>=0);
    // Real ACK after cancellation retires only its own duplicate, not a new
    // connection, and must not force process quarantine on an ordinary stop.
    assert(ack(old,capturedToken,0)==0);assert(work.get()==-1);assert(!g_nativePoisoned);
    assert(g_protectWaiters.empty());close(pair[0]);close(pair[1]);assert(fake.refs==0);
}
static void timeoutBeforeJs() {
    setup();int pair[2];assert(pipe(pair)==0);
    auto work=std::async(std::launch::async,[&]{return hey_protect_socket(pair[0]);});waitQueued();
    const int old=static_cast<ProtectCall*>(fake.queued.front())->fd;
    assert(work.get()==-1);assert(g_protectWaiters.empty());assert(dup2(pair[0],old)==old);
    dispatch();assert(platformCalls==0);assert(fcntl(old,F_GETFD)>=0);
    clear();close(old);close(pair[0]);close(pair[1]);assert(fake.refs==0);
}
static void realDupFailure() {
    setup();int pair[2];assert(pipe(pair)==0);struct rlimit limit;assert(getrlimit(RLIMIT_NOFILE,&limit)==0);
    const auto before=fake.refs.load();struct rlimit low=limit;low.rlim_cur=0;
    assert(setrlimit(RLIMIT_NOFILE,&low)==0);const int rc=hey_protect_socket(pair[0]);assert(setrlimit(RLIMIT_NOFILE,&limit)==0);
    assert(rc==-1);assert(fake.refs==before);assert(g_protectWaiters.empty());assert(fake.queued.empty());
    clear();close(pair[0]);close(pair[1]);
}
static void unresolvedPlatformBound() {
    setup();int pair[2];assert(pipe(pair)==0);
    auto work=std::async(std::launch::async,[&]{return hey_protect_socket(pair[0]);});waitQueued();dispatch();
    const int old=capturedFd;assert(work.get()==-1);assert(g_nativePoisoned);assert(g_protectWaiters.size()==1);
    assert(fcntl(old,F_GETFD)>=0);const int refs=fake.refs;
    for(int i=0;i<200;++i)assert(hey_protect_socket(pair[0])==-1);
    assert(g_protectWaiters.size()==1 && fake.refs==refs && fake.queued.empty());
    // Late real completion is permitted to retire its own duplicate only.
    assert(ack(old,capturedToken,0)==0);assert(g_nativePoisoned); // never clear poison on late success
    clear();close(pair[0]);close(pair[1]);
}
static void registryCap() {
    setup();int pair[2];assert(pipe(pair)==0);
    for(size_t i=0;i<MAX_PROTECT_PENDING;++i)g_protectWaiters.push_back(std::make_shared<ProtectWaiter>(dup(pair[0])));
    const int refs=fake.refs;assert(hey_protect_socket(pair[0])==-1);assert(fake.refs==refs);
    assert(g_protectWaiters.size()==MAX_PROTECT_PENDING);clear();assert(g_protectWaiters.empty());close(pair[0]);close(pair[1]);
}
static void envClosingBeforeClaim() {
    setup();int pair[2];assert(pipe(pair)==0);
    auto work=std::async(std::launch::async,[&]{return hey_protect_socket(pair[0]);});waitQueued();dispatch(false);
    assert(work.get()==-1);assert(g_protectWaiters.empty());assert(platformCalls==0);clear();close(pair[0]);close(pair[1]);
}
int main() {
    claimCancelReuse();cancelledBorrowCompletesWithinGrace();timeoutBeforeJs();realDupFailure();unresolvedPlatformBound();registryCap();envClosingBeforeClaim();
    std::cout<<"PASS 7 production protect bridge scenarios: claim/cancel/reused FD; timeout before JS; real EMFILE/TSFN balance; unresolved API quarantine; registry cap; env closing\n";
}
