# OpenCloud operator runbook

For the operator procedure using `restore.sh` and `test-restore.sh`, see the [Ukrainian recovery runbook](RESTORE_RUNBOOK_UA.md).

## Deploy and roll back dev

Run on the dev Swarm manager from `/opt/opencloud`. Check the target, age key, storage, network, Entra settings, available backup and maintenance window first. Production requires separate authorization and its own host and settings. The apply operation may install Borg, prepare directories and update the node label, secrets, Configs and service; a failure may leave some changes in place.

```bash
export SERVER_ENV=dev ORCHESTRATOR_MODE=swarm ENVIRONMENT_NAME=development
export STACK_NAME=opencloud ORCHESTRATOR_ENV_FILE=env.dev.enc
./scripts/deploy-orchestrator-swarm.sh --check
```

If the check succeeds and the intended dev change is approved, deploy and inspect the result:

```bash
./scripts/deploy-orchestrator-swarm.sh --deploy --apply
docker service ls --filter name=opencloud_opencloud
docker service ps opencloud_opencloud
```

Confirm container health, external HTTPS, Entra login, a file download and upload, Space access and public links. `1/1` alone is not acceptance. Stop on failure and inspect the service and deployment output before retrying. The [script runbook](scripts_runbook.md#swarm-deployment-orchestration-category-1b) covers prerequisites and manual commands.

For a service-spec rollback, review the current and previous image and replica count; also assess the previous configuration, mounts and secrets before applying it:

```bash
docker service inspect opencloud_opencloud --format 'current image={{.Spec.TaskTemplate.ContainerSpec.Image}} replicas={{.Spec.Mode.Replicated.Replicas}}{{if .PreviousSpec}}; previous image={{.PreviousSpec.TaskTemplate.ContainerSpec.Image}} replicas={{.PreviousSpec.Mode.Replicated.Replicas}}{{else}}; no previous specification{{end}}'
```

If a previous specification exists and is suitable, execute the following and repeat the acceptance checks above:

```bash
docker service rollback --detach=false opencloud_opencloud
docker service ps opencloud_opencloud
```

[Docker service rollback](https://docs.docker.com/reference/cli/docker/service/rollback/) restores the previous service specification, which may include a different replica count, mounts, Configs or secrets. It does not restore persistent data or the SOPS file. After a state migration, use the matching backup and configuration recovery procedure; an image rollback alone may be incompatible.

## Change the OpenCloud Swarm Secret

The secret contains state-coupled `opencloud.yaml`; do not regenerate it with `opencloud init` over existing data. Before a change, retain a usable backup and its matching configuration, and identify the recovery point. The [SOPS procedure](scripts_runbook.md#write-and-verify-the-base64-value) writes and compares a reviewed environment-specific YAML without printing it. Stage any plaintext on owner-only `/dev/shm`, then update the correct SOPS file. A changed YAML hash produces a new secret name; an unchanged value reuses the existing secret.

For dev, set the environment as in the deployment section and run the dry run, then deploy only after reviewing the result:

```bash
./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-map.env
./scripts/deploy-orchestrator-swarm.sh --check
./scripts/deploy-orchestrator-swarm.sh --deploy --apply
```

The orchestrator applies reconciliation and deploys the new reference. Verify service health and the user checks above; keep the prior secret and matching configuration while rollback or recovery may need them. Remove plaintext staging files when no longer needed.

Old secrets are removed manually only after the owner approves removal and confirms neither recovery nor rollback needs them. Set the exact old name from `docker secret ls`, then inspect references in both current and previous specifications of every service:

```bash
old_secret='REPLACE_WITH_VERIFIED_OLD_SECRET_NAME'
docker secret inspect "$old_secret" --format '{{.Spec.Name}}'
python3 - "$old_secret" <<'PYCODE'
import json, subprocess, sys
name = sys.argv[1]
ids = subprocess.check_output(['docker', 'service', 'ls', '-q'], text=True).split()
for service_id in ids:
    service = json.loads(subprocess.check_output(['docker', 'service', 'inspect', service_id]))[0]
    for field in ('Spec', 'PreviousSpec'):
        spec = service.get(field) or {}
        container = spec.get('TaskTemplate', {}).get('ContainerSpec', {})
        if any(secret.get('SecretName') == name for secret in container.get('Secrets', [])):
            print(f"{spec.get('Name', service_id)}: {field}")
PYCODE
```

Stop if inspection fails or prints any reference. Also check for concurrent deployments and other recovery dependencies. Only after these checks and authorization:

```bash
docker secret rm "$old_secret"
```

Never print secret values or full service specifications in shared logs. Internal cryptographic keys are not routinely rotated; changing them requires a separately validated data and identity migration.

## Add a Space Manager

An existing Space Manager or administrator opens the intended Space in the UI, opens its members, finds the already provisioned user or appropriate group, assigns **Can manage**, and confirms the change. Verify access with the recipient and keep at least one other responsible manager. This role can manage members and content; grant it only to an authorized person. See [OpenCloud Space membership](https://docs.opencloud.eu/docs/7.2/user/spaces/add-members/) and [Space roles](https://docs.opencloud.eu/docs/user/roles/space-roles/). Entra group synchronization can affect membership; verify the actual access after login.

## Offboard a user

1. Identify the user, owned personal space, managed Spaces, direct grants and public links. Agree with the data owner on retention, access transfer and replacement managers before removal.
2. An authorized Entra administrator disables the account or removes applicable access groups and revokes sign-in sessions according to the organization's procedure. Follow [Microsoft's access revocation guidance](https://learn.microsoft.com/en-us/entra/identity/users/users-revoke-access); existing tokens or sessions may remain usable until they expire or are otherwise invalidated.
3. Verify that sign-in and access have ceased, including existing sessions. Review and revoke direct shares and public links as appropriate; disabling an account does not itself prove that links are inaccessible.
4. Transfer required Space management and data through supported UI procedures. Accounts and personal spaces can remain after offboarding; delete them only after the owner approves the retention and deletion decision. Record the actions without tokens or personal file contents.

## Known limitations

- Backup stops a running service during archive creation; restore also causes downtime. One dev backup logged a restart request after 18 seconds, but end-to-end user downtime is not measured. Keep a maintenance window and measure it separately.
- The single storage node is a single point of failure. A local restore was exercised on dev; clean-node recovery and measured RTO/RPO remain unverified.
- Entra availability is required for Entra login. A second Entra admin is the planned break-glass account; its availability is not established by this runbook. JIT group synchronization can remove manual memberships when claims are absent, and denied users may still be provisioned ([issue #4058](https://github.com/opencloud-eu/opencloud/issues/4058)). Bulk staff assignment depends on the A1 licensing decision.
- Internal `opencloud.yaml` keys are not routinely rotated. Dev and prod share an age recipient: compromise of its private key affects both.
- Passwordless public read links are enabled; anyone holding a valid link can read it. An expiry policy is not explicitly set in the stack and must be verified before relying on it. Writable public links require a password.
- Offboarded accounts and personal spaces require an explicit retention and cleanup decision. Desktop clients and Google Drive data migration are outside the current scope.
- The Entra CSP Config is present, but the broader `frame-ancestors` CSP and Drupal AC-5 work is deferred. Do not infer those controls are complete.

## Restore a Borg backup

This procedure targets the `opencloud` **dev** stack on its Swarm manager and sole `storage=primary` node. It replaces live state and needs an approved maintenance window; production requires separate authorization and the correct production environment, repository and service. Run as an operator with the privileges needed to restore ownership and xattrs. Stop backups, deployments, upgrades and external schedulers for the entire procedure. Ensure no other process writes to the data tree or Borg repository.

The local repository is `/srv/opencloud/backup/repository`, and the service bind mount is `/srv/opencloud/data` in the example below. Verify both paths for the actual environment and archive; do not assume dev paths or secrets apply to prod. A selected archive contains the data tree and the `opencloud.yaml`, service specification, SOPS environment values and Swarm Config records that were captured with it. These may contain secrets. The matching configuration and image must be available with the restored state. Do not run `opencloud init` over existing or restored state.

If the local repository is unavailable, first copy a completed, dated Drive repository into a **new**, private local directory, using the configured remote and credentials. Replace the example with the exact remote directory selected for dev, and confirm the marker reads `opencloud-backup-v1 dev` before copying:

```bash
remote_dir='REPLACE_WITH_REMOTE:PATH/TO/COMPLETED_DEV_DIRECTORY'
rclone cat "$remote_dir/.opencloud-backup-owner"
```

Only after the marker matches, and after confirming sufficient local disk space:

```bash
umask 077
copy_dir=$(mktemp -d /srv/opencloud/.borg-copy.XXXXXXXX)
rclone copy "$remote_dir" "$copy_dir"
```

Stop if the copy fails. Set `BORG_REPO` below to `"$copy_dir"` instead of the example local repository. Preserve the source copy and check that Borg opens the local copy before using it. Restoring from Drive itself has not been rehearsed.

### 1. Select the archive and check the matching configuration

Before stopping the service, confirm the node, actual service bind mount, target environment, available disk space and recovery point. Keep the current state and its matching configuration for rollback. Record the service's original desired replica count; the commands below assume it is `1`. A service already at `0` must stay at `0` after recovery unless the operator separately decides to start it. For production, obtain authorization before changing service or data.

In a private shell, disable shell tracing, provide the Borg passphrase without placing it in a command argument or shell history, and list archive names. Borg can also ask for the passphrase interactively instead of exporting it:

```bash
set +x
set -o pipefail
export BORG_REPO=/srv/opencloud/backup/repository
read -r -s -p 'Borg passphrase: ' BORG_PASSPHRASE; printf '\n'
export BORG_PASSPHRASE
borg list --short "$BORG_REPO"
```

Select an archive from the output and set its exact name. Confirm it belongs to the intended environment. List only its recovery metadata paths; do not publish their contents:

```bash
archive='REPLACE_WITH_SELECTED_ARCHIVE_NAME'
borg list --short "$BORG_REPO::$archive" | awk '/^dev\/shm\/opencloud-backup\.[^/]+\/(opencloud.yaml|service.json|env|swarm-configs)$/ {print}'
```

The entries must share one `dev/shm/opencloud-backup.*` prefix. Replace the example with that exact archive-relative prefix. Confirm `/dev/shm` is tmpfs. Extract just the archived config and service specification to a private temporary directory, never into the live config or data tree:

```bash
findmnt -n -o FSTYPE --mountpoint /dev/shm
```

Continue only if the result is `tmpfs`:

```bash
umask 077
recovery_tmp=$(mktemp -d /dev/shm/opencloud-recovery.XXXXXXXX)
metadata_dir='dev/shm/opencloud-backup.REPLACE_WITH_ARCHIVED_SUFFIX'
borg extract --stdout "$BORG_REPO::$archive" "$metadata_dir/opencloud.yaml" > "$recovery_tmp/opencloud.yaml" &&
  borg extract --stdout "$BORG_REPO::$archive" "$metadata_dir/service.json" > "$recovery_tmp/service.json"
```

Stop if either extraction fails. Compare the archived config with the current dev SOPS config without printing its contents, then compare its hash-derived secret name with the secret attached to the actual service:

```bash
set -o pipefail
sops --decrypt --input-type dotenv --output-type binary --extract '["OPENCLOUD_YAML_B64"]' env.dev.enc |
  base64 --decode | cmp -s "$recovery_tmp/opencloud.yaml" - && echo 'SOPS config matches archive'
config_hash=$(sha256sum "$recovery_tmp/opencloud.yaml")
printf 'Expected secret: opencloud_opencloud_yaml_v%s\n' "${config_hash:0:16}"
docker service inspect opencloud_opencloud --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{if eq .File.Name "/etc/opencloud/opencloud.yaml"}}{{.SecretName}}{{end}}{{end}}'
```

Continue only when the comparison succeeds and the secret names match. Privately review `service.json` against the current service: image and its digest, data mount, environment and Swarm Config references must be appropriate for the recovery point. Recover or recreate matching settings using an authorized, reviewed procedure if they differ; do not deploy or start the service until they match. The archive's `env` and `swarm-configs` can support that investigation, but extracting `env` exposes secrets and must be confined to owner-only tmpfs. A newer OpenCloud image or changed configuration is not automatically compatible with older data.

### 2. Stop the service and extract to a separate directory

Identify a suitable control file's archive-relative path under `srv/opencloud/data`; its `user.oc.id` will be checked after extraction. Ensure `getfattr` is installed and leave enough space for both current and restored data. Do not continue if `/srv/opencloud/data.old` already exists or if the path is a mountpoint that cannot be renamed. The destination must be on the same filesystem as `/srv/opencloud/data`.

```bash
docker service scale --detach=false opencloud_opencloud=0
docker ps --filter label=com.docker.swarm.service.name=opencloud_opencloud --format '{{.ID}}'
```

Proceed only if scaling succeeded, the command succeeded and it printed no container ID. Verify no external writer has the data tree open. From this point every failure leaves the service stopped; notify the operator and investigate. Do not run another deployment or backup.

```bash
parent=/srv/opencloud
test ! -e "$parent/data.old" && test ! -e "$parent/data.restore" &&
  restore_stage=$(mktemp -d "$parent/.restore-stage.XXXXXXXX") &&
  (cd "$restore_stage" && borg extract "$BORG_REPO::$archive" srv/opencloud/data)
```

Stop at the first failing command; never run the extraction if the existence check fails. The archive path above is for the default data path. For a custom bind mount, select its archive-relative path from the archive and adjust the extraction and paths consistently. Extraction into the staging parent preserves the data directory's own metadata; it does not use `--strip-components`.

Check the restored directory, ownership and mode, file count, available space and a known control file. Replace the path below with the exact regular file relative to the restored data directory; do not use `..` or a symlink. Verify expected file count and content against the recovery point rather than assuming a nonzero count proves completeness:

```bash
candidate="$restore_stage/srv/opencloud/data"
control_rel='REPLACE_WITH_KNOWN_CONTROL_FILE_PATH'
stat -c '%u:%g %a %n' "$candidate"
find "$candidate" -type f -printf '.' | wc -c
getfattr -n user.oc.id --only-values -- "$candidate/$control_rel" >/dev/null && echo 'Control file xattr is readable'
```

Compare the directory owner and mode with the service's configured UID/GID and access requirements. If any check fails, leave the service stopped and inspect the isolated extraction; do not rename live data. A readable xattr is a limited check, not proof that all state, users, grants or links are recoverable.

### 3. Switch the data and accept recovery

Only after all checks and configuration matching succeed, move the restored directory into place. The previous directory remains as `data.old`:

```bash
mv -T -- "$parent/data" "$parent/data.old" &&
  mv -T -- "$candidate" "$parent/data"
```

If either move fails, **leave the service stopped**. Inspect which paths exist. If the first move succeeded and the second failed, the operator can restore the previous path with `mv -T -- /srv/opencloud/data.old /srv/opencloud/data` only after confirming `/srv/opencloud/data` is absent. Do not overwrite either tree. If reverting after a completed switch, first stop the service and preserve the restored tree under a new distinct name before moving `data.old` back; restore its matching configuration too.

If the service was running before recovery and the switch completed successfully:

```bash
docker service scale --detach=false opencloud_opencloud=1
docker service ls --filter name=opencloud_opencloud --format '{{.Name}} {{.Replicas}}'
docker ps --filter label=com.docker.swarm.service.name=opencloud_opencloud --format '{{.Names}} {{.Status}}'
```

Check health, external HTTPS, Entra login, a known file download, upload, users, Spaces, grants, public links and search. Allow time for the Traefik Swarm provider to refresh its route after startup and retry the HTTPS check within a bounded window before declaring a route failure. A `1/1` service or healthy proxy alone does not prove recovery. If acceptance fails, stop the service and investigate or roll back the data **and matching configuration**. Keep `data.old` until the owner explicitly accepts recovery; its later deletion is a separate irreversible operation.

When finished or abandoning the procedure, remove the owner-only temporary config directory and unset the passphrase in the same shell. Inspect and remove the empty staging directory only after confirming it contains no needed recovery data:

```bash
rm -rf -- "$recovery_tmp"
unset BORG_PASSPHRASE
```

A shell, host or power failure may leave temporary files or the service stopped; inspect state before resuming. Record recovery point, observations and downtime without recording secrets.

### Restore one file through the UI

First check the OpenCloud trash and file version history. Otherwise, select a known archive and the exact archive-relative path of a regular content file. With `BORG_REPO`, `BORG_PASSPHRASE` and `archive` set as above, extract only that file into a private directory:

```bash
umask 077
file_stage=$(mktemp -d /srv/opencloud/.file-restore.XXXXXXXX)
file_path='srv/opencloud/data/REPLACE_WITH_EXACT_PATH'
(cd "$file_stage" && borg extract "$BORG_REPO::$archive" "$file_path")
```

Inspect the extracted file privately, then upload it to the appropriate Space through the UI. Do not copy extracted files directly into the live PosixFS tree. Remove the temporary file when it is no longer needed. Archive path names and file contents may be sensitive. One dev archive file was extracted and the owner reported a successful UI upload. Mapping a different UI file to its archive path requires operator investigation.
