#include "hev-udp-diagnostics.h"
#include <errno.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

/* Process-lifetime counters. Relaxed atomics keep the sampling reader safe
 * without adding a lock, timer, sleep, or any I/O to the forwarding loop. */
static atomic_uint_fast64_t rx_calls, rx_again, rx_errors, rx_zero, rx_messages;
static atomic_uint_fast64_t loop_calls, loop_idle, loop_progress, loop_terminal;
static atomic_uint_fast64_t tcp_loop_calls, tcp_loop_idle, tcp_loop_progress;
static atomic_uint_fast64_t control_calls, control_again, control_eof, control_errors;
static atomic_uint_fast64_t poll_calls, poll_zero_timeout, poll_ready, poll_empty, poll_errors;
static atomic_uint_fast64_t event_in, event_out, event_err, event_hup;
static atomic_int last_rx_errno, last_control_errno;
static atomic_uint_fast64_t tun_counts[13], tun_last_ms;
static atomic_int tun_stage, tun_reg_result, tun_reg_errno, tun_fd, tun_flags;
static atomic_int tun_read_errno, tun_write_errno, tun_input_result;

#define INC(counter) atomic_fetch_add_explicit(&(counter), 1, memory_order_relaxed)
#define GET(counter) ((uint64_t)atomic_load_explicit(&(counter), memory_order_relaxed))
#ifdef CHUANSHAN_HEV_SOCKET_DEMAND_EVENTS
#define DIAG_VARIANT "socket-demand-events-v2"
#elif defined(CHUANSHAN_HEV_UDP_DEMAND_WRITE)
#define DIAG_VARIANT "udp-demand-write-v1"
#else
#define DIAG_VARIANT "counters-only"
#endif

void chuanshan_diag_tun_stage(int stage, int result, int error)
{
    const int saved_errno = errno;
    struct timespec now;
    if (stage >= 0 && stage < 13) {
        INC(tun_counts[stage]);
        atomic_store_explicit(&tun_stage, stage, memory_order_relaxed);
        if (clock_gettime(CLOCK_MONOTONIC, &now) == 0)
            atomic_store_explicit(&tun_last_ms, (uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000,
                                  memory_order_relaxed);
        if (stage == 2 && result <= 0)
            atomic_store_explicit(&tun_read_errno, error, memory_order_relaxed);
        if (stage == 11 && result <= 0)
            atomic_store_explicit(&tun_write_errno, error, memory_order_relaxed);
        if (stage == 6)
            atomic_store_explicit(&tun_input_result, result, memory_order_relaxed);
    }
    errno = saved_errno;
}

void chuanshan_diag_tun_registered(int fd, int result, int error, int flags)
{
    atomic_store_explicit(&tun_fd, fd, memory_order_relaxed);
    atomic_store_explicit(&tun_flags, flags, memory_order_relaxed);
    atomic_store_explicit(&tun_reg_result, result, memory_order_relaxed);
    atomic_store_explicit(&tun_reg_errno, result < 0 ? error : 0, memory_order_relaxed);
    chuanshan_diag_tun_stage(0, result, error);
}

void chuanshan_diag_udp_rx(int result, int error)
{
    INC(rx_calls);
    if (result > 0)
        atomic_fetch_add_explicit(&rx_messages, (unsigned int)result, memory_order_relaxed);
    else if (result == 0)
        INC(rx_zero);
    else if (error == EAGAIN)
        INC(rx_again);
    else {
        INC(rx_errors);
        atomic_store_explicit(&last_rx_errno, error, memory_order_relaxed);
    }
}

void chuanshan_diag_udp_loop(int forward, int backward)
{
    INC(loop_calls);
    if (forward > 0 || backward > 0)
        INC(loop_progress);
    else if ((forward & backward) == 0)
        INC(loop_idle);
    else
        INC(loop_terminal);
}

void chuanshan_diag_udp_control(int result, int error)
{
    INC(control_calls);
    if (result == 0)
        INC(control_eof);
    else if (result < 0 && error == EAGAIN)
        INC(control_again);
    else if (result < 0) {
        INC(control_errors);
        atomic_store_explicit(&last_control_errno, error, memory_order_relaxed);
    }
}

void chuanshan_diag_tcp_loop(int forward, int backward)
{
    INC(tcp_loop_calls);
    if (forward > 0 || backward > 0) INC(tcp_loop_progress);
    else if ((forward & backward) == 0) INC(tcp_loop_idle);
}

void chuanshan_diag_poll(int result, int timeout)
{
    INC(poll_calls);
    if (timeout == 0) INC(poll_zero_timeout);
    if (result > 0) INC(poll_ready);
    else if (result == 0) INC(poll_empty);
    else INC(poll_errors);
}

void chuanshan_diag_event(int readable, int writable, int error, int hangup)
{
    if (readable) INC(event_in);
    if (writable) INC(event_out);
    if (error) INC(event_err);
    if (hangup) INC(event_hup);
}

int hev_socks5_tunnel_diag_snapshot(char *buffer, int capacity)
{
    if (!buffer || capacity < 1) return -1;
    int n = snprintf(buffer, (size_t)capacity,
        "{\"schema\":\"hev-udp-diag@1\",\"scope\":\"process\",\"variant\":\"" DIAG_VARIANT "\","
        "\"rxCalls\":%" PRIu64 ",\"rxAgain\":%" PRIu64 ",\"rxErrors\":%" PRIu64
        ",\"rxZero\":%" PRIu64 ",\"rxMessages\":%" PRIu64 ",\"lastRxErrno\":%d,"
        "\"loopCalls\":%" PRIu64 ",\"loopIdle\":%" PRIu64 ",\"loopProgress\":%" PRIu64
        ",\"loopTerminal\":%" PRIu64 ",\"controlCalls\":%" PRIu64
        ",\"controlAgain\":%" PRIu64 ",\"controlEof\":%" PRIu64
        ",\"controlErrors\":%" PRIu64 ",\"lastControlErrno\":%d,"
        "\"pollCalls\":%" PRIu64 ",\"pollZeroTimeout\":%" PRIu64
        ",\"pollReady\":%" PRIu64 ",\"pollEmpty\":%" PRIu64 ",\"pollErrors\":%" PRIu64
        ",\"eventIn\":%" PRIu64 ",\"eventOut\":%" PRIu64
        ",\"eventErr\":%" PRIu64 ",\"eventHup\":%" PRIu64
        ",\"tcpLoopCalls\":%" PRIu64 ",\"tcpLoopIdle\":%" PRIu64
        ",\"tcpLoopProgress\":%" PRIu64
        ",\"tunTraceVersion\":1,\"tunStage\":%d,\"tunLastMs\":%" PRIu64
        ",\"tunRegResult\":%d,\"tunRegErrno\":%d,\"tunFd\":%d,\"tunFlags\":%d"
        ",\"tunReadErrno\":%d,\"tunWriteErrno\":%d,\"tunInputResult\":%d"
        ",\"tunCounts\":[%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
        ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
        ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "]}",
        GET(rx_calls), GET(rx_again), GET(rx_errors), GET(rx_zero), GET(rx_messages),
        atomic_load_explicit(&last_rx_errno, memory_order_relaxed),
        GET(loop_calls), GET(loop_idle), GET(loop_progress), GET(loop_terminal),
        GET(control_calls), GET(control_again), GET(control_eof), GET(control_errors),
        atomic_load_explicit(&last_control_errno, memory_order_relaxed),
        GET(poll_calls), GET(poll_zero_timeout), GET(poll_ready), GET(poll_empty), GET(poll_errors),
        GET(event_in), GET(event_out), GET(event_err), GET(event_hup),
        GET(tcp_loop_calls), GET(tcp_loop_idle), GET(tcp_loop_progress),
        atomic_load_explicit(&tun_stage, memory_order_relaxed), GET(tun_last_ms),
        atomic_load_explicit(&tun_reg_result, memory_order_relaxed),
        atomic_load_explicit(&tun_reg_errno, memory_order_relaxed),
        atomic_load_explicit(&tun_fd, memory_order_relaxed),
        atomic_load_explicit(&tun_flags, memory_order_relaxed),
        atomic_load_explicit(&tun_read_errno, memory_order_relaxed),
        atomic_load_explicit(&tun_write_errno, memory_order_relaxed),
        atomic_load_explicit(&tun_input_result, memory_order_relaxed),
        GET(tun_counts[0]), GET(tun_counts[1]), GET(tun_counts[2]), GET(tun_counts[3]),
        GET(tun_counts[4]), GET(tun_counts[5]), GET(tun_counts[6]), GET(tun_counts[7]),
        GET(tun_counts[8]), GET(tun_counts[9]), GET(tun_counts[10]), GET(tun_counts[11]), GET(tun_counts[12]));
    if (n < 0 || n >= capacity) { buffer[0] = '\0'; return -1; }
    return n;
}
