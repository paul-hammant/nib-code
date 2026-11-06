"""Installer checks without a compiler or network."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTest(unittest.TestCase):
    def test_install_and_failures(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            assets = work / 'assets'
            assets.mkdir()
            fake = work / 'fake'
            fake.mkdir()
            uname = fake / 'uname'
            uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo amd64;; esac\n')
            uname.chmod(0o755)
            asset = assets / 'nib-x86_64-linux.tar.gz'
            data = b'#!/bin/sh\necho "nib 0.5.0"\n'
            with tarfile.open(asset, 'w:gz') as archive:
                info = tarfile.TarInfo('nib')
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            sums = assets / 'SHA256SUMS'
            sums.write_text(hashlib.sha256(asset.read_bytes()).hexdigest() + '  ' + asset.name + '\n')
            env = dict(os.environ, PATH=str(fake) + ':' + os.environ['PATH'],
                       NIB_DOWNLOAD_BASE=assets.as_uri(), NIB_INSTALL_DIR=str(work / 'bin with spaces'))

            def run():
                return subprocess.run(['sh', str(ROOT / 'install.sh')], env=env,
                                      capture_output=True, text=True)

            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('nib 0.5.0', result.stdout)
            installed = work / 'bin with spaces/nib'
            self.assertEqual(installed.stat().st_mode & 0o777, 0o755)
            sums.write_text('0' * 64 + '  ' + asset.name + '\n')
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Checksum mismatch', result.stderr)
            self.assertEqual(installed.read_bytes(), data)
            env['NIB_SKIP_VERIFY'] = '1'
            self.assertEqual(run().returncode, 0)
            uname.write_text('#!/bin/sh\necho unsupported\n')
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unsupported platform', result.stderr)


if __name__ == '__main__':
    unittest.main()
