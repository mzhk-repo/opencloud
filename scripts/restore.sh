#!/usr/bin/env bash
# Restore a Borg archive into a new directory; keep configuration in tmpfs.
set -euo pipefail
umask 077
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
environment=${SERVER_ENV:-} target='' archive='' repo_override=''
while (($#)); do
  case "$1" in
    --env) (($# >= 2)) || die '--env needs a value'; environment=$2; shift 2 ;;
    --target) (($# >= 2)) || die '--target needs a value'; target=$2; shift 2 ;;
    --archive) (($# >= 2)) || die '--archive needs a value'; archive=$2; shift 2 ;;
    --repo) (($# >= 2)) || die '--repo needs a value'; repo_override=$2; shift 2 ;;
    --help) echo 'Usage: restore.sh --env dev|prod --target NEW_ABSOLUTE_DIRECTORY [--archive ARCHIVE] [--repo LOCAL_REPOSITORY]'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $environment == dev || $environment == prod ]] || die 'environment must be dev or prod'
[[ ${SERVER_ENV:-} == "$environment" ]] || die 'SERVER_ENV must match the environment'
[[ $(stat -f -c %T /dev/shm) == tmpfs ]] || die '/dev/shm must be tmpfs'
for tool in borg sops python3 flock; do command -v "$tool" >/dev/null || die "$tool is required"; done
python3 - "$environment" <<'PY' || die 'host environment does not match'
import os,re,sys
from pathlib import Path
values=[]
for line in Path('/etc/environment').read_text().splitlines():
 m=re.fullmatch(r'''\s*SERVER_ENV\s*=\s*(?:"(dev|prod)"|'(dev|prod)'|(dev|prod))\s*''',line)
 if m: values.append(next(v for v in m.groups() if v is not None))
 elif re.match(r'^\s*SERVER_ENV\s*=',line): sys.exit(1)
if values != [sys.argv[1]] or os.environ.get('SERVER_ENV') != sys.argv[1]: sys.exit(1)
PY
stage=$(mktemp -d /dev/shm/opencloud-restore.XXXXXXXX)
work='' keep_config=false
cleanup() {
  local rc=$?
  trap - EXIT
  rm -f -- "$stage/env" "$stage/settings" "$stage/archive-list" "$stage/paths"
  [[ -z $work ]] || printf 'Partial extraction retained: %s\n' "$work" >&2
  if [[ $keep_config == false ]]; then rm -rf -- "$stage"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
[[ -f "$root/env.$environment.enc" && ! -L "$root/env.$environment.enc" ]] || die 'encrypted environment file is missing'
sops --decrypt --input-type dotenv --output-type dotenv "$root/env.$environment.enc" > "$stage/env" 2>/dev/null || die 'SOPS decryption failed'
python3 - "$stage/env" "$stage/settings" "$target" "$repo_override" <<'PY' || die 'invalid restore settings or target'
import os,re,sys
from pathlib import Path
values={}
for line in Path(sys.argv[1]).read_text().splitlines():
 if not line.strip() or line.startswith('#'): continue
 m=re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)',line)
 if not m or m[1] in values: sys.exit('invalid dotenv')
 values[m[1]]=m[2]
for k in ('OPENCLOUD_DATA_PATH','BACKUP_LOCAL_DIR','BORG_PASSPHRASE'):
 if not values.get(k) or values[k].startswith('REPLACE_WITH_'): sys.exit('missing setting '+k)
def valid_path(p):
 return bool(p) and os.path.isabs(p) and p!='/' and os.path.normpath(p)==p and os.path.realpath(p)==p and not any(ord(c)<32 for c in p)
target=sys.argv[3]
repo_override=sys.argv[4]
for p in (target,values['OPENCLOUD_DATA_PATH'],values['BACKUP_LOCAL_DIR']):
 if not valid_path(p): sys.exit('paths must be absolute, normalized and without symlinks')
if os.path.lexists(target) or not os.path.isdir(os.path.dirname(target)): sys.exit('target must not exist and its parent must exist')
if repo_override:
 if not valid_path(repo_override) or not os.path.isdir(repo_override): sys.exit('invalid local repository')
 if os.path.commonpath([target,repo_override]) in (target,repo_override): sys.exit('target overlaps the repository')
for key in ('OPENCLOUD_DATA_PATH','BACKUP_LOCAL_DIR','BACKUP_RCLONE_MOUNT'):
 p=values.get(key,'')
 if p:
  if not valid_path(p): sys.exit('invalid configured path')
  if os.path.commonpath([target,p]) in (target,p): sys.exit('target overlaps a protected path')
with open(sys.argv[2],'wb') as f:
 for key in ('OPENCLOUD_DATA_PATH','BACKUP_LOCAL_DIR','BORG_PASSPHRASE'): f.write(values[key].encode()+b'\0')
PY
mapfile -d '' -t settings < "$stage/settings"
data=${settings[0]} backup=${settings[1]}
export BORG_PASSPHRASE=${settings[2]}
unset settings
repo=${repo_override:-"$backup/repository"}
[[ -d $repo && ! -L $repo ]] || die 'local Borg repository is unavailable'
if [[ "$repo" == "$backup/repository" ]]; then
  exec 9>"$backup/.opencloud-backup.lock"
else
  exec 9<"$repo"
fi
flock -n 9 || die 'another backup or restore is running'
version=$(borg --version)
if ! [[ "$version" =~ ^borg\ 1\.([0-9]+)\. ]] || (( BASH_REMATCH[1] < 2 )); then die 'Borg 1.2 or newer in the 1.x series is required'; fi
borg list --json "$repo" > "$stage/archive-list" || die 'cannot read Borg repository'
archive=$(python3 - "$stage/archive-list" "$environment" "$archive" <<'PY'
import json,re,sys
items=json.load(open(sys.argv[1]))['archives']; prefix='opencloud-'+sys.argv[2]+'-'
names=[x['name'] for x in items if x.get('name','').startswith(prefix)]
requested=sys.argv[3]
if requested and requested not in names: sys.exit('archive does not belong to the selected environment')
if not names: sys.exit('no archives for selected environment')
print(requested or max(names))
PY
) || die 'cannot select archive'
borg list --short "$repo::$archive" > "$stage/paths" || die 'cannot inspect archive'
mapfile -t configs < <(grep -E '^dev/shm/opencloud-backup\.[^/]+/opencloud\.yaml$' "$stage/paths" || true)
[[ ${#configs[@]} -eq 1 ]] || die 'archive must contain one OpenCloud configuration'
data_archive=${data#/}
grep -Fxq -- "$data_archive" "$stage/paths" || die 'configured data path is absent from archive'
borg extract --stdout "$repo::$archive" "${configs[0]}" > "$stage/opencloud.yaml" || die 'cannot extract OpenCloud configuration'
[[ -s "$stage/opencloud.yaml" ]] || die 'archived OpenCloud configuration is empty'
metadata_dir=${configs[0]%/*}
borg extract --stdout "$repo::$archive" "$metadata_dir/service.json" > "$stage/service.json" || die 'cannot extract archived service specification'
python3 - "$stage/service.json" "$data" <<'PY' || die 'archived service specification does not match the data path'
import json,sys
s=json.load(open(sys.argv[1]))[0]['Spec']['TaskTemplate']['ContainerSpec']
if not s.get('Image'): sys.exit(1)
mounts=[m for m in s.get('Mounts',[]) if m.get('Target')=='/var/lib/opencloud']
if len(mounts)!=1 or mounts[0].get('Type')!='bind' or mounts[0].get('Source')!=sys.argv[2]: sys.exit(1)
PY
work=$(mktemp -d "$(dirname "$target")/.opencloud-restore.XXXXXXXX")
(cd "$work" && borg extract "$repo::$archive" "$data_archive") || die 'Borg extraction failed'
[[ -d "$work/$data_archive" && ! -L "$work/$data_archive" ]] || die 'restored data directory is invalid'
[[ ! -e $target && ! -L $target ]] || die 'target appeared during restore'
mv -T -n -- "$work/$data_archive" "$target" || die 'cannot install restored data at target'
[[ ! -e "$work/$data_archive" ]] || die 'target appeared during restore'
# Only empty directories remain in the extraction staging tree.
find "$work" -depth -type d -empty -delete
if [[ -e $work ]]; then die 'unexpected entries remain in extraction staging'; fi
work=''
keep_config=true
printf 'ARCHIVE=%s\nDATA_PATH=%s\nCONFIG_PATH=%s\nSERVICE_PATH=%s\n' "$archive" "$target" "$stage/opencloud.yaml" "$stage/service.json"
