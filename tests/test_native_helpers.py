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

    def test_protect_lease_cancellation_and_real_ack(self):
        cxx = shutil.which('clang++') or shutil.which('c++')
        if not cxx:
            self.skipTest('C++ compiler unavailable')
        with tempfile.TemporaryDirectory() as temp:
            output = str(Path(temp) / 'protect-lease')
            subprocess.run([cxx, '-std=c++17', '-pthread', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'entry/src/main/cpp'), str(ROOT / 'tests/protect_lease_test.cpp'), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=10)

    def test_error_journal_persistence_redaction_and_rotation(self):
        cxx = shutil.which('clang++') or shutil.which('c++')
        if not cxx:
            self.skipTest('C++ compiler unavailable')
        with tempfile.TemporaryDirectory() as temp:
            output = str(Path(temp) / 'error-journal')
            subprocess.run([cxx, '-std=c++17', '-pthread', '-Wall', '-Wextra', '-Werror',
                '-I', str(ROOT / 'entry/src/main/cpp'), str(ROOT / 'tests/local_error_log_test.cpp'),
                str(ROOT / 'entry/src/main/cpp/local_error_log.cpp'), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=20)
