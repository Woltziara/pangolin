#!/usr/bin/env python3
"""Add counts-only TUN progress probes. No routing, waits, return or retry changes."""
from pathlib import Path
import sys

p = Path(sys.argv[1]) / 'src/hev-socks5-tunnel.c'
text = p.read_text()
def replace(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit('TUN diagnostic anchor mismatch: ' + old[:90])
    text = text.replace(old, new, 1)

replace('#include <errno.h>', '#include <errno.h>\n#include <fcntl.h>\n#include "hev-udp-diagnostics.h"')
replace('    hev_task_yield (type);\n\n    return READ_ONCE (run) ? 0 : -1;',
        '    chuanshan_diag_tun_stage (8, type, errno);\n'
        '    hev_task_yield (type);\n'
        '    chuanshan_diag_tun_stage (9, type, errno);\n\n'
        '    return READ_ONCE (run) ? 0 : -1;')
replace('    s = hev_tunnel_write (tun_fd, p);',
        '    chuanshan_diag_tun_stage (10, 0, 0);\n'
        '    s = hev_tunnel_write (tun_fd, p);\n'
        '    chuanshan_diag_tun_stage (11, s, errno);')
replace('    hev_tunnel_add_task (tun_fd, task_lwip_io);',
        '    int registration = hev_tunnel_add_task (tun_fd, task_lwip_io);\n'
        '    int registration_errno = errno;\n'
        '    int descriptor_flags = fcntl (tun_fd, F_GETFL);\n'
        '    chuanshan_diag_tun_registered (tun_fd, registration, registration_errno, descriptor_flags);\n'
        '    errno = registration_errno;')
replace('        buf = hev_tunnel_read (tun_fd, mtu, task_io_yielder, NULL);',
        '        chuanshan_diag_tun_stage (1, 0, 0);\n'
        '        buf = hev_tunnel_read (tun_fd, mtu, task_io_yielder, NULL);\n'
        '        chuanshan_diag_tun_stage (2, buf ? (int)buf->tot_len : 0, errno);')
replace('        hev_task_mutex_lock (&mutex);\n'
        '        if (netif->input (buf, netif) != ERR_OK)\n'
        '            pbuf_free (buf);\n'
        '        hev_task_mutex_unlock (&mutex);',
        '        chuanshan_diag_tun_stage (3, 0, 0);\n'
        '        hev_task_mutex_lock (&mutex);\n'
        '        chuanshan_diag_tun_stage (4, 0, 0);\n'
        '        chuanshan_diag_tun_stage (5, 0, 0);\n'
        '        int input_result = netif->input (buf, netif);\n'
        '        chuanshan_diag_tun_stage (6, input_result, errno);\n'
        '        if (input_result != ERR_OK)\n'
        '            pbuf_free (buf);\n'
        '        hev_task_mutex_unlock (&mutex);\n'
        '        chuanshan_diag_tun_stage (7, 0, 0);')
replace('    hev_tunnel_del_task (tun_fd, task_lwip_io);',
        '    chuanshan_diag_tun_stage (12, 0, 0);\n'
        '    hev_tunnel_del_task (tun_fd, task_lwip_io);')
p.write_text(text)
