#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent/'scripts/init-volumes.sh'

class InitTests(unittest.TestCase):
    def setUp(self):
        if 'SERVER_ENV=dev' not in Path('/etc/environment').read_text().splitlines(): self.skipTest('requires dev host identity')
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        for name in ('bin', 'data', 'mount'): (self.p/name).mkdir(mode=0o700)
        f = self.p/'env'; f.write_text(f'OPENCLOUD_DATA_PATH={self.p}/data\nOPENCLOUD_UID={os.getuid()}\nOPENCLOUD_GID={os.getgid()}\nBACKUP_LOCAL_DIR={self.p}/backup\nBACKUP_RCLONE_MOUNT={self.p}/mount\nBACKUP_RCLONE_FOLDER=opencloud\nBACKUP_RCLONE_REMOTE=drive\n'); f.chmod(0o600)
        self.env = dict(os.environ, SERVER_ENV='dev', ORCHESTRATOR_ENV_FILE=str(f), PATH=str(self.p/'bin')+':/usr/bin:/bin', TEST_ROOT=str(self.p))
        fake = self.p/'bin/findmnt'; fake.write_text('''#!/bin/sh
[ ! -e "$TEST_ROOT/missing" ] || exit 1
case "$*" in *FSTYPE*) echo fuse.rclone;; *SOURCE*) echo drive:;; esac
'''); fake.chmod(0o755)
    def run_script(self): return subprocess.run([str(SCRIPT)], env=self.env, capture_output=True, text=True)
    def test_mount_guard_and_idempotence(self):
        (self.p/'missing').touch()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse((self.p/'mount/opencloud').exists())
        (self.p/'missing').unlink()
        for _ in range(2):
            result = self.run_script(); self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.p/'mount/opencloud').is_dir())
        self.assertTrue((self.p/'backup').is_dir())

if __name__ == '__main__': unittest.main()
