#!/usr/bin/env bash
# Test a complete isolated Borg extraction and report textfile metrics.
set -euo pipefail
umask 077
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
environment=${SERVER_ENV:-} archive=''
while (($#)); do
  case "$1" in
    --env) (($# >= 2)) || die '--env needs a value'; environment=$2; shift 2 ;;
    --archive) (($# >= 2)) || die '--archive needs a value'; archive=$2; shift 2 ;;
    --help) echo 'Usage: test-restore.sh --env dev|prod [--archive ARCHIVE]'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $environment == dev || $environment == prod ]] || die 'environment must be dev or prod'
[[ ${SERVER_ENV:-} == "$environment" ]] || die 'SERVER_ENV must match the environment'
[[ $(stat -f -c %T /dev/shm) == tmpfs ]] || die '/dev/shm must be tmpfs'
for tool in sops python3 flock; do command -v "$tool" >/dev/null || die "$tool is required"; done
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
stage=$(mktemp -d /dev/shm/opencloud-restore-smoke.XXXXXXXX)
work='' config_dir='' metrics_dir='' metrics_lock=false status=0 run_timestamp=$(date +%s)
cleanup() {
  local rc=$? previous=0 tmp=''
  trap - EXIT
  if [[ -n $config_dir ]]; then rm -rf -- "$config_dir" || rc=1; fi
  if [[ -n $work ]]; then rm -rf -- "$work" || rc=1; fi
  if [[ -n $metrics_dir && $metrics_lock == true ]]; then
    if [[ -f "$metrics_dir/opencloud_restore_smoke.prom" ]]; then
      previous=$(sed -n "s/^opencloud_restore_smoke_last_success_timestamp_seconds{env=\"$environment\",service=\"opencloud\"} \([0-9][0-9]*\)$/\1/p" "$metrics_dir/opencloud_restore_smoke.prom" | tail -1)
      [[ $previous =~ ^[0-9]+$ ]] || previous=0
    fi
    if (( rc == 0 )) && [[ $status == 1 ]]; then previous=$(date +%s); else status=0; fi
    if tmp=$(mktemp "$metrics_dir/.opencloud_restore_smoke.XXXXXXXX") &&
      printf '# HELP opencloud_restore_smoke_last_run_timestamp_seconds Unix timestamp of the last OpenCloud restore smoke test attempt.\n# TYPE opencloud_restore_smoke_last_run_timestamp_seconds gauge\nopencloud_restore_smoke_last_run_timestamp_seconds{env="%s",service="opencloud"} %s\n# HELP opencloud_restore_smoke_last_success_timestamp_seconds Unix timestamp of the last successful OpenCloud restore smoke test.\n# TYPE opencloud_restore_smoke_last_success_timestamp_seconds gauge\nopencloud_restore_smoke_last_success_timestamp_seconds{env="%s",service="opencloud"} %s\n# HELP opencloud_restore_smoke_last_status Last OpenCloud restore smoke test status (1=success, 0=failure).\n# TYPE opencloud_restore_smoke_last_status gauge\nopencloud_restore_smoke_last_status{env="%s",service="opencloud"} %s\n' "$environment" "$run_timestamp" "$environment" "$previous" "$environment" "$status" > "$tmp" &&
      chmod 644 "$tmp" && mv -f -- "$tmp" "$metrics_dir/opencloud_restore_smoke.prom"; then :
    else
      printf 'ERROR: failed to write restore smoke metrics\n' >&2
      [[ -z $tmp ]] || rm -f -- "$tmp"
      rc=1
    fi
  fi
  rm -rf -- "$stage" || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
[[ -f "$root/env.$environment.enc" && ! -L "$root/env.$environment.enc" ]] || die 'encrypted environment file is missing'
sops --decrypt --input-type dotenv --output-type dotenv "$root/env.$environment.enc" > "$stage/env" 2>/dev/null || die 'SOPS decryption failed'
python3 - "$stage/env" "$stage/settings" <<'PY' || die 'invalid smoke test settings'
import os,re,sys
from pathlib import Path
v={}
for line in Path(sys.argv[1]).read_text().splitlines():
 if not line.strip() or line.startswith('#'): continue
 m=re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)',line)
 if not m or m[1] in v: sys.exit('invalid dotenv')
 v[m[1]]=m[2]
for k in ('BACKUP_LOCAL_DIR','NODE_EXPORTER_TEXTFILE_DIR'):
 p=v.get(k,'')
 if not os.path.isabs(p) or p=='/' or os.path.normpath(p)!=p or os.path.realpath(p)!=p or any(ord(c)<32 for c in p): sys.exit('invalid '+k)
with open(sys.argv[2],'wb') as f:
 for k in ('BACKUP_LOCAL_DIR','NODE_EXPORTER_TEXTFILE_DIR'): f.write(v[k].encode()+b'\0')
PY
mapfile -d '' -t settings < "$stage/settings"
backup=${settings[0]} metrics_dir=${settings[1]}
[[ -d $metrics_dir ]] || die 'metrics directory does not exist'
exec 8>"$metrics_dir/.opencloud_restore_smoke.lock"
flock -n 8 || die 'another restore smoke test is running'
metrics_lock=true
work=$(mktemp -d "$(dirname "$backup")/.opencloud-smoke.XXXXXXXX")
args=(--env "$environment" --target "$work/data")
[[ -z $archive ]] || args+=(--archive "$archive")
"$root/scripts/restore.sh" "${args[@]}" > "$stage/result" || die 'isolated restore failed'
config=$(sed -n 's/^CONFIG_PATH=//p' "$stage/result")
[[ "$config" =~ ^/dev/shm/opencloud-restore\.[A-Za-z0-9]+/opencloud\.yaml$ ]] || die 'invalid restored config path'
config_dir=${config%/*}
[[ -s $config ]] || die 'restored configuration is empty'
for path in storage/users idm/idm.boltdb nats/jetstream; do
  [[ -e "$work/data/$path" ]] || die "required restored state is missing: $path"
done
python3 - "$work/data/storage/users" <<'PY' || die 'no restored regular file with user.oc.id was found'
import os,sys
for root, dirs, files in os.walk(sys.argv[1],followlinks=False):
 for name in files:
  p=os.path.join(root,name)
  if os.path.islink(p) or not os.path.isfile(p): continue
  try:
   if os.getxattr(p,'user.oc.id',follow_symlinks=False): sys.exit(0)
  except OSError: pass
sys.exit(1)
PY
status=1
printf 'Isolated restore, required state and user.oc.id verified\n'
