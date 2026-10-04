#ifndef CHUANSHAN_HEV_UDP_DIAGNOSTICS_H
#define CHUANSHAN_HEV_UDP_DIAGNOSTICS_H

/* Counts only: never capture payloads, destinations, or authentication data. */
void chuanshan_diag_udp_rx(int result, int error);
void chuanshan_diag_udp_loop(int forward, int backward);
void chuanshan_diag_tcp_loop(int forward, int backward);
void chuanshan_diag_udp_control(int result, int error);
void chuanshan_diag_poll(int result, int timeout);
void chuanshan_diag_event(int readable, int writable, int error, int hangup);
/* 0 register, 1 read, 2 read-return, 3 lock-wait, 4 lock-held,
 * 5 input, 6 input-return, 7 unlocked, 8 wait-io, 9 resumed,
 * 10 write, 11 write-return, 12 task-exit. Observation only. */
void chuanshan_diag_tun_stage(int stage, int result, int error);
void chuanshan_diag_tun_registered(int fd, int result, int error, int flags);

__attribute__((visibility("default")))
int hev_socks5_tunnel_diag_snapshot(char *buffer, int capacity);

#endif
