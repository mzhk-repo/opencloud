# OpenCloud recovery runbook

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

Inspect the extracted file privately, then upload it to the appropriate Space through the UI. Do not copy extracted files directly into the live PosixFS tree. Remove the temporary file when it is no longer needed. Archive path names and file contents may be sensitive. This procedure and its mapping from an OpenCloud file to its archive path require a dev rehearsal.
