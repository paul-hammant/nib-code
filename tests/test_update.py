"""Self-update against local release assets; no credentials or GitHub downloads."""
import functools
import hashlib
import http.server
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/nib'

class Update(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets = self.root / 'assets'
        self.assets.mkdir()
        self.target = self.root / 'bin/nib'
        self.target.parent.mkdir()
        shutil.copy2(BINARY, self.target)
        self.current = subprocess.check_output([self.target, '--version'], text=True).strip()[4:]
        arch = {'arm64': 'aarch64', 'amd64': 'x86_64'}.get(platform.machine(), platform.machine())
        self.asset = f'nib-{arch}-{"macos" if platform.system() == "Darwin" else "linux"}.tar.gz'
        with tarfile.open(self.assets / self.asset, 'w:gz', format=tarfile.USTAR_FORMAT) as tar:
            data = b'#!/bin/sh\necho "nib 9.9.9"\n'
            info = tarfile.TarInfo('nib')
            info.size = len(data)
            info.mode = 0o755
            tar.addfile(info, io.BytesIO(data))
        digest = hashlib.sha256((self.assets / self.asset).read_bytes()).hexdigest()
        (self.assets / 'SHA256SUMS').write_text(f'{digest}  {self.asset}\n')

    def run_update(self, version='9.9.9', base=None, **env):
        return subprocess.run([self.target, 'update', version], env=dict(os.environ,
            NIB_DOWNLOAD_BASE=base or self.assets.as_uri(), **env), capture_output=True, text=True)

    def test_replace(self):
        result = self.run_update('v9.9.9')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f'nib {self.current} → 9.9.9\n')
        self.assertEqual(result.stderr, '')
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o755)
        self.assertEqual(subprocess.check_output([self.target], text=True), 'nib 9.9.9\n')
        self.assertEqual(list(self.target.parent.glob('.nib-*')), [])

    def test_checksum_failure(self):
        original = self.target.read_bytes()
        (self.assets / 'SHA256SUMS').write_text('0' * 64 + f'  {self.asset}\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(list(self.target.parent.glob('.nib-*')), [])

    def test_same_version(self):
        result = self.run_update(self.current)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f'nib {self.current} is installed\n')

    def test_unwritable(self):
        if os.geteuid() == 0:
            self.skipTest('root bypasses directory permissions')
        original = self.target.read_bytes()
        self.target.parent.chmod(0o555)
        try:
            result = self.run_update()
        finally:
            self.target.parent.chmod(0o755)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.target), result.stderr)
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertEqual(self.target.read_bytes(), original)

    def test_symlink_and_skip_verify(self):
        link = self.root / 'alias'
        link.symlink_to(self.target)
        self.target = link
        (self.assets / 'SHA256SUMS').unlink()
        result = self.run_update(NIB_SKIP_VERIFY='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(subprocess.check_output([link], text=True), 'nib 9.9.9\n')

    def test_http(self):
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=self.assets))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = self.run_update(base=f'http://127.0.0.1:{server.server_port}', HTTP_PROXY='', HTTPS_PROXY='', http_proxy='', https_proxy='')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f'nib {self.current} → 9.9.9\n')
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

if __name__ == '__main__':
    unittest.main()
