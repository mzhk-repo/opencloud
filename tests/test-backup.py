#!/usr/bin/env python3
"""Exercise backup orchestration with isolated local fake services."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class BackupTests(unittest.TestCase):
    def setUp(self):
        if 'SERVER_ENV=dev' not in Path('/etc/environment').read_text().splitlines():
            self.skipTest('requires a dev host identity')
        self.tmp = tempfile.TemporaryDirectory(dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        for d in ('scripts', 'bin', 'data', 'backup', 'metrics', 'mount/oc', 'remote/oc'):
            (self.p / d).mkdir(parents=True)
        shutil.copy(ROOT / 'scripts/backup.sh', self.p / 'scripts')
        config = b'instance: isolated\n'
        self.secret = 'opencloud_opencloud_yaml_v' + hashlib.sha256(config).hexdigest()[:16]
        settings = dict(OPENCLOUD_DATA_PATH=str(self.p/'data'), BACKUP_LOCAL_DIR=str(self.p/'backup'), BACKUP_RCLONE_REMOTE='drive', BACKUP_RCLONE_FOLDER='oc', BACKUP_RCLONE_MOUNT=str(self.p/'mount'), NODE_EXPORTER_TEXTFILE_DIR=str(self.p/'metrics'), BORG_PASSPHRASE='synthetic', OPENCLOUD_YAML_B64=base64.b64encode(config).decode())
        (self.p/'env.dev.enc').write_text(''.join(f'{k}={v}\n' for k,v in settings.items()))
        (self.p/'replicas').write_text('1')
        self.env = dict(os.environ, PATH=str(self.p/'bin')+':/usr/bin:/bin', SERVER_ENV='dev', STACK_NAME='test', TEST_ROOT=str(self.p), TEST_SECRET=self.secret)
        self.exe('sops', '#!/bin/sh\ncat "$6"\n')
        self.exe('findmnt', '''#!/bin/sh
[ ! -e "$TEST_ROOT/mount-missing" ] || exit 1
case "$*" in *FSTYPE*) echo fuse.rclone;; *SOURCE*) echo drive:;; esac
''')
        self.exe('borg', '''#!/usr/bin/python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['TEST_ROOT']); a=sys.argv[1:]
with (p/'events').open('a') as f: f.write('borg '+a[0]+'\\n')
if a[0]=='prune': (p/'prune-args').write_text(' '.join(a))
if a[0]=='--version': print('borg 1.4.1')
elif a[0]=='init': pathlib.Path(a[-1]).mkdir()
elif a[0]=='info': print(json.dumps({'encryption': {'mode':'repokey-blake2'}}))
elif a[0]=='create' and (p/'fail-create').exists(): sys.exit(1)
''')
        self.exe('docker', '''#!/usr/bin/python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['TEST_ROOT']); a=sys.argv[1:]
with (p/'events').open('a') as f: f.write('docker '+' '.join(a[:3])+'\\n')
if a[:2]==['service','inspect']:
 print(json.dumps([{'Spec':{'Mode':{'Replicated':{'Replicas':int((p/'replicas').read_text())}},'TaskTemplate':{'Placement':{'Constraints':['node.labels.storage == primary']},'ContainerSpec':{'Mounts':[{'Type':'bind','Source':str(p/'data'),'Target':'/var/lib/opencloud'}],'Secrets':[{'File':{'Name':'/etc/opencloud/opencloud.yaml'},'SecretName':os.environ['TEST_SECRET']}],'Configs':[{'ConfigID':'abc123'}]}}}}]))
elif a[:2]==['service','scale']:
 (p/'replicas').write_text(a[-1][-1])
elif a[:2]==['config','inspect']: print('{}')
elif a[0]=='info' or a[:2]==['node','ls']: print('node1')
elif a[0]=='ps' and '-q' in a and (p/'fail-ps').exists(): sys.exit(1)
elif a[0]=='ps' and '-q' not in a and (p/'replicas').read_text()=='1': print('container1')
''')
        self.exe('rclone', '''#!/usr/bin/python3
import os, pathlib, shutil, sys
p=pathlib.Path(os.environ['TEST_ROOT']); a=sys.argv[1:]
with (p/'events').open('a') as f: f.write('rclone '+a[0]+'\\n')
def path(s): return p/'remote'/s.removeprefix('drive:')
if a[0]=='copy':
 if (p/'fail-copy').exists(): sys.exit(1)
 shutil.copytree(a[1],path(a[2]),dirs_exist_ok=True)
elif a[0]=='copyto':
 path(a[2]).parent.mkdir(parents=True,exist_ok=True); shutil.copy(a[1],path(a[2]))
elif a[0]=='lsf':
 for x in path(a[-1]).iterdir():
  if x.is_dir(): print(x.name+'/')
elif a[0]=='cat':
 try: print(path(a[1]).read_text(),end='')
 except FileNotFoundError: sys.exit(1)
elif a[0]=='purge': shutil.rmtree(path(a[1]))
''')

    def exe(self, name, body):
        p = self.p/'bin'/name; p.write_text(body); p.chmod(0o755)

    def run_backup(self, *args):
        return subprocess.run([str(self.p/'scripts/backup.sh'), *args], env=self.env, capture_output=True, text=True)

    def events(self): return (self.p/'events').read_text().splitlines()
    def metrics(self): return (self.p/'metrics/opencloud_backup.prom').read_text()

    def test_failure_retry_retention_and_metrics(self):
        old = self.p/'remote/oc/opencloud-dev-20200101T000000000000000Z-12345678'; old.mkdir(); (old/'.opencloud-backup-owner').write_text('opencloud-backup-v1 dev\n')
        other = self.p/'remote/oc/opencloud-dev-20200102T000000000000000Z-12345678'; other.mkdir()
        newer = self.p/'remote/oc/opencloud-dev-20990101T000000000000000Z-12345678'; newer.mkdir(); (newer/'.opencloud-backup-owner').write_text('opencloud-backup-v1 dev\n')
        (self.p/'fail-copy').touch()
        r = self.run_backup('dev'); self.assertNotEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.p/'replicas').read_text(), '1')
        self.assertIn('opencloud_backup_last_status{env="dev",service="opencloud"} 0', self.metrics())
        self.assertTrue(old.exists()); self.assertTrue(other.exists())
        before = self.events().count('borg create')
        (self.p/'fail-copy').unlink()
        r = self.run_backup('dev','--retry-copy'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.events().count('borg create'), before)
        self.assertFalse(old.exists()); self.assertTrue(other.exists()); self.assertTrue(newer.exists())
        self.assertIn('opencloud_backup_last_status{env="dev",service="opencloud"} 1', self.metrics())
        success = self.metrics().splitlines()[1]
        (self.p/'fail-create').touch()
        r = self.run_backup('dev'); self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.p/'replicas').read_text(), '1')
        self.assertEqual(success, self.metrics().splitlines()[1])
        self.assertIn('borg prune', self.events())
        prune = (self.p/'prune-args').read_text()
        for option in ('--keep-daily 7', '--keep-weekly 4', '--keep-monthly 6', '--glob-archives opencloud-dev-*'): self.assertIn(option, prune)

    def test_stopped_service_and_missing_mount(self):
        (self.p/'replicas').write_text('0'); (self.p/'mount-missing').touch()
        r = self.run_backup('dev'); self.assertNotEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.p/'replicas').read_text(), '0')
        self.assertTrue((self.p/'backup/.opencloud-pending').exists())
        self.assertFalse(any(x.startswith('docker service scale') for x in self.events()))

    def test_rejects_mismatched_secret_and_concurrent_run(self):
        self.env['TEST_SECRET'] = 'opencloud_opencloud_yaml_v0000000000000000'
        result = self.run_backup('dev')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(x.startswith('docker service scale') for x in self.events()))
        self.env['TEST_SECRET'] = self.secret
        with (self.p/'backup/.opencloud-backup.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_backup('dev')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another backup is running', result.stderr)

    def test_metrics_write_failure_is_reported(self):
        if os.geteuid() == 0:
            self.skipTest('requires an unprivileged test user')
        directory = self.p/'metrics'
        directory.chmod(0o500)
        try:
            result = self.run_backup('dev')
        finally:
            directory.chmod(0o700)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('failed to write backup metrics', result.stderr)

    def test_cannot_check_stopped_container(self):
        (self.p/'fail-ps').touch()
        result = self.run_backup('dev')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.p/'replicas').read_text(), '1')
        self.assertNotIn('borg create', self.events())

    def test_real_borg_restores_xattr_when_available(self):
        borg = os.environ.get('ISOLATED_BORG')
        if not borg:
            self.skipTest('ISOLATED_BORG was not provided')
        self.exe('borg', f'#!/bin/sh\nexec "{borg}" "$@"\n')
        self.env['PYTHONPATH'] = os.environ['ISOLATED_BORG_PYTHONPATH']
        self.env['BORG_CACHE_DIR'] = str(self.p/'borg-cache')
        self.env['BORG_CONFIG_DIR'] = str(self.p/'borg-config')
        data = self.p/'data/control'
        data.write_text('control')
        os.setxattr(data, 'user.oc.id', b'isolated-id')
        result = self.run_backup('dev')
        self.assertEqual(result.returncode, 0, result.stderr)
        restore = self.p/'restore'; restore.mkdir()
        env = dict(self.env, BORG_PASSPHRASE='synthetic')
        repo = str(self.p/'backup/repository')
        listing = subprocess.check_output([borg, 'list', '--short', repo], env=env, text=True).strip()
        subprocess.run([borg, 'extract', repo+'::'+listing], cwd=restore, env=env, check=True, capture_output=True)
        restored = restore / str(data).lstrip('/')
        self.assertEqual(restored.read_text(), 'control')
        self.assertEqual(os.getxattr(restored, 'user.oc.id'), b'isolated-id')

if __name__ == '__main__': unittest.main()
