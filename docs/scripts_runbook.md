# Scripts runbook

Run commands from the repository root. Identify the target environment before changing state. Keep passwords, decrypted configuration and tokens out of Git, logs and shared terminals.

## Storage preflight (category 1a)

`scripts/preflight-host.sh` checks an existing storage directory for a supported filesystem, free space and xattr support. It does not require Docker or SOPS.

```bash
./scripts/preflight-host.sh /srv/opencloud/data
```

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
