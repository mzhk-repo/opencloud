# Scripts runbook

Run commands from the repository root. Identify the target environment before changing state. Keep passwords, decrypted configuration and tokens out of Git, logs and shared terminals.

## Manual script commands

The examples below target the `opencloud` dev stack. Run each command separately, after reading its linked section and satisfying its prerequisites. On the dev host, export `SERVER_ENV=dev`; it must match `/etc/environment` for scripts that validate the host environment. Use the corresponding prod settings only on the prod host with explicit production authorization.

For the commands that accept a plaintext env file, first prepare one in `/dev/shm` in the same shell session. Confirm `/dev/shm` is tmpfs and that the operator has access to the appropriate SOPS age key. This example decrypts the dev file without displaying its contents:

```bash
findmnt -n -o FSTYPE --mountpoint /dev/shm
```

Continue only if the output is `tmpfs`:

```bash
umask 077
manual_env=$(mktemp /dev/shm/opencloud-env.XXXXXXXX) &&
  sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "$manual_env" || {
    [[ -z ${manual_env:-} ]] || rm -f -- "$manual_env"
    unset manual_env
    echo 'ERROR: temporary environment preparation failed' >&2
    false
  }
```

Continue only if the command succeeds and `manual_env` remains set. The file has owner-only permissions; run the scripts as its owner. After changing the encrypted environment, remove this temporary file and decrypt it again before running scripts that need the new values.

1. **Check a data directory** ([storage preflight](#storage-preflight-category-1a)):

   ```bash
   ./scripts/preflight-host.sh /srv/opencloud/data
   ```

2. **Install or check Borg** ([backup prerequisites](#borg-backup-and-google-drive-copy-category-2)). This can install a package when Borg is absent:

   ```bash
   ./scripts/install-borg.sh
   ```

3. **Prepare storage and backup directories** ([storage preparation](#prepare-the-storage-directory-category-1b)):

   ```bash
   SERVER_ENV=dev ORCHESTRATOR_ENV_FILE="$manual_env" ./scripts/init-volumes.sh
   ```

4. **Generate the group mapping** ([group-to-role configuration](#group-to-role-configuration)). The destination directory must exist:

   ```bash
   SERVER_ENV=dev python3 scripts/render-proxy-config.py --env-file "$manual_env" > .local/proxy-config.env.tmp && mv .local/proxy-config.env.tmp .local/proxy-config.env
   ```

5. **Check the Swarm secret** ([secret reconciliation](#opencloud-swarm-secret-category-1b)). This is a dry run; the linked section also documents apply:

   ```bash
   SERVER_ENV=dev ./scripts/reconcile-sops-secrets.sh -env-file "$manual_env" -environment dev -mapping-file /tmp/opencloud-map.env
   ```

6. **Check the deployment** ([Swarm orchestration](#swarm-deployment-orchestration-category-1b)). This does not deploy; the linked section gives the apply command:

   ```bash
   SERVER_ENV=dev ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development STACK_NAME=opencloud ORCHESTRATOR_ENV_FILE="$manual_env" ./scripts/deploy-orchestrator-swarm.sh --check
   ```

7. **Run the CI deployment adapter manually**. This performs a dev deployment; use the preceding check first and review the [deployment prerequisites](#swarm-deployment-orchestration-category-1b):

   ```bash
   SERVER_ENV=dev ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development STACK_NAME=opencloud ORCHESTRATOR_ENV_FILE="$manual_env" ./scripts/ci-deploy-swarm.sh
   ```

8. **Create a backup and copy it to Drive** ([backup procedure](#borg-backup-and-google-drive-copy-category-2)). This temporarily stops a running service:

   ```bash
   SERVER_ENV=dev STACK_NAME=opencloud ./scripts/backup.sh dev
   ```

   `backup.sh` reads `env.dev.enc` directly and decrypts it in its own temporary directory; it does not accept `manual_env`. Preflight and Borg installation do not use an env file.

When finished or abandoning the manual procedure, remove the temporary file in the same shell:

```bash
rm -f -- "$manual_env"
unset manual_env
```

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

Follow the [9.1.x upgrade guide](upgrade-9.1.x.md). These commands are for the `opencloud` dev stack on its manager and storage node. The requested procedure does not create a backup. After 9.1.1 changes persistent state, switching the image back to 7.2.5 alone is not a verified recovery procedure. Stop on any error; keep the service stopped until the failure is understood. Do not run a second deployment or migration concurrently.

Check the current image and confirm that the dry-run secret name matches the secret attached to the deployed service. A mismatch means the SOPS configuration is not proven to match the running service; stop and investigate without printing configuration values.

```bash
cd /opt/opencloud
export SERVER_ENV=dev
docker service inspect opencloud_opencloud --format 'Image: {{.Spec.TaskTemplate.ContainerSpec.Image}}{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{if eq .File.Name "/etc/opencloud/opencloud.yaml"}}{{printf "\nConfig secret: %s" .SecretName}}{{end}}{{end}}'
./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-upgrade-map.env
docker pull opencloudeu/opencloud:9.1.1
```

Confirm the image is 7.2.x and compare the secret names. Confirm the 9.1.1 image pull succeeded before stopping the service. Then stop it and confirm no container for this service remains on the storage node:

```bash
docker service scale --detach=false opencloud_opencloud=0
docker ps --filter label=com.docker.swarm.service.name=opencloud_opencloud --format '{{.ID}}'
```

Continue only if the last command prints no container ID. Prepare a temporary owner-only copy in tmpfs, using the same Linux UID/GID as the service. Keep the shell session open for the following commands; do not expose the contents of the YAML, diff, or patch in logs or shared terminals.

```bash
set -o pipefail
umask 077
task_stage=$(mktemp -d /dev/shm/opencloud-upgrade.XXXXXXXX)
sops --decrypt --input-type dotenv --output-type binary \
  --extract '["OPENCLOUD_YAML_B64"]' env.dev.enc \
  | base64 --decode > "$task_stage/opencloud.yaml"
```

Stop if decryption or decoding fails. The following runs `init --diff` only on the temporary config copy, with no live data mounted. It does not initialize the existing data directory:

```bash
docker run --rm --pull never --network none --user "$(id -u):$(id -g)" \
  --entrypoint /bin/sh --mount "type=bind,src=$task_stage,dst=/etc/opencloud" \
  opencloudeu/opencloud:9.1.1 \
  -c 'cd /etc/opencloud && opencloud init --diff' > "$task_stage/diff-output" 2>&1
```

Review `diff-output` and, if present, `opencloud.config.patch` privately. Check custom settings, the guest-link service account and thumbnail changes against the guide. If there is a patch, verify and apply it to the temporary file:

```bash
patch --dry-run --batch --forward "$task_stage/opencloud.yaml" < "$task_stage/opencloud.config.patch" &&
patch --batch --forward "$task_stage/opencloud.yaml" < "$task_stage/opencloud.config.patch"
```

If the diff explicitly says there are no changes and no patch was produced, skip these two commands. Stop for any other result or failed review. Close any SOPS editor first. Update the encrypted dev file with the reviewed config, then the image tag; the two writes are separate, so stop and resolve a failure before deploying.

```bash
python3 -c 'import base64,json,sys; json.dump(base64.b64encode(open(sys.argv[1],"rb").read()).decode(),sys.stdout)' \
  "$task_stage/opencloud.yaml" | sops set --input-type dotenv --output-type dotenv --value-stdin \
  env.dev.enc '["OPENCLOUD_YAML_B64"]' &&
printf '"9.1.1"' | sops set --input-type dotenv --output-type dotenv --value-stdin \
  env.dev.enc '["OPENCLOUD_IMAGE_TAG"]' &&
sops --decrypt --input-type dotenv --output-type binary \
  --extract '["OPENCLOUD_YAML_B64"]' env.dev.enc | base64 --decode | cmp -s "$task_stage/opencloud.yaml" - &&
sops --decrypt --input-type dotenv --output-type binary \
  --extract '["OPENCLOUD_IMAGE_TAG"]' env.dev.enc
```

Continue only when the comparison succeeds and the tag is `9.1.1`. Remove the temporary directory after completing the verification, including if the process is abandoned: `rm -rf -- "${task_stage:?}"`. Deploy using the orchestrator and stop if it fails:

```bash
ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development STACK_NAME=opencloud \
  ORCHESTRATOR_ENV_FILE=env.dev.enc ./scripts/deploy-orchestrator-swarm.sh --check
ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development STACK_NAME=opencloud \
  ORCHESTRATOR_ENV_FILE=env.dev.enc ./scripts/deploy-orchestrator-swarm.sh --deploy --apply
```

Once the service is healthy, rebuild the default Bleve index during a low-activity window. Select the sole running service container on its storage node and verify there is exactly one before running the command:

```bash
docker ps --filter label=com.docker.swarm.service.name=opencloud_opencloud --format '{{.ID}}'
docker exec <container-id> opencloud search index --all-spaces --force-rescan
```

Replace `<container-id>` with that single ID. Wait for completion before retrying. Verify old files appear in search, sign-in, upload/download, Spaces, existing shares and public links, previews and a new project Space's 1,000,000,000-byte default quota. Do not delete `/var/lib/opencloud/search/bleve` until search validation succeeds and the operator separately decides to remove it. The default quota does not retroactively change existing Spaces. Record observed results and CPU/RAM use; a healthy proxy alone does not prove these checks.

## Prepare the storage directory (category 1b)

Run `scripts/init-volumes.sh` on the intended storage node, before preflight. Its exported `SERVER_ENV` must match the single `dev` or `prod` value in `/etc/environment`. `ORCHESTRATOR_ENV_FILE` must point to an owner-only plaintext dotenv prepared securely by the deployment process; it may contain `OPENCLOUD_DATA_PATH`, `OPENCLOUD_UID`, and `OPENCLOUD_GID`. Defaults are `/srv/opencloud/data`, `1000`, and `1000`. The Swarm stack uses the same variables. The script does not decrypt SOPS files or execute dotenv contents.

```bash
ORCHESTRATOR_ENV_FILE="$manual_env" ./scripts/init-volumes.sh
./scripts/preflight-host.sh /srv/opencloud/data
```

Prepare `manual_env` as shown in [manual script commands](#manual-script-commands). If a custom data path is configured, pass the same path to preflight. The script creates a missing directory with mode `0700` and the requested owner; it checks an existing directory without changing it or its contents. A mismatch stops execution for manual review. The caller needs the necessary filesystem privileges; do not reinitialize or recursively change ownership of existing OpenCloud data. Keep decrypted dotenv files out of Git and remove them when no longer needed.

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

For recovery, follow the [Borg restore runbook](RUNBOOK.md#restore-a-borg-backup).

## Borg backup and Google Drive copy (category 2)

Configure the backup settings shown in `config/sops-env.example` in the selected encrypted `env.dev.enc` or `env.prod.enc`; do not print decrypted values. `BORG_PASSPHRASE` must be a strong non-placeholder value and must be recoverable independently of the Borg repository. Preserve the corresponding SOPS age key and encrypted environment separately. The backup includes the matching `opencloud.yaml`, decrypted environment, service specification and Swarm Config records inside the encrypted Borg archive. The SOPS configuration must hash to the `opencloud.yaml` secret attached to the service; the script stops on a mismatch.

`BACKUP_LOCAL_DIR` holds the encrypted Borg repository, its lock and a pending-copy marker. It must be outside both the OpenCloud data tree and the rclone mount. `BACKUP_RCLONE_REMOTE` is an rclone remote name without `:`, `BACKUP_RCLONE_FOLDER` is a relative folder beneath that remote, and `BACKUP_RCLONE_MOUNT` must be an existing `fuse.rclone` mount of the remote root (`findmnt` source `<remote>:`). The same user running backup and volume preparation must have access to the mount, the remote's rclone configuration, the SOPS key, Docker and the metrics directory. In particular, root must be able to access a FUSE mount created by another user. Provision `NODE_EXPORTER_TEXTFILE_DIR` separately. Restrict access to the local backup directory and to the Google Drive destination.

The deploy orchestrator runs `install-borg.sh` only during `--deploy --apply`. It keeps an existing Borg 1.2 or later in the 1.x series; otherwise on Ubuntu it uses `sudo -n apt-get` to install the distribution package. Noninteractive apt permission is required when installation is needed; failure stops deployment. Borg 2 and repositories incompatible with the installed Borg stop with an error. `--check` does not install packages or create directories. Deploy preparation creates the configured backup directories only after checking the rclone mount and remote. Do not configure a timer until the owner chooses an external scheduler.

Run the backup on the manager that is the sole `storage=primary` node, with no concurrent deployment, restore, or other operation on the Borg repository. This example targets dev; the operator must run it with sufficient privileges to read all data and its xattrs and must make the age key and rclone configuration available to that account:

```bash
cd /opt/opencloud
SERVER_ENV=dev STACK_NAME=opencloud ./scripts/backup.sh dev
```

The script attempts expired trash and upload cleanup, stops the service only when its desired replica count is one, creates an encrypted archive, restores that replica count, prunes local archives (7 daily, 4 weekly, 6 monthly), compacts the repository, and runs `rclone copy` to a new dated Drive directory. A service already scaled to zero remains stopped. The reported scaling interval is not an external availability measurement. The first dev run still needs an independently measured downtime and a full restore drill. Signals handled by the script attempt a restart; power loss or SIGKILL cannot run cleanup. If restart fails, inspect the service and recover it manually before continuing.

A failed copy leaves the local archive and `.opencloud-pending` marker. Fix the mount, remote or credentials, then retry without stopping the service or creating an archive:

```bash
SERVER_ENV=dev STACK_NAME=opencloud ./scripts/backup.sh dev --retry-copy
```

Do not edit or delete the pending marker or modify the repository before retrying. A failure during prune or compact also leaves the marker; investigate local retention and repository health before retrying, since retry only transfers the existing repository. After successful transfer the script removes older matching directories carrying its ownership marker, keeping the current copy and ignoring unmarked, unrelated and newer directories. Failed or interrupted transfers can leave unmarked partial directories that require manual review. Full dated copies can temporarily require space for multiple repositories. A successful `rclone copy` is not a restore test; `borg check` and the full recovery procedure are separate operator tasks.

The `opencloud_backup.prom` file is atomically replaced with `opencloud_backup_last_run_timestamp_seconds`, `opencloud_backup_last_success_timestamp_seconds`, and `opencloud_backup_last_status`, labelled with `env` and `service="opencloud"`. A failed run keeps the previous success timestamp. If the configuration cannot be decrypted or parsed, the metrics directory is not yet known and no metric can be written; monitor the scheduler and script exit code too. A metrics write failure is reported and returns a nonzero status, even if the backup copy completed.
