#!/usr/bin/env bash
# Category 1b: validate and deploy the OpenCloud Swarm stack.
# Example: ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development STACK_NAME=opencloud ORCHESTRATOR_ENV_FILE=env.dev.enc ./scripts/deploy-orchestrator-swarm.sh --check
set -euo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[opencloud-orchestrator] %s\n' "$*" >&2; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
operation='' apply=false approval=''
while (($#)); do
  case "$1" in
    --check|--deploy) [[ -z "$operation" ]] || die 'choose one operation'; operation=${1#--}; shift ;;
    --apply) apply=true; shift ;;
    --approval-context) (($# >= 2)) || die 'missing approval context'; approval=$2; shift 2 ;;
    --help) printf '%s\n' 'Usage: deploy-orchestrator-swarm.sh --check | --deploy --apply [--approval-context ID]'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$operation" ]] || die 'choose --check or --deploy'
[[ "${ORCHESTRATOR_MODE:-}" == swarm ]] || die 'ORCHESTRATOR_MODE must be swarm'
case "${ENVIRONMENT_NAME:-}" in development) environment=dev ;; production) environment=prod ;; *) die 'ENVIRONMENT_NAME must be development or production' ;; esac
[[ "${STACK_NAME:-}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die 'STACK_NAME must be a safe lowercase stack name'
if [[ "$operation" == deploy ]]; then
  [[ "$apply" == true ]] || die '--deploy requires --apply'
  if [[ "$environment" == prod ]]; then
    [[ "$approval" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{7,127}$ ]] || die 'production deploy requires an approval context identifier'
  fi
else
  [[ "$apply" == false && -z "$approval" ]] || die '--check does not accept --apply or --approval-context'
fi
[[ -n "${ORCHESTRATOR_ENV_FILE:-}" && -f "$ORCHESTRATOR_ENV_FILE" && ! -L "$ORCHESTRATOR_ENV_FILE" ]] || die 'ORCHESTRATOR_ENV_FILE must be an existing regular non-symlink file'
source_file=$(realpath -- "$ORCHESTRATOR_ENV_FILE")
[[ $(stat -f -c %T /dev/shm) == tmpfs ]] || die '/dev/shm must be tmpfs'
for tool in docker python3 curl timeout; do command -v "$tool" >/dev/null || die "$tool is required"; done

# Check the host identity without executing /etc/environment.
python3 - "$environment" <<'PY' || die 'host environment validation failed'
import os
from pathlib import Path
import re
import sys
values = []
for line in Path('/etc/environment').read_text().splitlines():
    match = re.fullmatch(r'''\s*SERVER_ENV\s*=\s*(?:"(dev|prod)"|'(dev|prod)'|(dev|prod))\s*''', line)
    if match:
        values.append(next(value for value in match.groups() if value is not None))
    elif re.match(r'^\s*SERVER_ENV\s*=', line):
        sys.exit(1)
if values != [sys.argv[1]] or os.environ.get('SERVER_ENV') != sys.argv[1]:
    sys.exit(1)
PY
stage=$(mktemp -d /dev/shm/opencloud-deploy.XXXXXXXX)
trap 'rm -rf -- "$stage"' EXIT
if [[ "$source_file" == *.enc ]]; then
  [[ "${source_file##*/}" == "env.${environment}.enc" ]] || die 'encrypted env filename must match host environment'
  command -v sops >/dev/null || die 'sops is required'
  sops --decrypt --input-type dotenv --output-type dotenv "$source_file" > "$stage/env" 2>/dev/null || die 'SOPS decryption or integrity verification failed'
else
  mode=$(stat -c '%a' "$source_file")
  (( (8#$mode & 077) == 0 )) || die 'plaintext env file must be owner-only'
  cp -- "$source_file" "$stage/env"
fi
chmod 600 "$stage/env"

# Export only validated, non-secret values required by the stack.
python3 - "$stage/env" > "$stage/stack.env" <<'PY' || die 'deployment values are invalid'
from pathlib import Path
import re
import sys
import uuid
keys = ('OPENCLOUD_IMAGE', 'OPENCLOUD_IMAGE_TAG', 'OPENCLOUD_DOMAIN', 'ENTRA_TENANT_ID', 'ENTRA_CLIENT_ID', 'OPENCLOUD_MEM_LIMIT', 'OPENCLOUD_DATA_PATH', 'OPENCLOUD_UID', 'OPENCLOUD_GID')
values = {'OPENCLOUD_IMAGE': 'opencloudeu/opencloud', 'OPENCLOUD_MEM_LIMIT': '2.5G', 'OPENCLOUD_DATA_PATH': '/srv/opencloud/data', 'OPENCLOUD_UID': '1000', 'OPENCLOUD_GID': '1000'}
seen = set()
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line.strip() or line.startswith('#'):
        continue
    key, sep, value = line.partition('=')
    if not sep or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key) or key in seen:
        sys.exit('ERROR: malformed or duplicate dotenv entry')
    seen.add(key)
    if key in keys:
        values[key] = value
for key in keys:
    value = values.get(key, '')
    if not value or value.startswith('REPLACE_WITH_') or not re.fullmatch(r'[A-Za-z0-9._/:@-]+', value):
        sys.exit('ERROR: missing or invalid deployment setting: ' + key)
for key in ('ENTRA_TENANT_ID', 'ENTRA_CLIENT_ID'):
    try:
        parsed = uuid.UUID(values[key])
        if str(parsed) != values[key].lower() or parsed.int == 0:
            raise ValueError
    except ValueError:
        sys.exit('ERROR: invalid UUID: ' + key)
if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', values['OPENCLOUD_DOMAIN']):
    sys.exit('ERROR: invalid OpenCloud domain')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?[kKmMgG]', values['OPENCLOUD_MEM_LIMIT']):
    sys.exit('ERROR: invalid memory limit')
for key in ('OPENCLOUD_UID', 'OPENCLOUD_GID'):
    if not re.fullmatch(r'[1-9][0-9]{0,9}', values[key]) or int(values[key]) >= 4294967295:
        sys.exit('ERROR: invalid numeric ID: ' + key)
for key in keys:
    print(key + '=' + values[key])
PY
while IFS= read -r line; do export "${line?}"; done < "$stage/stack.env"
export OPENCLOUD_PROXY_CONFIG_FILE="$stage/proxy.yaml"
python3 "$root/scripts/render-proxy-config.py" --env-file "$stage/env" > "$stage/config-map" || die 'group mapping generation failed'
while IFS= read -r line; do
  [[ "$line" =~ ^OPENCLOUD_(PROXY|ENTRA_CSP)_CONFIG_NAME=opencloud_(dev|prod)_[a-z]+_v[0-9a-f]{16}$ ]] || die 'invalid config mapping'
  export "${line?}"
done < "$stage/config-map"
[[ -n "${OPENCLOUD_PROXY_CONFIG_NAME:-}" && -n "${OPENCLOUD_ENTRA_CSP_CONFIG_NAME:-}" ]] || die 'incomplete config mapping'
secret_dry=$(
  "$root/scripts/reconcile-sops-secrets.sh" -env-file "$stage/env" -environment "$environment" -mapping-file "$stage/secret-map"
) || die 'secret reconciliation dry run failed'
OPENCLOUD_YAML_SECRET_NAME=${secret_dry#'Dry run successful; secret name: '}
[[ "$OPENCLOUD_YAML_SECRET_NAME" =~ ^opencloud_opencloud_yaml_v[0-9a-f]{16}$ ]] || die 'invalid secret name from dry run'
export OPENCLOUD_YAML_SECRET_NAME

docker_env=("PATH=$PATH" "HOME=${HOME:-/}" "OPENCLOUD_PROXY_CONFIG_FILE=$OPENCLOUD_PROXY_CONFIG_FILE" "OPENCLOUD_YAML_SECRET_NAME=$OPENCLOUD_YAML_SECRET_NAME" "OPENCLOUD_PROXY_CONFIG_NAME=$OPENCLOUD_PROXY_CONFIG_NAME" "OPENCLOUD_ENTRA_CSP_CONFIG_NAME=$OPENCLOUD_ENTRA_CSP_CONFIG_NAME")
while IFS= read -r line; do docker_env+=("$line"); done < "$stage/stack.env"
for key in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
  [[ ! -v "$key" ]] || docker_env+=("$key=${!key}")
done
docker_clean() { env -i "${docker_env[@]}" docker "$@"; }

cd "$root"
docker_clean compose --env-file "$stage/stack.env" -f docker-stack.yml config --format json > "$stage/stack.json" || die 'stack configuration is invalid'
python3 - "$stage/stack.json" <<'PY' || die 'stack policy validation failed'
import json
from pathlib import Path
import sys
x = json.loads(Path(sys.argv[1]).read_text())
services = x.get('services', {})
if set(services) != {'opencloud'}:
    sys.exit('ERROR: stack must contain only the opencloud service')
s = services['opencloud']
d = s.get('deploy', {})
if d.get('replicas') != 1 or d.get('update_config', {}).get('order') != 'stop-first':
    sys.exit('ERROR: stack requires one replica and stop-first updates')
if d.get('placement', {}).get('constraints') != ['node.labels.storage == primary']:
    sys.exit('ERROR: storage placement constraint is missing or changed')
if s.get('ports'):
    sys.exit('ERROR: published ports are not allowed')
if set(x.get('secrets', {})) != {'opencloud_yaml'} or not x['secrets']['opencloud_yaml'].get('external'):
    sys.exit('ERROR: the OpenCloud secret must be external')
h = s.get('healthcheck', {})
if not h.get('test') or h.get('disable') or h.get('test', [])[0] == 'NONE':
    sys.exit('ERROR: stack has no enabled healthcheck; complete task 6.1 before deploying')
labels = d.get('labels', {})
if labels.get('traefik.enable', '').lower() != 'true':
    sys.exit('ERROR: Traefik routing is not configured; complete task 5.4 before deploying')
PY
docker_clean stack config -c docker-stack.yml > /dev/null || die 'Swarm stack configuration is invalid'
[[ "$(docker_clean info --format '{{.Swarm.LocalNodeState}} {{.Swarm.ControlAvailable}}')" == 'active true' ]] || die 'an active Swarm manager is required'
node_id=$(docker_clean info --format '{{.Swarm.NodeID}}')
node_list=$(docker_clean node ls --quiet --filter 'node.label=storage=primary') || die 'cannot list storage nodes'
[[ -z "$node_list" || "$node_list" == "$node_id" ]] || die 'storage=primary is already assigned to another node or to multiple nodes'
[[ "$(docker_clean node inspect "$node_id" --format '{{.Status.State}} {{.Spec.Availability}}')" == 'ready active' ]] || die 'storage node must be ready and active'
node_label=$(docker_clean node inspect "$node_id" --format '{{if index .Spec.Labels "storage"}}{{index .Spec.Labels "storage"}}{{end}}') || die 'cannot inspect storage label'
[[ -z "$node_label" || "$node_label" == primary ]] || die 'current manager already has a different storage label'
if [[ -n "$node_list" ]]; then
  [[ "$node_label" == primary ]] || die 'storage label changed during validation; retry'
else
  [[ -z "$node_label" ]] || die 'storage label changed during validation; retry'
fi
log 'environment, stack policies and local storage node verified'
if [[ "$operation" == check ]]; then
  [[ -n "$node_list" ]] || log 'deployment will assign storage=primary to this manager'
  log 'check passed; no data directory, Swarm Secret or service was changed'
  exit 0
fi

if [[ -z "$node_list" ]]; then
  docker_clean node update --label-add storage=primary "$node_id" > /dev/null || die 'cannot assign storage=primary to the current manager'
  node_list=$(docker_clean node ls --quiet --filter 'node.label=storage=primary') || die 'cannot verify storage nodes after labeling'
  [[ "$node_list" == "$node_id" ]] || die 'storage label conflict after assignment; review labels before retrying'
  log 'assigned storage=primary to the current manager'
fi
ORCHESTRATOR_ENV_FILE="$stage/env" "$root/scripts/init-volumes.sh"
"$root/scripts/preflight-host.sh" "$OPENCLOUD_DATA_PATH"
args=(-env-file "$stage/env" -environment "$environment" -mapping-file "$stage/secret-map" -apply)
[[ -z "$approval" ]] || args+=(-approval-context "$approval")
"$root/scripts/reconcile-sops-secrets.sh" "${args[@]}"
[[ "$(cat "$stage/secret-map")" == "OPENCLOUD_YAML_SECRET_NAME=$OPENCLOUD_YAML_SECRET_NAME" ]] || die 'reconciled secret name changed after dry run'
timeout 300 env -i "${docker_env[@]}" docker stack deploy --detach=false --compose-file docker-stack.yml "$STACK_NAME" || die 'stack deployment failed or timed out'
service="${STACK_NAME}_opencloud"
for ((attempt=0; attempt<60; attempt++)); do
  update_state=$(docker_clean service inspect "$service" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)
  [[ "$update_state" != paused && "$update_state" != rollback_started && "$update_state" != rollback_paused && "$update_state" != rollback_completed ]] || die 'service update failed or rolled back'
  mapfile -t containers < <(docker_clean ps --filter "label=com.docker.swarm.service.name=$service" --format '{{.ID}}')
  if [[ ${#containers[@]} -eq 1 ]]; then
    health=$(docker_clean inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "${containers[0]}" 2>/dev/null || true)
    if [[ "$health" == healthy && ( -z "$update_state" || "$update_state" == completed ) ]]; then
      status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${OPENCLOUD_DOMAIN}/" || true)
      [[ "$status" == 200 ]] && { log 'service is healthy and HTTPS returned 200'; exit 0; }
    fi
  fi
  sleep 5
done
die 'timed out waiting for a healthy service and HTTP 200; inspect the stack before retrying'
