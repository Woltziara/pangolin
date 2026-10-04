"""Replay the actual patched C functions, not a Python model.

Run after the native checkout has been prepared:
HEV_WORK_DIR=<build directory> python3 tests/test_hev_socket_events.py
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HevSocketEventsTest(unittest.TestCase):
    def compile_run(self, source):
        cc = shutil.which("clang") or shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="hev-event-test-") as tmp:
            cfile = Path(tmp) / "test.c"
            exe = Path(tmp) / "test"
            cfile.write_text(source)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-Wno-sign-compare", str(cfile), "-o", str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def checkout(self):
        work = os.environ.get("HEV_WORK_DIR")
        if not work:
            self.skipTest("HEV_WORK_DIR is required to test actual patched upstream code")
        root = Path(work) / "src"
        self.assertTrue(root.is_dir())
        return root

    def test_tcp_interest_and_backpressure(self):
        source = (self.checkout() / "src/hev-socks5-session-tcp.c").read_text()
        actual = re.search(r"static unsigned int\ntcp_needed_events[\s\S]*?(?=static int\ntask_io_yielder)", source)
        self.assertIsNotNone(actual)
        self.compile_run(r'''
#include <assert.h>
#include <stddef.h>
#include <poll.h>
typedef int HevTask;
typedef struct { size_t used, max; } Ring;
typedef struct { void *queue; Ring *buffer; int fd; } HevSocks5SessionTCP;
#define HEV_SOCKS5(s) (s)
static HevTask task;
static int registered=1, modifications, additions, deletions, fail;
static HevTask *hev_task_self(void) { return &task; }
static size_t hev_ring_buffer_get_use_size(Ring *r) { return r->used; }
static size_t hev_ring_buffer_get_max_size(Ring *r) { return r->max; }
static int hev_task_mod_fd(HevTask *t,int fd,unsigned e) {
 (void)t;(void)e;assert(fd==42);if(fail||!registered)return -1;modifications++;return 0;
}
static int hev_task_add_fd(HevTask *t,int fd,unsigned e) {
 (void)t;(void)e;assert(fd==42);if(fail)return -1;registered=1;additions++;return 0;
}
static int hev_task_del_fd(HevTask *t,int fd) {
 (void)t;assert(fd==42);registered=0;deletions++;return 0;
}
''' + actual[0] + r'''
int main(void) {
 Ring b={0,64};HevSocks5SessionTCP s={0,&b,42};unsigned current=~0u;
 assert(tcp_needed_events(&s,0,0)==POLLIN);
 s.queue=&task;assert(tcp_needed_events(&s,0,0)==(POLLIN|POLLOUT));
 b.used=64;assert(tcp_needed_events(&s,0,0)==POLLOUT);
 s.queue=0;assert(tcp_needed_events(&s,0,0)==0);
 b.used=0;assert(tcp_needed_events(&s,0,-1)==0);
 s.queue=&task;assert(tcp_needed_events(&s,-1,0)==POLLIN);
 assert(set_tcp_interest(&s,POLLIN,&current)==0&&modifications==1);
 assert(set_tcp_interest(&s,POLLIN,&current)==0&&modifications==1);
 assert(set_tcp_interest(&s,0,&current)==0&&!registered&&deletions==1);
 assert(set_tcp_interest(&s,POLLIN,&current)==0&&registered&&additions==1);
 fail=1;assert(set_tcp_interest(&s,POLLOUT,&current)<0&&current==POLLIN);
 return 0;
}
''')

    def test_socket_wait_direction_and_nonblocking(self):
        source = (self.checkout() / "third-part/hev-task-system/src/lib/io/socket/hev-task-io-socket.c").read_text()
        helper = re.search(r"static int\nset_wait_interest[\s\S]*?(?=EXPORT_SYMBOL)", source)
        self.assertIsNotNone(helper)
        functions = []
        for name in ("recv", "send"):
            match = re.search(r"EXPORT_SYMBOL ssize_t\nhev_task_io_socket_" + name + r" \([\s\S]*?(?=EXPORT_SYMBOL)", source)
            self.assertIsNotNone(match)
            functions.append(match[0])
        self.compile_run(r'''
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
typedef int HevTask;
typedef int HevTaskYieldType;
typedef int (*HevTaskIOYielder)(int,void*);
#define HEV_TASK_WAITIO 1
#define EXPORT_SYMBOL
static HevTask task;
static int events, expected, reads, sends, waits, abort_wait, fail_interest;
static HevTask *hev_task_self(void) { return &task; }
static int hev_task_mod_fd(HevTask *t,int fd,unsigned e) {
 (void)t;assert(fd==42);if(fail_interest)return -1;events=e;return 0;
}
static int hev_task_add_fd(HevTask *t,int fd,unsigned e) {return hev_task_mod_fd(t,fd,e);}
static int yield_checked(int type,void *data) {
 (void)data;assert(type==HEV_TASK_WAITIO&&events==expected);waits++;return abort_wait;
}
static void hev_task_yield(int type) {(void)yield_checked(type,0);}
static ssize_t fake_recv(int fd,void *buf,size_t len,int flags) {
 (void)flags;assert(fd==42);if(reads++==0){errno=EAGAIN;return -1;}
 memset(buf,0,len);return (ssize_t)len;
}
static ssize_t fake_send(int fd,const void *buf,size_t len,int flags) {
 (void)buf;(void)flags;assert(fd==42);if(sends++==0){errno=EAGAIN;return -1;}return (ssize_t)len;
}
#define recv fake_recv
#define send fake_send
''' + helper[0] + "\n".join(functions) + r'''
int main(void) {
 char buf[4]={0};expected=POLLIN;
 assert(hev_task_io_socket_recv(42,buf,4,MSG_WAITALL,yield_checked,0)==4);
 assert(waits==1&&events==POLLIN);
 expected=POLLOUT;assert(hev_task_io_socket_send(42,buf,4,MSG_WAITALL,yield_checked,0)==4);
 assert(waits==2&&events==POLLOUT);
 reads=0;assert(hev_task_io_socket_recv(42,buf,4,MSG_DONTWAIT,yield_checked,0)==-1);
 assert(waits==2&&events==POLLOUT);
 reads=0;expected=POLLIN;abort_wait=1;
 assert(hev_task_io_socket_recv(42,buf,4,0,yield_checked,0)==-2);
 reads=0;abort_wait=0;fail_interest=1;
 assert(hev_task_io_socket_recv(42,buf,4,0,yield_checked,0)==-2);
 return 0;
}
''')


if __name__ == "__main__":
    unittest.main()
