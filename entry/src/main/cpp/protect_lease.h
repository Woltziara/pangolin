#pragma once

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <unistd.h>

// The duplicated descriptor belongs to this lease until Claim(), then it is
// also borrowed by the asynchronous platform API. Timeout is NOT cancellation
// of that API. Only its real ACK may release a claimed descriptor; otherwise
// the enclosing VPN process must be quarantined and terminated by its owner.
class ProtectLease {
public:
    enum class State { Queued, Claimed, RetiredClaimed, Complete, Revoked };
    explicit ProtectLease(int fd) : fd_(fd) {}
    ProtectLease(const ProtectLease&) = delete;
    ProtectLease& operator=(const ProtectLease&) = delete;
    ~ProtectLease() {
        std::lock_guard<std::mutex> lock(mu_);
        // Claimed leases stay in the registry until ACK/process exit. Never
        // use a destructor as permission to close a platform-borrowed fd.
        if (state_ != State::Claimed && state_ != State::RetiredClaimed) CloseLocked();
    }
    bool Claim() {
        std::lock_guard<std::mutex> lock(mu_);
        if (state_ != State::Queued) return false;
        state_ = State::Claimed;
        return true;
    }
    bool Available() const {
        std::lock_guard<std::mutex> lock(mu_);
        return state_ == State::Queued;
    }
    // Returns true if the platform may still borrow fd_. No fd is released in
    // that case. This transition is serialized with Claim() and Complete().
    bool Retire() {
        std::lock_guard<std::mutex> lock(mu_);
        if (state_ == State::Claimed) state_ = State::RetiredClaimed;
        else if (state_ == State::Queued) { state_ = State::Revoked; CloseLocked(); }
        cv_.notify_all();
        return state_ == State::RetiredClaimed;
    }
    bool Complete(int rc) {
        std::lock_guard<std::mutex> lock(mu_);
        if (state_ == State::Complete || state_ == State::Revoked) return false;
        result_ = state_ == State::RetiredClaimed ? -1 : rc;
        state_ = State::Complete;
        CloseLocked();
        cv_.notify_all();
        return true;
    }
    int Wait(int queuedMs, int claimedMs, bool* retained) {
        std::unique_lock<std::mutex> lock(mu_);
        cv_.wait_for(lock, std::chrono::milliseconds(queuedMs), [&] { return FinishedLocked(); });
        if (state_ == State::Claimed || state_ == State::RetiredClaimed) {
            cv_.wait_for(lock, std::chrono::milliseconds(claimedMs), [&] { return FinishedLocked(); });
        }
        if (state_ == State::Queued || state_ == State::Claimed || state_ == State::RetiredClaimed) timedOut_ = true;
        if (state_ == State::Queued) { state_ = State::Revoked; CloseLocked(); }
        else if (state_ == State::Claimed) state_ = State::RetiredClaimed;
        if (retained) *retained = state_ == State::RetiredClaimed;
        return state_ == State::Complete ? result_ : -1;
    }
    bool Acknowledged() const { std::lock_guard<std::mutex> lock(mu_); return state_ == State::Complete; }
    bool TimedOut() const { std::lock_guard<std::mutex> lock(mu_); return timedOut_; }
    bool Retained() const {
        std::lock_guard<std::mutex> lock(mu_);
        return state_ == State::Claimed || state_ == State::RetiredClaimed;
    }
    bool Done() const {
        std::lock_guard<std::mutex> lock(mu_);
        return state_ == State::Complete || state_ == State::Revoked;
    }
private:
    bool FinishedLocked() const {
        return state_ == State::Complete || state_ == State::Revoked;
    }
    void CloseLocked() { if (fd_ >= 0) { const int fd = fd_; fd_ = -1; close(fd); } }
    mutable std::mutex mu_;
    std::condition_variable cv_;
    int fd_;
    int result_ = -1;
    bool timedOut_ = false;
    State state_ = State::Queued;
};

// Every successful TSFN acquire is paired, including allocation/dup failures.
// On napi_closing the caller must abandon the handle, per Node-API semantics.
class ProtectCallbackLease {
public:
    using Release = void (*)(void*);
    ProtectCallbackLease(void* handle, Release release) : handle_(handle), release_(release) {}
    ~ProtectCallbackLease() { if (handle_ && release_) release_(handle_); }
    void Closing() { handle_ = nullptr; }
    ProtectCallbackLease(const ProtectCallbackLease&) = delete;
    ProtectCallbackLease& operator=(const ProtectCallbackLease&) = delete;
private:
    void* handle_;
    Release release_;
};
