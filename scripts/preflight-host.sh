#!/usr/bin/env bash
# Check storage host readiness for OpenCloud PosixFS (category 1a).
# Usage: ./scripts/preflight-host.sh [data-path]
set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: $0 [data-path]" >&2
  exit 1
fi
data_path=${1:-/srv/opencloud/data}
if [[ ! -d $data_path ]]; then
  echo "Error: data directory does not exist: $data_path" >&2
  exit 1
fi
for command in findmnt df awk mktemp python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command not found: $command" >&2
    exit 1
  fi
done
filesystem=$(findmnt -T "$data_path" -n -o FSTYPE) || { echo "Error: cannot determine filesystem" >&2; exit 1; }
if [[ $filesystem != ext4 && $filesystem != xfs ]]; then
  echo "Error: unsupported filesystem: $filesystem (expected ext4 or xfs)" >&2
  exit 1
fi
available_kib=$(df -Pk -- "$data_path" | awk 'NR == 2 {print $4}')
# shortcut: 10 GiB covers only the planned test file; size storage for actual data and overhead.
if [[ ! $available_kib =~ ^[0-9]+$ ]] || (( available_kib < 10485760 )); then
  echo "Error: at least 10 GiB of available space is required" >&2
  exit 1
fi
temp_file=$(mktemp -- "$data_path/.opencloud-preflight.XXXXXXXXXX") || { echo "Error: cannot write to $data_path" >&2; exit 1; }
trap 'rm -f -- "$temp_file"' EXIT
if ! python3 - "$temp_file" <<'PY'
import os
import sys

try:
    os.setxattr(sys.argv[1], 'user.opencloud_preflight', b'check')
    if os.getxattr(sys.argv[1], 'user.opencloud_preflight') != b'check':
        raise OSError('xattr value did not match')
except OSError as exc:
    print(f'Error: user xattr check failed: {exc}', file=sys.stderr)
    sys.exit(1)
PY
then
  echo "Error: unable to verify user xattrs on $data_path" >&2
  exit 1
fi
memory_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
if [[ ! $memory_kib =~ ^[0-9]+$ ]] || (( memory_kib == 0 )); then
  echo "Error: cannot determine host memory" >&2
  exit 1
fi
echo "Storage preflight passed: $data_path ($filesystem), $available_kib KiB available"
echo "Reference OPENCLOUD_MEM_LIMIT=$((memory_kib * 70 / 100 / 1024))M (70% of host RAM; choose dev limit separately)"
