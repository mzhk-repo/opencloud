#!/usr/bin/env python3
"""Exercise restore and metrics against a disposable encrypted Borg repository."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent

class RestoreTests(unittest.TestCase):
    def setUp(self):
        if 'SERVER_ENV=dev' not in Path('/etc/environment').read_text().splitlines():
            self.skipTest('requires dev host identity')
        if not shutil.which('borg') or not shutil.which('sops'):
            self.skipTest('requires Borg and SOPS')
        self.tmp=tempfile.TemporaryDirectory(dir='/tmp'); self.addCleanup(self.tmp.cleanup)
        self.p=Path(self.tmp.name); self.root=self.p/'project'; (self.root/'scripts').mkdir(parents=True)
        self.bin=self.p/'bin'; self.bin.mkdir(); self.data=self.p/'source'; self.backup=self.p/'backup'; self.metrics=self.p/'metrics'
        for p in (self.data/'storage/users',self.data/'idm',self.data/'nats/jetstream',self.backup,self.metrics): p.mkdir(parents=True)
        (self.data/'idm/idm.boltdb').write_bytes(b'synthetic')
        control=self.data/'storage/users/control'; control.write_bytes(b'synthetic control'); os.setxattr(control,'user.oc.id',b'synthetic-id')
        for name in ('restore.sh','test-restore.sh'): shutil.copy(ROOT/'scripts'/name,self.root/'scripts')
        settings=f'OPENCLOUD_DATA_PATH={self.data}\nBACKUP_LOCAL_DIR={self.backup}\nBORG_PASSPHRASE=synthetic-password\nNODE_EXPORTER_TEXTFILE_DIR={self.metrics}\n'
        (self.root/'env.dev.enc').write_text(settings)
        sops=self.bin/'sops'; sops.write_text('#!/bin/sh\ncat "$6"\n'); sops.chmod(0o755)
        self.env=dict(os.environ,PATH=str(self.bin)+':/usr/bin:/bin',SERVER_ENV='dev',BORG_PASSPHRASE='synthetic-password',BORG_CACHE_DIR=str(self.p/'cache'),BORG_CONFIG_DIR=str(self.p/'config'))
        self.repo=self.backup/'repository'; self.borg('init','--encryption=repokey-blake2',str(self.repo))
        self.cfg=tempfile.TemporaryDirectory(prefix='opencloud-backup.',dir='/dev/shm'); self.addCleanup(self.cfg.cleanup)
        config=Path(self.cfg.name)/'opencloud.yaml'; config.write_text('synthetic: true\n')
        service=Path(self.cfg.name)/'service.json'
        service.write_text(json.dumps([{'Spec':{'TaskTemplate':{'ContainerSpec':{'Image':'fixture:1','Mounts':[{'Type':'bind','Source':str(self.data),'Target':'/var/lib/opencloud'}]}}}}]))
        self.name='opencloud-dev-20261124T130247423653380Z-00000001'
        self.borg('create',str(self.repo)+'::'+self.name,str(self.data),str(config),str(service))
    def borg(self,*args):
        subprocess.run(['borg',*args],env=self.env,check=True,capture_output=True)
    def run_script(self,name,*args):
        return subprocess.run([str(self.root/'scripts'/name),*args],env=self.env,text=True,capture_output=True)
    def test_restore_and_protected_paths(self):
        target=self.p/'restored'; r=self.run_script('restore.sh','--env','dev','--target',str(target)); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((target/'storage/users/control').read_bytes(),b'synthetic control')
        self.assertEqual(os.getxattr(target/'storage/users/control','user.oc.id'),b'synthetic-id')
        conf=next(x.split('=',1)[1] for x in r.stdout.splitlines() if x.startswith('CONFIG_PATH=')); self.addCleanup(shutil.rmtree,Path(conf).parent)
        self.assertEqual(Path(conf).read_text(),'synthetic: true\n')
        self.assertNotEqual(self.run_script('restore.sh','--env','dev','--target',str(target)).returncode,0)
        self.assertNotEqual(self.run_script('restore.sh','--env','dev','--target',str(self.data/'new')).returncode,0)
    def test_smoke_and_failure_preserves_success(self):
        r=self.run_script('test-restore.sh','--env','dev'); self.assertEqual(r.returncode,0,r.stderr)
        metrics=self.metrics/'opencloud_restore_smoke.prom'; before=metrics.read_text()
        self.assertIn('opencloud_restore_smoke_last_status{env="dev",service="opencloud"} 1',before)
        success=next(s for s in before.splitlines() if s.startswith('opencloud_restore_smoke_last_success_timestamp_seconds{'))
        time.sleep(1)
        r=self.run_script('test-restore.sh','--env','dev','--archive','wrong-archive'); self.assertNotEqual(r.returncode,0)
        after=metrics.read_text(); self.assertIn(success,after)
        self.assertIn('opencloud_restore_smoke_last_status{env="dev",service="opencloud"} 0',after)
        self.assertFalse(list(self.p.glob('.opencloud-smoke.*')))

    def test_explicit_repository_copy(self):
        copy=self.p/'repository-copy'; shutil.copytree(self.repo,copy)
        target=self.p/'from-copy'
        self.env['BORG_RELOCATED_REPO_ACCESS_IS_OK']='yes'
        r=self.run_script('restore.sh','--env','dev','--repo',str(copy),'--target',str(target))
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((target/'storage/users/control').read_bytes(),b'synthetic control')
        conf=next(x.split('=',1)[1] for x in r.stdout.splitlines() if x.startswith('CONFIG_PATH='))
        self.addCleanup(shutil.rmtree,Path(conf).parent)

if __name__=='__main__': unittest.main()
