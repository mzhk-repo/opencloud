#!/usr/bin/env bash
# Category 1b: reconcile OpenCloud's versioned Swarm Secret.
# Example: SERVER_ENV=dev ./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-map.env
set -euo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
env_file='' mapping_file='' environment='' approval='' apply=false
while (($#)); do
  case "$1" in
    -env-file|-mapping-file|-environment|-approval-context)
      (($# >= 2)) || die "missing value for $1"
      case "$1" in
        -env-file) env_file=$2 ;;
        -mapping-file) mapping_file=$2 ;;
        -environment) environment=$2 ;;
        -approval-context) approval=$2 ;;
      esac
      shift 2 ;;
    -apply) apply=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -f "$env_file" && ! -L "$env_file" ]] || die 'env file must be an existing regular non-symlink file'
[[ "$mapping_file" = /* && ! -L "$mapping_file" && ( ! -e "$mapping_file" || -f "$mapping_file" ) ]] || die 'mapping file must be an absolute regular non-symlink path'
[[ ! -e "$mapping_file" || ! "$env_file" -ef "$mapping_file" ]] || die 'mapping file must differ from env file'
[[ -d "$(dirname "$mapping_file")" ]] || die 'mapping directory does not exist'

# Read one literal value, never execute the host environment file.
host_env=$(python3 - <<'PY'
import re
from pathlib import Path
lines = Path('/etc/environment').read_text().splitlines()
values = []
for line in lines:
    match = re.fullmatch(r'''\s*SERVER_ENV\s*=\s*(?:"(dev|prod)"|'(dev|prod)'|(dev|prod))\s*''', line)
    if match:
        values.append(next(v for v in match.groups() if v is not None))
    elif re.match(r'^\s*SERVER_ENV\s*=', line):
        raise SystemExit('invalid SERVER_ENV in /etc/environment')
if len(values) != 1:
    raise SystemExit('expected exactly one SERVER_ENV in /etc/environment')
print(values[0])
PY
) || die 'cannot determine host SERVER_ENV'
[[ "${SERVER_ENV:-}" == "$host_env" ]] || die 'exported SERVER_ENV must match /etc/environment'
environment=${environment:-$host_env}
case "$environment" in development) environment=dev ;; production) environment=prod ;; dev|prod) ;; *) die 'environment must be dev or prod' ;; esac
[[ "$environment" == "$host_env" ]] || die 'environment does not match host SERVER_ENV'
if [[ "$apply" == true && "$environment" == prod ]]; then
  [[ "$approval" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{7,127}$ ]] || die 'prod apply requires an approval context identifier'
fi
[[ $(stat -f -c %T /dev/shm) == tmpfs ]] || die '/dev/shm must be tmpfs'
stage=$(mktemp -d /dev/shm/opencloud-secret.XXXXXXXX)
map_tmp=''
cleanup() { rm -rf -- "$stage"; [[ -z "$map_tmp" ]] || rm -f -- "$map_tmp"; }
trap cleanup EXIT
if [[ "$env_file" == *.enc ]]; then
  [[ "${env_file##*/}" == "env.${host_env}.enc" ]] || die 'encrypted env filename must match host SERVER_ENV'
  command -v sops >/dev/null || die 'sops is required'
  grep -q '^sops_version=' "$env_file" || die 'encrypted dotenv metadata is missing'
  sops --decrypt --input-type dotenv --output-type dotenv "$env_file" > "$stage/env" 2>/dev/null || die 'SOPS decryption or integrity verification failed'
else
  mode=$(stat -c '%a' "$env_file")
  (( (8#$mode & 077) == 0 )) || die 'plaintext environment file must be owner-only'
  cp -- "$env_file" "$stage/env"
fi
chmod 400 "$stage/env"
python3 - "$stage/env" "$stage/opencloud.yaml" <<'PY'
import base64
import binascii
import re
import sys
from pathlib import Path

values = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    match = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)', line)
    if not match or match[1] in values:
        sys.exit('ERROR: invalid or duplicate dotenv entry')
    values[match[1]] = match[2]
    if not match[2] or match[2].startswith('REPLACE_WITH_'):
        sys.exit('ERROR: an environment value is empty or a placeholder')
key = 'OPENCLOUD_YAML_B64'
value = values.get(key, '')
if not value or value.startswith('REPLACE_WITH_'):
    sys.exit('ERROR: OPENCLOUD_YAML_B64 is missing or a placeholder')
try:
    data = base64.b64decode(value, validate=True)
except (ValueError, binascii.Error):
    sys.exit('ERROR: OPENCLOUD_YAML_B64 is invalid base64')
if not data or b'\0' in data or b'REPLACE_WITH_' in data:
    sys.exit('ERROR: decoded OpenCloud configuration is empty or invalid')
Path(sys.argv[2]).write_bytes(data)
PY
chmod 400 "$stage/opencloud.yaml"
hash=$(sha256sum "$stage/opencloud.yaml")
secret="opencloud_opencloud_yaml_v${hash:0:16}"
if [[ "$apply" != true ]]; then
  printf 'Dry run successful; secret name: %s\n' "$secret"
  exit 0
fi
command -v docker >/dev/null || die 'docker is required for apply'
docker secret ls --format '{{.Name}}' > "$stage/secrets" || die 'cannot list Swarm secrets; run on a Swarm manager'
if ! grep -Fxq -- "$secret" "$stage/secrets"; then
  docker secret create "$secret" "$stage/opencloud.yaml" >/dev/null || die 'cannot create Swarm secret'
fi
map_tmp=$(mktemp "$(dirname "$mapping_file")/.opencloud-map.XXXXXXXX")
printf 'OPENCLOUD_YAML_SECRET_NAME=%s\n' "$secret" > "$map_tmp"
mv -f -- "$map_tmp" "$mapping_file"
map_tmp=''
printf 'Secret mapping updated: %s\n' "$mapping_file"
