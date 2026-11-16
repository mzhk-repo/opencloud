#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d -- "$root/.preflight-test.XXXXXXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

"$root/scripts/preflight-host.sh" "$test_dir"
"$root/scripts/preflight-host.sh" "$test_dir"
if compgen -G "$test_dir/.opencloud-preflight.*" >/dev/null; then
  echo 'Temporary preflight file was not removed' >&2
  exit 1
fi
if "$root/scripts/preflight-host.sh" "$test_dir/missing"; then
  echo 'Missing directory was accepted' >&2
  exit 1
fi
mkdir "$test_dir/bin"
printf '#!/bin/sh\nexit 1\n' > "$test_dir/bin/python3"
chmod +x "$test_dir/bin/python3"
if PATH="$test_dir/bin:$PATH" "$root/scripts/preflight-host.sh" "$test_dir"; then
  echo 'Failed xattr check was accepted' >&2
  exit 1
fi
if compgen -G "$test_dir/.opencloud-preflight.*" >/dev/null; then
  echo 'Temporary preflight file remained after failure' >&2
  exit 1
fi
