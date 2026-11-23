#!/usr/bin/env python3
"""Render the Swarm group mapping from environment variables."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


def group_id(name, values):
    value = values.get(name, '')
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        sys.exit(f'ERROR: {name} must be a UUID')
    if str(parsed) != value.lower() or parsed.int == 0:
        sys.exit(f'ERROR: {name} must be a canonical nonzero UUID')
    return str(parsed)


environment = os.environ.get('SERVER_ENV', '')
if environment not in ('dev', 'prod'):
    sys.exit('ERROR: SERVER_ENV must be dev or prod')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--env-file', help='SOPS dotenv or owner-only plaintext dotenv')
args = parser.parse_args()
values = os.environ
if args.env_file:
    source = Path(args.env_file)
    if source.is_symlink() or not source.is_file():
        sys.exit('ERROR: env file must be a regular non-symlink file')
    if source.name.endswith('.enc'):
        if source.name != f'env.{environment}.enc':
            sys.exit('ERROR: encrypted env filename must match SERVER_ENV')
        try:
            result = subprocess.run(
                ['sops', '--decrypt', '--input-type', 'dotenv', '--output-type', 'dotenv', str(source)],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            sys.exit('ERROR: SOPS decryption or integrity verification failed')
        lines = result.stdout.splitlines()
    else:
        if source.stat().st_mode & 0o077:
            sys.exit('ERROR: plaintext env file must be owner-only')
        lines = source.read_text().splitlines()
    values = {}
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or key in values:
            sys.exit('ERROR: invalid or duplicate dotenv entry')
        values[key] = value
admin = group_id('ENTRA_ADMIN_GROUP_ID', values)
staff = group_id('ENTRA_STAFF_GROUP_ID', values)
if admin == staff:
    sys.exit('ERROR: admin and staff groups must differ')
path = Path(os.environ.get('OPENCLOUD_PROXY_CONFIG_FILE', './.local/proxy.yaml'))
if path.is_symlink() or (path.exists() and not path.is_file()):
    sys.exit('ERROR: config path must be a regular non-symlink file')
content = (
    '---\nrole_assignment:\n  oidc_role_mapper:\n    role_mapping:\n'
    f'      - role_name: admin\n        claim_value: {admin}\n'
    f'      - role_name: user\n        claim_value: {staff}\n'
)
path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
temp = None
try:
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.proxy-', delete=False) as stream:
        temp = Path(stream.name)
        stream.write(content)
    os.replace(temp, path)
finally:
    if temp is not None:
        temp.unlink(missing_ok=True)
proxy_hash = hashlib.sha256(content.encode()).hexdigest()[:16]
csp = Path(__file__).resolve().parent.parent / 'config/entra-csp.yaml'
csp_hash = hashlib.sha256(csp.read_bytes()).hexdigest()[:16]
print(f'OPENCLOUD_PROXY_CONFIG_NAME=opencloud_{environment}_proxy_v{proxy_hash}')
print(f'OPENCLOUD_ENTRA_CSP_CONFIG_NAME=opencloud_{environment}_csp_v{csp_hash}')
