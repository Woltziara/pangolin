#include <atomic>
#include <cassert>
#include <thread>
#include <unistd.h>

struct Waiter {
    std::atomic<int> holdFd{-1};
};

static void release(Waiter& waiter)
{
    const int fd = waiter.holdFd.exchange(-1);
    if (fd >= 0) {
        close(fd);
    }
}

int main(void)
{
    int pipefd[2];
    assert(pipe(pipefd) == 0);
    close(pipefd[1]);
    Waiter waiter;
    waiter.holdFd.store(pipefd[0]);
    std::thread first([&] { release(waiter); });
    std::thread second([&] { release(waiter); });
    first.join();
    second.join();
    assert(waiter.holdFd.load() == -1);
    return 0;
}
