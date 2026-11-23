#!/usr/bin/env bash
# Category 1b: adapt the shared CI environment to the OpenCloud orchestrator.
# Example: ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development ORCHESTRATOR_ENV_FILE=/tmp/env.decrypted ./scripts/ci-deploy-swarm.sh
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export STACK_NAME=${STACK_NAME:-opencloud}
case "${ENVIRONMENT_NAME:-}" in
  development) exec "$root/scripts/deploy-orchestrator-swarm.sh" --deploy --apply ;;
  production) exec "$root/scripts/deploy-orchestrator-swarm.sh" --deploy --apply --approval-context "${APPROVAL_CONTEXT:-}" ;;
  *) printf '%s\n' 'ERROR: ENVIRONMENT_NAME must be development or production' >&2; exit 1 ;;
esac
