#include "hev-udp-diagnostics.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    char json[2048];
    assert(hev_socks5_tunnel_diag_snapshot(NULL, 100) == -1);
    assert(hev_socks5_tunnel_diag_snapshot(json, 0) == -1);
    assert(hev_socks5_tunnel_diag_snapshot(json, 1) == -1);
    assert(json[0] == '\0');
    assert(hev_socks5_tunnel_diag_snapshot(json, sizeof(json)) > 0);
    assert(strstr(json, "\"rxCalls\":0") != NULL);
    chuanshan_diag_udp_rx(-1, EAGAIN);
    chuanshan_diag_udp_rx(-1, EIO);
    chuanshan_diag_udp_rx(0, 0);
    chuanshan_diag_udp_rx(2, 0);
    chuanshan_diag_udp_loop(0, 0);
    chuanshan_diag_udp_loop(1, 0);
    chuanshan_diag_udp_loop(-1, -1);
    chuanshan_diag_tcp_loop(0, 0);
    chuanshan_diag_tcp_loop(1, 0);
    chuanshan_diag_udp_control(-1, EAGAIN);
    chuanshan_diag_udp_control(0, 0);
    chuanshan_diag_udp_control(-1, EIO);
    chuanshan_diag_poll(2, 0);
    chuanshan_diag_poll(0, 10);
    chuanshan_diag_poll(-1, 10);
    chuanshan_diag_event(1, 1, 0, 0);
    chuanshan_diag_event(0, 0, 1, 1);
    errno = EBUSY;
    chuanshan_diag_tun_registered(55, -1, EEXIST, 2048);
    assert(errno == EBUSY);
    for (int stage = 1; stage < 13; stage++) chuanshan_diag_tun_stage(stage, 0, EAGAIN);
    assert(errno == EBUSY);
    assert(hev_socks5_tunnel_diag_snapshot(json, sizeof(json)) > 0);
    assert(strstr(json, "\"rxCalls\":4") != NULL);
    assert(strstr(json, "\"rxAgain\":1") != NULL);
    assert(strstr(json, "\"rxErrors\":1") != NULL);
    assert(strstr(json, "\"rxMessages\":2") != NULL);
    assert(strstr(json, "\"loopIdle\":1") != NULL);
    assert(strstr(json, "\"loopProgress\":1") != NULL);
    assert(strstr(json, "\"loopTerminal\":1") != NULL);
    assert(strstr(json, "\"controlAgain\":1") != NULL);
    assert(strstr(json, "\"controlEof\":1") != NULL);
    assert(strstr(json, "\"controlErrors\":1") != NULL);
    assert(strstr(json, "\"pollCalls\":3") != NULL);
    assert(strstr(json, "\"pollZeroTimeout\":1") != NULL);
    assert(strstr(json, "\"eventIn\":1") != NULL);
    assert(strstr(json, "\"eventOut\":1") != NULL);
    assert(strstr(json, "\"eventErr\":1") != NULL);
    assert(strstr(json, "\"eventHup\":1") != NULL);
    assert(strstr(json, "\"tcpLoopCalls\":2") != NULL);
    assert(strstr(json, "\"tcpLoopIdle\":1") != NULL);
    assert(strstr(json, "\"tcpLoopProgress\":1") != NULL);
    assert(strstr(json, "\"tunRegResult\":-1") != NULL);
    assert(strstr(json, "\"tunFd\":55") != NULL);
    assert(strstr(json, "\"tunStage\":12") != NULL);
    assert(strstr(json, "\"tunCounts\":[1,1,1,1,1,1,1,1,1,1,1,1,1]") != NULL);
    puts(json);
    return 0;
}
