#!/usr/bin/env python3
"""Isolated orchestration checks using fake Docker and preparation helpers."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        if os.environ.get('SERVER_ENV') != 'dev' or 'SERVER_ENV=dev' not in Path('/etc/environment').read_text():
            self.skipTest('requires the dev host environment')
        self.tmp = tempfile.TemporaryDirectory(prefix='oc-orchestrator-test-', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        shutil.copy(ROOT / 'scripts/deploy-orchestrator-swarm.sh', self.root / 'scripts')
        shutil.copy(ROOT / 'scripts/ci-deploy-swarm.sh', self.root / 'scripts')
        (self.root / 'docker-stack.yml').write_text('services: {}\n')
        self.envfile = self.root / 'input.env'
        self.envfile.write_text('OPENCLOUD_IMAGE_TAG=7.2.5\nOPENCLOUD_DOMAIN=example.test\nENTRA_TENANT_ID=11111111-1111-4111-8111-111111111111\nENTRA_CLIENT_ID=22222222-2222-4222-8222-222222222222\n')
        self.envfile.chmod(0o600)
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + ':/usr/bin:/bin', SERVER_ENV='dev', ORCHESTRATOR_MODE='swarm', ENVIRONMENT_NAME='development', STACK_NAME='opencloudtest', ORCHESTRATOR_ENV_FILE=str(self.envfile))
        self.trace = self.root / 'trace'
        self.model = {'services': {'opencloud': {'deploy': {'replicas': 1, 'update_config': {'order': 'stop-first'}, 'placement': {'constraints': ['node.labels.storage == primary']}, 'labels': {'traefik.enable': 'true'}}, 'healthcheck': {'test': ['CMD', 'true']}}}, 'secrets': {'opencloud_yaml': {'external': True}}}
        self.write_model()
        self.executable('scripts/render-proxy-config.py', '''#!/usr/bin/env python3
import os
from pathlib import Path
Path(os.environ['OPENCLOUD_PROXY_CONFIG_FILE']).write_text('role_assignment: {}\\n')
print('OPENCLOUD_PROXY_CONFIG_NAME=opencloud_dev_proxy_v1111111111111111')
print('OPENCLOUD_ENTRA_CSP_CONFIG_NAME=opencloud_dev_csp_v2222222222222222')
''')
        self.executable('scripts/reconcile-sops-secrets.sh', '''#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ " $* " == *" -apply "* ]]; then
  echo reconcile >> "$root/trace"
  [[ ! -e "$root/fail_reconcile" ]] || exit 1
  while (($#)); do if [[ $1 == -mapping-file ]]; then printf '%s\\n' OPENCLOUD_YAML_SECRET_NAME=opencloud_opencloud_yaml_v3333333333333333 > "$2"; break; fi; shift; done
else
  echo 'Dry run successful; secret name: opencloud_opencloud_yaml_v3333333333333333'
fi
''')
        for step in ('init-volumes', 'preflight-host'):
            self.executable('scripts/' + step + '.sh', f'''#!/bin/bash
root=$(cd "$(dirname "$0")/.." && pwd)
echo {step} >> "$root/trace"
[[ ! -e "$root/fail_{step}" ]]
''')
        self.executable('bin/docker', '''#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
a=sys.argv[1:]
if a[0]=='compose': print((root/'model.json').read_text())
elif a[:2]==['stack','config']: pass
elif a[:2]==['stack','deploy']:
 with (root/'trace').open('a') as f: f.write('deploy\\n')
 if (root/'fail_deploy').exists(): sys.exit(1)
elif a[0]=='info': print('active true' if 'ControlAvailable' in a[-1] else 'node123')
elif a[:2]==['node','ls']: print('remote-node' if (root/'remote_node').exists() else 'node123')
elif a[:2]==['node','inspect']: print('ready active')
elif a[:2]==['service','inspect']: print('completed')
elif a[0]=='ps': print('container123')
elif a[0]=='inspect': print('unhealthy' if (root/'unhealthy').exists() else 'healthy')
else: sys.exit(1)
''')
        self.executable('bin/curl', "#!/bin/sh\nprintf 200\n")
        self.executable('bin/sleep', "#!/bin/sh\nexit 0\n")

    def executable(self, name, content):
        p = self.root / name
        p.write_text(content)
        p.chmod(0o755)

    def write_model(self):
        (self.root / 'model.json').write_text(json.dumps(self.model))

    def run_script(self, *args, env=None):
        return subprocess.run([str(self.root / 'scripts/deploy-orchestrator-swarm.sh'), *args], env=env or self.env, text=True, capture_output=True, timeout=15)

    def events(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def test_success_order(self):
        result = self.run_script('--deploy', '--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ['init-volumes', 'preflight-host', 'reconcile', 'deploy'])

    def test_check_changes_no_state(self):
        result = self.run_script('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), [])

    def test_ci_adapter_uses_explicit_deploy(self):
        env = self.env.copy()
        env.pop('STACK_NAME')
        result = subprocess.run([str(self.root / 'scripts/ci-deploy-swarm.sh')], env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ['init-volumes', 'preflight-host', 'reconcile', 'deploy'])

    def test_missing_health_and_bad_policy_stop_before_mutation(self):
        del self.model['services']['opencloud']['healthcheck']
        self.write_model()
        result = self.run_script('--deploy', '--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('healthcheck', result.stderr)
        self.assertEqual(self.events(), [])
        self.model['services']['opencloud']['deploy']['replicas'] = 2
        self.write_model()
        self.assertNotEqual(self.run_script('--deploy', '--apply').returncode, 0)
        self.assertEqual(self.events(), [])

    def test_preflight_failure_stops_before_reconcile_and_deploy(self):
        (self.root / 'fail_preflight-host').touch()
        self.assertNotEqual(self.run_script('--deploy', '--apply').returncode, 0)
        self.assertEqual(self.events(), ['init-volumes', 'preflight-host'])

    def test_reconciliation_failure_stops_before_deploy(self):
        (self.root / 'fail_reconcile').touch()
        self.assertNotEqual(self.run_script('--deploy', '--apply').returncode, 0)
        self.assertEqual(self.events(), ['init-volumes', 'preflight-host', 'reconcile'])

    def test_dotenv_value_is_never_executed(self):
        marker = self.root / 'executed'
        self.envfile.write_text(f'OPENCLOUD_IMAGE_TAG=7.2.5\nOPENCLOUD_DOMAIN=$(touch {marker})\n')
        result = self.run_script('--deploy', '--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertFalse(marker.exists())

    def test_production_without_approval_fails_before_mutation(self):
        env = self.env.copy()
        env['ENVIRONMENT_NAME'] = 'production'
        self.assertNotEqual(self.run_script('--deploy', '--apply', env=env).returncode, 0)
        self.assertEqual(self.events(), [])

    def test_remote_storage_is_rejected_before_mutation(self):
        (self.root / 'remote_node').touch()
        result = self.run_script('--deploy', '--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('remote storage preparation is not implemented', result.stderr)
        self.assertEqual(self.events(), [])

    def test_unhealthy_service_times_out(self):
        (self.root / 'unhealthy').touch()
        result = self.run_script('--deploy', '--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('timed out', result.stderr)
        self.assertEqual(self.events(), ['init-volumes', 'preflight-host', 'reconcile', 'deploy'])


if __name__ == '__main__':
    unittest.main()
