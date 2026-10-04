"""Execute the production C diagnostics and socket hold release, not replicas."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class NativeHelpersTest(unittest.TestCase):
    def test_declared_and_consumed_methods_match_native_exports(self):
        cpp = '\n'.join((ROOT / 'entry/src/main/cpp' / name).read_text()
                        for name in ('napi_init.cpp', 'app_flow_router.cpp'))
        exported = set(re.findall(r'\{\s*"([^"]+)",\s*nullptr,\s*\w+,', cpp))
        declared = set(re.findall(r'export const (\w+):',
            (ROOT / 'entry/src/main/cpp/types/libheyvpn/Index.d.ts').read_text()))
        consumed = set(re.findall(r'heyNative\.(\w+)\(',
            (ROOT / 'entry/src/main/ets/native/TunnelNative.ets').read_text()))
        self.assertEqual(exported, declared)
        self.assertEqual(consumed, declared)

    def test_diagnostic_counters_and_errno(self):
        cc = shutil.which('clang') or shutil.which('cc')
        if not cc:
            self.skipTest('C compiler unavailable')
        with tempfile.TemporaryDirectory() as temp:
            output = str(Path(temp) / 'diagnostics')
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'native/patches'),
                str(ROOT / 'tests/hev_udp_diagnostics_test.c'),
                str(ROOT / 'native/patches/hev-udp-diagnostics.c'), '-o', output], check=True)
            subprocess.run([output], check=True, stdout=subprocess.DEVNULL)

    def test_protect_hold_closes_once_even_after_fd_reuse(self):
        cxx = shutil.which('clang++') or shutil.which('c++')
        if not cxx:
            self.skipTest('C++ compiler unavailable')
        source = (ROOT / 'entry/src/main/cpp/napi_init.cpp').read_text()
        actual = source[source.index('struct ProtectWaiter {'):source.index('struct ProtectCall {')]
        with tempfile.TemporaryDirectory() as temp:
            test = Path(temp) / 'test.cpp'
            test.write_text('''#include <atomic>
#include <cassert>
#include <condition_variable>
#include <cstdint>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <thread>
#include <unistd.h>
''' + actual + '''
int main() {
    int fds[2]; assert(pipe(fds) == 0);
    auto waiter = std::make_shared<ProtectWaiter>();
    waiter->holdFd.store(fds[0]);
    std::thread a([&]{ ReleaseProtectHold(waiter); });
    std::thread b([&]{ ReleaseProtectHold(waiter); });
    a.join(); b.join();
    assert(waiter->holdFd.load() == -1);
    assert(fcntl(fds[0], F_GETFD) == -1);
    assert(dup2(fds[1], fds[0]) == fds[0]);
    ReleaseProtectHold(waiter);
    assert(fcntl(fds[0], F_GETFD) >= 0);
    close(fds[0]); close(fds[1]);
    ReleaseProtectHold(nullptr);
}
''')
            output = str(Path(temp) / 'test')
            subprocess.run([cxx, '-std=c++17', '-pthread', '-Wall', '-Wextra', '-Werror', str(test), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=10)
