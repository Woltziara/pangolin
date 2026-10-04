#include "protect_lease.h"
#include <cassert>
#include <fcntl.h>
#include <future>
#include <sys/socket.h>
#include <thread>
#include <iostream>

static void testClaimBeforeTimeout() {
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    const int fd = dup(pair[0]); assert(fd >= 0);
    ProtectLease lease(fd);
    // Deterministic barrier: timeout can only run AFTER platform claim.
    std::promise<void> claimed, retire;
    auto first = claimed.get_future(); auto second = retire.get_future();
    std::thread platform([&] { assert(lease.Claim()); claimed.set_value(); second.wait();
        assert(fcntl(fd, F_GETFD) >= 0); assert(lease.Complete(0)); });
    first.wait(); bool retained = false;
    assert(lease.Wait(0, 0, &retained) == -1 && retained);
    assert(fcntl(fd, F_GETFD) >= 0); // timeout never closes platform's lease
    assert(lease.Retire()); assert(fcntl(fd, F_GETFD) >= 0);
    retire.set_value(); platform.join();
    assert(fcntl(fd, F_GETFD) == -1);
    // Force reuse of the exact descriptor number. A second ACK/destructor
    // must not affect it. This exercises the shipped ownership implementation.
    assert(dup2(pair[0], fd) == fd);
    assert(!lease.Complete(0)); assert(!lease.Retire());
    assert(fcntl(fd, F_GETFD) >= 0);
    close(fd); close(pair[0]); close(pair[1]);
}
static void testTimeoutBeforeClaim() {
    int pair[2]; assert(pipe(pair) == 0); const int fd = dup(pair[0]);
    ProtectLease lease(fd); bool retained = true;
    assert(lease.Wait(0, 0, &retained) == -1 && !retained);
    assert(dup2(pair[0], fd) == fd);
    assert(!lease.Claim()); assert(!lease.Complete(0));
    assert(fcntl(fd, F_GETFD) >= 0);
    close(fd); close(pair[0]); close(pair[1]);
}
static void testCancelAndAck() {
    int pair[2]; assert(pipe(pair) == 0); const int fd = dup(pair[0]);
    ProtectLease lease(fd); assert(lease.Claim()); assert(lease.Retire());
    assert(lease.Complete(0)); bool retained;
    assert(lease.Wait(0, 0, &retained) == -1 && !retained); // late success is failure
    close(pair[0]); close(pair[1]);
}
static void testCallbackBalance() {
    int releases = 0;
    auto release = [](void* p) { ++*static_cast<int*>(p); };
    { ProtectCallbackLease acquired(&releases, release); /* actual early-return/dup-failure path */ }
    assert(releases == 1);
    { ProtectCallbackLease acquired(&releases, release); acquired.Closing(); }
    assert(releases == 1); // closing handle cannot be reused
}
int main() { testClaimBeforeTimeout(); testTimeoutBeforeClaim(); testCancelAndAck(); testCallbackBalance();
    std::cout << "PASS production ProtectLease: claim/timeout barriers, exact fd reuse, late ACK, TSFN balance\n";
}
