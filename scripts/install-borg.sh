#!/usr/bin/env bash
# Install the distribution Borg only when it is missing.
set -euo pipefail
if ! command -v borg >/dev/null; then
  [[ -r /etc/os-release ]] || { echo 'ERROR: cannot identify operating system' >&2; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || { echo 'ERROR: automatic Borg installation requires Ubuntu' >&2; exit 1; }
  sudo -n apt-get update
  sudo -n apt-get install -y borgbackup
fi
version=$(borg --version)
if ! [[ "$version" =~ ^borg\ 1\.([0-9]+)\. ]] || (( BASH_REMATCH[1] < 2 )); then
  echo "ERROR: Borg 1.2 or newer in the 1.x series is required; found $version" >&2
  exit 1
fi
printf 'Using %s\n' "$version"
