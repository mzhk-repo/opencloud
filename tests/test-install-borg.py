#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'scripts/install-borg.sh'

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        self.env = dict(os.environ, PATH=str(self.p)+':/usr/bin:/bin', TEST_BIN=str(self.p))
        self.exe('sudo', '''#!/bin/bash
printf '%s\\n' "$*" >> "$TEST_BIN/sudo-calls"
[[ ! -e "$TEST_BIN/deny" ]] || exit 1
if [[ " $* " == *" install "* ]]; then
  printf '#!/bin/sh\\necho borg 1.3.2\\n' > "$TEST_BIN/borg"
  chmod +x "$TEST_BIN/borg"
fi
''')
    def exe(self, name, text):
        p = self.p/name; p.write_text(text); p.chmod(0o755)
    def run_script(self): return subprocess.run([str(SCRIPT)], env=self.env, text=True, capture_output=True)
    def test_existing_newer_borg_is_reused(self):
        self.exe('borg', '#!/bin/sh\necho borg 1.4.9\n')
        for _ in range(2): self.assertEqual(self.run_script().returncode, 0)
        self.assertFalse((self.p/'sudo-calls').exists())
    def test_install_and_repeat(self):
        r = self.run_script(); self.assertEqual(r.returncode, 0, r.stderr)
        calls = (self.p/'sudo-calls').read_text().splitlines()
        self.assertEqual(len(calls), 2); self.assertTrue(all(c.startswith('-n apt-get ') for c in calls))
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual((self.p/'sudo-calls').read_text().splitlines(), calls)
    def test_denied_sudo_and_incompatible_borg(self):
        (self.p/'deny').touch()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.exe('borg', '#!/bin/sh\necho borg 2.0.0\n')
        self.assertNotEqual(self.run_script().returncode, 0)

if __name__ == '__main__': unittest.main()
