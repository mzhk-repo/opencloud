#!/usr/bin/env bash
# Category 1b: prepare the OpenCloud data directory without changing existing data.
# Example: ORCHESTRATOR_ENV_FILE=/run/user/1000/opencloud.env ./scripts/init-volumes.sh
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 0 ]] || die 'this script does not accept arguments'
[[ -n "${ORCHESTRATOR_ENV_FILE:-}" && -f "$ORCHESTRATOR_ENV_FILE" && ! -L "$ORCHESTRATOR_ENV_FILE" ]] || die 'ORCHESTRATOR_ENV_FILE must be an existing regular non-symlink file'

settings=$(python3 - "$ORCHESTRATOR_ENV_FILE" <<'PY'
import os
from pathlib import Path
import re
import sys

file = Path(sys.argv[1])
if file.stat().st_mode & 0o077:
    sys.exit('ERROR: environment file must be owner-only')
host_values = []
for line in Path('/etc/environment').read_text().splitlines():
    match = re.fullmatch(r'''\s*SERVER_ENV\s*=\s*(?:"(dev|prod)"|'(dev|prod)'|(dev|prod))\s*''', line)
    if match:
        host_values.append(next(value for value in match.groups() if value is not None))
    elif re.match(r'^\s*SERVER_ENV\s*=', line):
        sys.exit('ERROR: invalid SERVER_ENV in /etc/environment')
if len(host_values) != 1 or os.environ.get('SERVER_ENV') != host_values[0]:
    sys.exit('ERROR: exported SERVER_ENV must match /etc/environment')
values = {'OPENCLOUD_DATA_PATH': '/srv/opencloud/data', 'OPENCLOUD_UID': '1000', 'OPENCLOUD_GID': '1000', 'BACKUP_LOCAL_DIR': '', 'BACKUP_RCLONE_MOUNT': '', 'BACKUP_RCLONE_FOLDER': '', 'BACKUP_RCLONE_REMOTE': ''}
seen = set()
for line in file.read_text().splitlines():
    if re.match(r'\s*(sops_version=|sops:)', line):
        sys.exit('ERROR: environment file must be decrypted plaintext')
    match = re.match(r'^\s*(?:export\s+)?(OPENCLOUD_DATA_PATH|OPENCLOUD_UID|OPENCLOUD_GID|BACKUP_LOCAL_DIR|BACKUP_RCLONE_MOUNT|BACKUP_RCLONE_FOLDER|BACKUP_RCLONE_REMOTE)(?=\s|=|$)', line)
    if not match:
        continue
    key = match[1]
    if key in seen or not line.startswith(key + '='):
        sys.exit('ERROR: duplicate or invalid storage setting')
    seen.add(key)
    values[key] = line[len(key) + 1:]
path = values['OPENCLOUD_DATA_PATH']
if not os.path.isabs(path) or path == '/' or os.path.normpath(path) != path or os.path.realpath(path) != path or any(ord(c) < 32 for c in path):
    sys.exit('ERROR: data path must be an absolute normalized path without symlinks')
for key in ('OPENCLOUD_UID', 'OPENCLOUD_GID'):
    value = values[key]
    if not re.fullmatch(r'[1-9][0-9]{0,9}', value) or int(value) >= 4294967295:
        sys.exit(f'ERROR: {key} must be a valid nonzero numeric ID')
backup_keys = ('BACKUP_LOCAL_DIR', 'BACKUP_RCLONE_MOUNT', 'BACKUP_RCLONE_FOLDER', 'BACKUP_RCLONE_REMOTE')
if any(values[k] for k in backup_keys):
    if not all(values[k] for k in backup_keys):
        sys.exit('ERROR: all backup directory settings are required together')
    for key in backup_keys[:2]:
        p = values[key]
        if not os.path.isabs(p) or p == '/' or os.path.normpath(p) != p or os.path.realpath(p) != p or any(ord(c) < 32 for c in p):
            sys.exit(f'ERROR: invalid {key}')
    folder = values['BACKUP_RCLONE_FOLDER']
    if not re.fullmatch(r'[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*', folder):
        sys.exit('ERROR: invalid backup remote folder')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', values['BACKUP_RCLONE_REMOTE']):
        sys.exit('ERROR: invalid backup remote name')
    remote_path = os.path.join(values['BACKUP_RCLONE_MOUNT'], folder)
    if os.path.realpath(remote_path) != remote_path:
        sys.exit('ERROR: backup remote folder contains a symlink')
    if os.path.commonpath([path, values['BACKUP_LOCAL_DIR']]) in (path, values['BACKUP_LOCAL_DIR']):
        sys.exit('ERROR: backup and data directories must not overlap')
    if os.path.commonpath([values['BACKUP_RCLONE_MOUNT'], values['BACKUP_LOCAL_DIR']]) in (values['BACKUP_RCLONE_MOUNT'], values['BACKUP_LOCAL_DIR']):
        sys.exit('ERROR: local backup and rclone mount overlap')
for key in ('OPENCLOUD_DATA_PATH', 'OPENCLOUD_UID', 'OPENCLOUD_GID', *backup_keys):
    print(values[key])
PY
) || die 'could not validate environment settings'
mapfile -t config <<< "$settings"
data_path=${config[0]}
uid=${config[1]}
gid=${config[2]}

if [[ -e "$data_path" ]]; then
  [[ -d "$data_path" && ! -L "$data_path" ]] || die 'data path must be a non-symlink directory'
  actual=$(stat -c '%u:%g:%a' -- "$data_path") || die 'cannot inspect data directory'
  [[ "$actual" == "$uid:$gid:700" ]] || die 'existing data directory ownership or mode differs; review it manually'
  printf 'Data directory already prepared: %s\n' "$data_path"
else
  umask 022
  mkdir -p -- "$(dirname -- "$data_path")" || die 'cannot create parent directory; check permissions'
  mkdir -m 700 -- "$data_path" || die 'cannot create data directory; check permissions'
  actual=$(stat -c '%u:%g' -- "$data_path") || die 'cannot inspect new data directory'
  if [[ "$actual" != "$uid:$gid" ]]; then
    chown "$uid:$gid" -- "$data_path" || die 'cannot set ownership of new data directory; review it manually'
  fi
  chmod 00700 -- "$data_path" || die 'cannot set permissions on new data directory; review it manually'
  actual=$(stat -c '%u:%g:%a' -- "$data_path") || die 'cannot inspect new data directory'
  [[ "$actual" == "$uid:$gid:700" ]] || die 'new data directory ownership or mode is incorrect; review it manually'
  printf 'Data directory prepared: %s\n' "$data_path"
fi
if [[ -n ${config[3]:-} ]]; then
  [[ $(findmnt -n -o FSTYPE --mountpoint "${config[4]}") == fuse.rclone ]] || die 'configured rclone mount is unavailable'
  [[ $(findmnt -n -o SOURCE --mountpoint "${config[4]}") == "${config[6]}:" ]] || die 'rclone mount does not match configured remote'
  umask 077
  mkdir -p -- "${config[3]}" "${config[4]}/${config[5]}" || die 'cannot prepare backup directories'
fi
