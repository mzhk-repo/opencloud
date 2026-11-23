# Scripts runbook

Run commands from the repository root. Identify the target environment before changing state. Keep passwords, decrypted configuration and tokens out of Git, logs and shared terminals.

## Storage preflight (category 1a)

`scripts/preflight-host.sh` checks an existing storage directory for a supported filesystem, free space and xattr support. It does not require Docker or SOPS.

```bash
./scripts/preflight-host.sh /srv/opencloud/data
```

## Swarm deployment orchestration (category 1b)

The orchestrator requires a Swarm manager as the storage node; remote storage-node preparation is not implemented. During deployment it assigns `storage=primary` to the current manager if the label is absent. It stops if another node is already labelled `storage=primary` or the current node has a different `storage` value. `--check` reports a needed assignment without changing labels. Set `SERVER_ENV` from the host, an existing SOPS or owner-only plaintext `ORCHESTRATOR_ENV_FILE`, `ORCHESTRATOR_MODE=swarm`, `ENVIRONMENT_NAME=development` or `production`, and a lowercase `STACK_NAME`. The file must contain the Entra group IDs and other deployment settings. Check without changing storage, secrets or services:

```bash
ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development STACK_NAME=opencloud \
  ORCHESTRATOR_ENV_FILE=env.dev.enc ./scripts/deploy-orchestrator-swarm.sh --check
```

After review, an authorized dev deployment is started with the same environment and `--deploy --apply`. Traefik and OpenCloud must share the `OPENCLOUD_PROXY_NETWORK` Swarm overlay. The orchestrator creates a missing overlay during deployment; `--check` reports the planned creation without changing it. Set the same network on Traefik, for example `OPENCLOUD_PROXY_NETWORK=cloud_net`. This hop uses HTTP; an unencrypted overlay is accepted with a warning in both environments and exposes traffic to network participants. The network remains if a later deployment step fails. Production additionally requires `--approval-context <approval-id>`; the identifier does not itself grant approval. The shared CI workflow must invoke `scripts/ci-deploy-swarm.sh`, which adapts its environment to these explicit options; CI integration remains a later task.

The orchestrator checks policies and node placement before assigning a missing label, then prepares and checks the data directory, reconciles the secret, deploys, and waits for a healthy service and HTTP 200. It exits nonzero on failure; a failure can leave the node label, an updated stack or a new secret, so inspect the node and service before retrying. The `storage=primary` label can also affect other Swarm services using that placement constraint. It never automatically rolls back data or removes old secrets. No direct production operation is authorized by this documentation.

## Prepare the storage directory (category 1b)

Run `scripts/init-volumes.sh` on the intended storage node, before preflight. Its exported `SERVER_ENV` must match the single `dev` or `prod` value in `/etc/environment`. `ORCHESTRATOR_ENV_FILE` must point to an owner-only plaintext dotenv prepared securely by the deployment process; it may contain `OPENCLOUD_DATA_PATH`, `OPENCLOUD_UID`, and `OPENCLOUD_GID`. Defaults are `/srv/opencloud/data`, `1000`, and `1000`. The Swarm stack uses the same variables. The script does not decrypt SOPS files or execute dotenv contents.

```bash
ORCHESTRATOR_ENV_FILE=/path/to/owner-only.env ./scripts/init-volumes.sh
./scripts/preflight-host.sh /srv/opencloud/data
```

If a custom data path is configured, pass the same path to preflight. The script creates a missing directory with mode `0700` and the requested owner; it checks an existing directory without changing it or its contents. A mismatch stops execution for manual review. The caller needs the necessary filesystem privileges; do not reinitialize or recursively change ownership of existing OpenCloud data. Keep decrypted dotenv files out of Git and remove them when no longer needed.

## Group-to-role configuration

On the Swarm manager, add `ENTRA_ADMIN_GROUP_ID` and `ENTRA_STAFF_GROUP_ID` to the appropriate SOPS environment file. They must be distinct canonical Entra group UUIDs. `SERVER_ENV` must be exported as `dev` or `prod`. The generated file is ignored by Git and must be regenerated after cloning.

```bash
mkdir -p .local
python3 scripts/render-proxy-config.py --env-file env.dev.enc > .local/proxy-config.env.tmp &&
  mv .local/proxy-config.env.tmp .local/proxy-config.env
```

The script writes `OPENCLOUD_PROXY_CONFIG_FILE` (default `./.local/proxy.yaml`) and emits only content-based Swarm Config names to the mapping file. For prod, use `env.prod.enc` on the prod host. The script also accepts an owner-only plaintext dotenv via `--env-file`, or exported group IDs when the option is omitted. Pass `.local/proxy-config.env` and the secret mapping to the deployment process. The planned orchestrator must invoke this script; the existing repository does not yet have a CI/CD workflow.

## OpenCloud Swarm secret (category 1b)

`scripts/reconcile-sops-secrets.sh` prepares a versioned Swarm secret from `OPENCLOUD_YAML_B64`. It requires SOPS, the correct age key, Python 3 with PyYAML and a host `SERVER_ENV` matching `/etc/environment`. Apply additionally requires Docker access on a Swarm manager. The following examples target **dev**; never use its OpenCloud config for another environment.

### Write and verify the base64 value

Close any SOPS editor for `env.dev.enc` before updating it. The following writes the existing local configuration directly into SOPS without printing the value or putting it in command arguments. It modifies the encrypted file; confirm that this local configuration is the one associated with the dev data.

```bash
cd /opt/opencloud
(
  set -o pipefail
  python3 -c 'import base64,json,sys; json.dump(base64.b64encode(open(sys.argv[1],"rb").read()).decode(),sys.stdout)' \
    .local/opencloud/config/opencloud.yaml \
    | sops set --input-type dotenv --output-type dotenv --value-stdin \
        env.dev.enc '["OPENCLOUD_YAML_B64"]'
)
```

Check the decoded bytes against the same file without printing either value:

```bash
(
  set -o pipefail
  sops --decrypt --input-type dotenv --output-type binary \
    --extract '["OPENCLOUD_YAML_B64"]' env.dev.enc \
    | base64 -d \
    | cmp -s .local/opencloud/config/opencloud.yaml -
) && echo 'OK: configuration matches' || echo 'ERROR: comparison failed'
```

A failed comparison requires investigation before proceeding. Use the appropriate environment-specific source file and encrypted env file for prod; production apply requires explicit authorization and an approval context. Never reinitialize OpenCloud over existing state.

### Dry run and apply on dev

```bash
./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-map.env
./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-map.env -apply
./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-map.env -apply
```

Stop at the first error. The first command makes no Swarm changes; the next creates the secret if missing and writes its name to the mapping. The last confirms a repeat run succeeds. These commands do not deploy a service or remove old secrets. Verify the actual service and recovery separately before removing any old secret.
