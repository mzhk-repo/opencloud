#!/usr/bin/env bash
# Create a consistent local Borg archive and copy its repository off site.
set -euo pipefail
umask 077
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[opencloud-backup] %s\n' "$*" >&2; }
environment=${SERVER_ENV:-}
retry=false
while (($#)); do
  case "$1" in
    dev|development) environment=dev ;;
    prod|production) environment=prod ;;
    --retry-copy) retry=true ;;
    *) die "invalid argument: $1" ;;
  esac
  shift
done
[[ $environment == dev || $environment == prod ]] || die 'select dev or prod'
[[ ${SERVER_ENV:-} == "$environment" ]] || die 'SERVER_ENV must match the selected environment'
python3 - "$environment" <<'PY' || die 'host SERVER_ENV does not match'
import re, sys
from pathlib import Path
values = []
for line in Path('/etc/environment').read_text().splitlines():
    m = re.fullmatch(r'''\s*SERVER_ENV\s*=\s*(?:"(dev|prod)"|'(dev|prod)'|(dev|prod))\s*''', line)
    if m: values.append(next(v for v in m.groups() if v is not None))
    elif re.match(r'^\s*SERVER_ENV\s*=', line): sys.exit(1)
if values != [sys.argv[1]]: sys.exit(1)
PY
[[ $(stat -f -c %T /dev/shm) == tmpfs ]] || die '/dev/shm must be tmpfs'
for tool in sops python3; do command -v "$tool" >/dev/null || die "$tool is required"; done
stage=$(mktemp -d /dev/shm/opencloud-backup.XXXXXXXX)
restart=false
stop_started=0
metrics_dir=''
status=0
started=$(date +%s)
cleanup() {
  local rc=$? previous=0 tmp=''
  trap - EXIT
  if [[ $restart == true ]]; then
    if ! docker service scale --detach=false "${service}=1" >/dev/null; then
      log 'ERROR: failed to restart service; intervene manually'
      rc=1
    else
      log "service restart requested after $(( $(date +%s) - stop_started )) seconds"
    fi
  fi
  if [[ -n $metrics_dir ]]; then
    if [[ -f $metrics_dir/opencloud_backup.prom ]]; then
      previous=$(sed -n "s/^opencloud_backup_last_success_timestamp_seconds{env=\"$environment\",service=\"opencloud\"} \([0-9][0-9]*\)$/\1/p" "$metrics_dir/opencloud_backup.prom" | tail -1)
      [[ $previous =~ ^[0-9]+$ ]] || previous=0
    fi
    if (( rc == 0 )) && [[ $status == 1 ]]; then previous=$(date +%s); else status=0; fi
    if tmp=$(mktemp "$metrics_dir/.opencloud_backup.XXXXXXXX") &&
      printf 'opencloud_backup_last_run_timestamp_seconds{env="%s",service="opencloud"} %s\nopencloud_backup_last_success_timestamp_seconds{env="%s",service="opencloud"} %s\nopencloud_backup_last_status{env="%s",service="opencloud"} %s\n' "$environment" "$started" "$environment" "$previous" "$environment" "$status" > "$tmp" &&
      chmod 644 "$tmp" && mv -f -- "$tmp" "$metrics_dir/opencloud_backup.prom"; then :
    else
      log 'ERROR: failed to write backup metrics'
      [[ -z $tmp ]] || rm -f -- "$tmp"
      rc=1
    fi
  fi
  rm -rf -- "$stage" || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
env_file="$root/env.$environment.enc"
[[ -f $env_file && ! -L $env_file ]] || die 'encrypted environment file is missing'
sops --decrypt --input-type dotenv --output-type dotenv "$env_file" > "$stage/env" 2>/dev/null || die 'SOPS decryption failed'
python3 - "$stage/env" "$stage" <<'PY'
import base64, binascii, os, re, sys
from pathlib import Path
values = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line.strip() or line.startswith('#'): continue
    m = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)', line)
    if not m or m[1] in values: sys.exit('ERROR: invalid dotenv')
    values[m[1]] = m[2]
keys = ('OPENCLOUD_DATA_PATH', 'BACKUP_LOCAL_DIR', 'BACKUP_RCLONE_REMOTE', 'BACKUP_RCLONE_FOLDER', 'BACKUP_RCLONE_MOUNT', 'NODE_EXPORTER_TEXTFILE_DIR', 'BORG_PASSPHRASE', 'OPENCLOUD_YAML_B64')
for k in keys:
    if not values.get(k) or values[k].startswith('REPLACE_WITH_'): sys.exit('ERROR: missing or placeholder setting: ' + k)
for k in ('OPENCLOUD_DATA_PATH', 'BACKUP_LOCAL_DIR', 'BACKUP_RCLONE_MOUNT', 'NODE_EXPORTER_TEXTFILE_DIR'):
    p = values[k]
    if not os.path.isabs(p) or p == '/' or os.path.normpath(p) != p or os.path.realpath(p) != p or any(ord(c) < 32 for c in p): sys.exit('ERROR: invalid path: ' + k)
if os.path.commonpath([values['OPENCLOUD_DATA_PATH'], values['BACKUP_LOCAL_DIR']]) in (values['OPENCLOUD_DATA_PATH'], values['BACKUP_LOCAL_DIR']): sys.exit('ERROR: backup and data paths overlap')
if os.path.commonpath([values['BACKUP_RCLONE_MOUNT'], values['BACKUP_LOCAL_DIR']]) in (values['BACKUP_RCLONE_MOUNT'], values['BACKUP_LOCAL_DIR']): sys.exit('ERROR: local backup and rclone mount overlap')
if not re.fullmatch(r'[A-Za-z0-9_-]+', values['BACKUP_RCLONE_REMOTE']) or not re.fullmatch(r'[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*', values['BACKUP_RCLONE_FOLDER']): sys.exit('ERROR: invalid rclone target')
try: config = base64.b64decode(values['OPENCLOUD_YAML_B64'], validate=True)
except (ValueError, binascii.Error): sys.exit('ERROR: invalid OpenCloud configuration encoding')
if not config or b'\0' in config: sys.exit('ERROR: invalid OpenCloud configuration')
Path(sys.argv[2], 'opencloud.yaml').write_bytes(config)
with open(Path(sys.argv[2], 'settings'), 'wb') as f:
    for k in keys[:-1]: f.write(values[k].encode() + b'\0')
PY
mapfile -d '' -t settings < "$stage/settings"
data=${settings[0]} backup_dir=${settings[1]} remote=${settings[2]} folder=${settings[3]} mount=${settings[4]} metrics_dir=${settings[5]}
export BORG_PASSPHRASE=${settings[6]}
unset settings
[[ -d $metrics_dir ]] || die 'metrics directory does not exist'
for tool in borg rclone docker flock findmnt; do command -v "$tool" >/dev/null || die "$tool is required"; done
version=$(borg --version)
if ! [[ "$version" =~ ^borg\ 1\.([0-9]+)\. ]] || (( BASH_REMATCH[1] < 2 )); then die "Borg 1.2 or newer in the 1.x series is required; found $version"; fi
[[ -d $backup_dir && ! -L $backup_dir ]] || die 'local backup directory does not exist'
exec 9>"$backup_dir/.opencloud-backup.lock"
flock -n 9 || die 'another backup is running'
[[ ${STACK_NAME:-} =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die 'STACK_NAME is required'
service="${STACK_NAME}_opencloud"
repo="$backup_dir/repository"
pending="$backup_dir/.opencloud-pending"
if [[ $retry == false ]]; then
  [[ ! -e $pending ]] || die 'a copy is pending; run --retry-copy first'
  [[ -d $data ]] || die 'data directory does not exist'
  docker service inspect "$service" > "$stage/service.json" || die 'cannot inspect service'
  python3 - "$stage/service.json" "$data" "$stage/opencloud.yaml" <<'PY' || die 'service configuration or data mount does not match'
import hashlib, json, os, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())[0]['Spec']
t = s['TaskTemplate']['ContainerSpec']
if s.get('Mode', {}).get('Replicated', {}).get('Replicas') not in (0, 1): sys.exit(1)
mounts = [m for m in t.get('Mounts', []) if m.get('Target') == '/var/lib/opencloud']
if len(mounts) != 1 or mounts[0].get('Type') != 'bind' or os.path.realpath(mounts[0].get('Source', '')) != sys.argv[2]: sys.exit(1)
expected = 'opencloud_opencloud_yaml_v' + hashlib.sha256(Path(sys.argv[3]).read_bytes()).hexdigest()[:16]
secrets = [x['SecretName'] for x in t.get('Secrets', []) if x.get('File', {}).get('Name') == '/etc/opencloud/opencloud.yaml']
if secrets != [expected]: sys.exit(1)
if s.get('TaskTemplate', {}).get('Placement', {}).get('Constraints') != ['node.labels.storage == primary']: sys.exit(1)
configs = t.get('Configs', [])
if not configs: sys.exit(1)
with open(Path(sys.argv[3]).parent / 'config-ids', 'w') as f:
    for c in configs:
        ident = c.get('ConfigID', '')
        if not ident.isalnum(): sys.exit(1)
        f.write(ident + '\n')
PY
  mkdir "$stage/swarm-configs"
  while IFS= read -r config_id; do
    docker config inspect "$config_id" > "$stage/swarm-configs/$config_id.json" || die 'cannot save Swarm configuration'
  done < "$stage/config-ids"
  replicas=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["Spec"]["Mode"]["Replicated"]["Replicas"])' "$stage/service.json")
  node=$(docker info --format '{{.Swarm.NodeID}}')
  nodes=$(docker node ls --quiet --filter node.label=storage=primary)
  [[ -n $node && $nodes == "$node" ]] || die 'run on the sole primary storage node'
  if [[ ! -e $repo ]]; then borg init --encryption=repokey-blake2 "$repo" || die 'Borg repository initialization failed'; fi
  [[ -d $repo && ! -L $repo ]] || die 'invalid Borg repository'
  borg info --json "$repo" > "$stage/borg-info" || die 'cannot open Borg repository; check version, format and passphrase'
  python3 - "$stage/borg-info" <<'PY' || die 'Borg repository must be encrypted'
import json, sys
x=json.load(open(sys.argv[1]))
if x.get('encryption', {}).get('mode') in (None, 'none'): sys.exit(1)
PY
  if [[ $replicas == 1 ]]; then
    mapfile -t containers < <(docker ps --filter "label=com.docker.swarm.service.name=$service" --format '{{.ID}}')
    if [[ ${#containers[@]} == 1 ]]; then
      docker exec "${containers[0]}" opencloud storage-users trash-bin purge-expired || log 'WARNING: trash cleanup failed'
      docker exec "${containers[0]}" opencloud storage-users uploads sessions --expired=true --clean || log 'WARNING: upload cleanup failed'
    else log 'WARNING: cannot select a single container for cleanup'; fi
    restart=true
    stop_started=$(date +%s)
    docker service scale --detach=false "${service}=0" >/dev/null || die 'failed to stop service'
  fi
  running=$(docker ps -q --filter "label=com.docker.swarm.service.name=$service") || die 'cannot verify stopped service containers'
  [[ -z $running ]] || die 'service container still runs on storage node'
  stamp=$(date -u +%Y%m%dT%H%M%S%NZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  borg create -- "$repo::opencloud-$environment-$stamp" "$data" "$stage/opencloud.yaml" "$stage/env" "$stage/service.json" "$stage/swarm-configs" || die 'borg create failed'
  printf '%s\n' "$stamp" > "$pending"
  if [[ $restart == true ]]; then
    docker service scale --detach=false "${service}=1" >/dev/null || die 'failed to restart service'
    restart=false
    log "service restart requested after $(( $(date +%s) - stop_started )) seconds"
  fi
  borg prune --list --glob-archives "opencloud-$environment-*" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 "$repo" || die 'borg prune failed; archive retained and copy pending'
  borg compact "$repo" || die 'borg compact failed; copy pending'
else
  [[ -f $pending && ! -L $pending && -d $repo ]] || die 'no pending local copy'
  stamp=$(cat "$pending")
  [[ $stamp =~ ^[0-9]{8}T[0-9]{15}Z-[0-9a-f]{8}$ ]] || die 'invalid pending copy marker'
fi
[[ $(findmnt -n -o FSTYPE --mountpoint "$mount") == fuse.rclone ]] || die 'configured rclone mount is unavailable; local archive retained'
[[ $(findmnt -n -o SOURCE --mountpoint "$mount") == "$remote:" ]] || die 'rclone mount does not match configured remote'
[[ -d $mount/$folder ]] || die 'remote backup folder is missing on the mount'
[[ $(realpath -e -- "$mount/$folder") == "$mount/$folder" ]] || die 'remote backup folder contains a symlink'
dest="$remote:$folder/opencloud-$environment-$stamp"
rclone copy "$repo" "$dest" || die 'rclone copy failed; local archive retained'
printf 'opencloud-backup-v1 %s\n' "$environment" > "$stage/owner"
rclone copyto "$stage/owner" "$dest/.opencloud-backup-owner" || die 'could not mark completed remote copy'
rclone lsf --dirs-only "$remote:$folder" > "$stage/remote-dirs" || die 'cannot list remote copies'
while IFS= read -r item; do
  item=${item%/}
  [[ $item =~ ^opencloud-${environment}-[0-9]{8}T[0-9]{15}Z-[0-9a-f]{8}$ && $item != "opencloud-$environment-$stamp" ]] || continue
  [[ $item < "opencloud-$environment-$stamp" ]] || continue
  owner=$(rclone cat "$remote:$folder/$item/.opencloud-backup-owner" 2>/dev/null) || continue
  [[ $owner == "opencloud-backup-v1 $environment" ]] || continue
  rclone purge "$remote:$folder/$item" || die 'remote retention failed; completed copy retained'
done < "$stage/remote-dirs"
rm -f -- "$pending"
status=1
log 'local archive and offsite copy completed'
