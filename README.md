# OpenCloud storage

Phase 1 plans a university file store using OpenCloud, PosixFS and Microsoft Entra ID. See [the specification](docs/SPEC.md) and [implementation roadmap](docs/ROADMAP.md) for requirements and acceptance criteria.

## Repository

- `docs/`: requirements, roadmap, AI context and changelog volumes.
- `scripts/`: planned host checks, deployment and backup scripts.
- `config/`: planned static service configuration.
- `.github/workflows/`: reserved for the shared CI/CD workflow.
- `.env.example`: image repository and version; contains no secrets.

## Local development

The local Compose setup is for an isolated Linux host with Docker Compose and user xattrs. Docker Desktop on macOS or Windows is unsuitable for these bind mount xattr checks. The service listens on host loopback only and uses a self-signed certificate; `OC_INSECURE` is for this local test only. Do not commit local state or plaintext environment files. See the [OpenCloud 7.2 Docker guide](https://github.com/opencloud-eu/docs/blob/main/versioned_docs/version-7.2/admin/getting-started/container/docker.md).

For a new local instance, run from the repository root. The guard stops if the local instance directory already exists; never reinitialize existing data. The `init` output may contain a generated admin password: keep it private and save it securely. Select the insecure certificate option only for this isolated test.

```bash
( set -e
  if [ -e .local/opencloud ]; then
    echo 'Local instance directory exists; stop and investigate.' >&2
    exit 1
  fi
  mkdir -p .local/opencloud/config .local/opencloud/data
  chmod 700 .local/opencloud/config .local/opencloud/data
  ./scripts/preflight-host.sh .local/opencloud/data
  docker run --rm -it --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$PWD/.local/opencloud/config,dst=/etc/opencloud" \
    --mount "type=bind,src=$PWD/.local/opencloud/data,dst=/var/lib/opencloud" \
    opencloudeu/opencloud:7.2.5 init
)
```

If initialization fails or leaves partial state, stop and investigate; do not rerun it on existing data. The example runs the container as the current Linux UID/GID. Docker user namespace remapping can change host ownership requirements; resolve access for both mounts before proceeding.

After successful initialization, start the local service as the same user:

```bash
export OPENCLOUD_LOCAL_UID="$(id -u)" OPENCLOUD_LOCAL_GID="$(id -g)"
docker compose --env-file .env.example config -q
docker compose --env-file .env.example up -d
docker compose --env-file .env.example ps
```

Open `https://localhost:9200` on the Docker host and sign in as `admin` using the password from initialization. For a remote dev host, use an SSH local port forward to its `127.0.0.1:9200`; do not expose this test instance publicly. Upload a test file, then inspect its `user.oc.*` xattrs on the host and inspect state paths inside the container. Stop with `docker compose --env-file .env.example down`; the bind-mounted state remains.

Check a prepared storage directory with `./scripts/preflight-host.sh /srv/opencloud/data`. The check needs `findmnt`, `df`, `awk`, `mktemp` and Python 3. It requires at least 10 GiB free for the planned test file; provision additional space for real data and overhead. The printed 70% memory reference does not set a limit; choose a separate dev limit after measuring actual usage.

## Local Entra PoC

This opt-in override is for a loopback-only test with manually provisioned users. OpenCloud 7.2.5's access-token verifier does not enforce the token audience; do not expose this PoC or use it for production. UPN is mutable and is not a safe permanent authorization identifier.

Before switching, create a test user in the internal-IdP UI with an OpenCloud username matching the Entra user's UPN. The Entra app must have the registered SPA redirect URIs, enabled `access_as_user` scope and consent, v2 access tokens, optional `upn` access-token claim, and a test user assigned. The override does not create users. Put `ENTRA_TENANT_ID` and `ENTRA_CLIENT_ID` in `.local/entra-poc.env`, using `.env.example` as a template; the file is ignored by Git.

To apply the PoC on the local host:

```bash
export OPENCLOUD_LOCAL_UID="$(id -u)" OPENCLOUD_LOCAL_GID="$(id -g)"
docker compose --env-file .env.example --env-file .local/entra-poc.env \
  -f docker-compose.yml -f docker-compose.entra.yml config -q
docker compose --env-file .env.example --env-file .local/entra-poc.env \
  -f docker-compose.yml -f docker-compose.entra.yml up -d
```

To return to the internal IdP, recreate the service without the override:

```bash
docker compose --env-file .env.example -f docker-compose.yml up -d
```

Do not rerun `opencloud init` or delete local state when switching. Keep tokens, passwords and configuration contents out of diagnostics.

## Isolated autoprovisioning PoC

For the earlier App Role PoC, use test accounts assigned to the Entra application and absent from the copied OpenCloud users. The override maps the `opencloudAdmin` and `opencloudUser` Entra app roles via the `roles` claim and disables Graph's default role assignment. Autoprovisioning in 7.2.5 also updates user attributes and synchronizes group memberships: a missing `groups` claim can remove existing memberships. Run this PoC only on a separate copy, never on the existing state. The `upn` and `name` access-token claims are required. The audience and mutable UPN risks described above still apply.

The subsequent group-claim PoC adds `docker-compose.groups.yml` to map Entra group IDs to roles using an ignored local `proxy.yaml`. The project retains the official image and its built-in synchronization: Entra GUID groups can be created locally, and memberships absent from the configured claim can be removed on login. This includes manually assigned memberships and a missing claim. Independent control is requested in [OpenCloud issue #4058](https://github.com/opencloud-eu/opencloud/issues/4058); its proposed switch is not available in 7.2.5. Group overage, token audience validation and the final deployment remain unverified.

To administer existing accounts on the isolated copy with its internal IdP, recreate only the isolated project using `-f docker-compose.yml -f docker-compose.isolated-internal.yml`, sign in as its existing local administrator at port 19200, and remove only the intended test users. Keep the local administrator. Return to Entra using the three-file command below. Account deletion affects the copied state and may affect those users' personal data; retain anything needed before deletion.

Add SPA redirect URIs `https://localhost:19200/`, `https://localhost:19200/oidc-callback.html`, and `https://localhost:19200/oidc-silent-redirect.html` in Entra. The source service is briefly stopped while copying. Run from the repository root; if any command fails, stop and investigate without reinitializing or deleting state:

```bash
( set -eu
  test ! -e .local/autoprovision-poc
  mkdir -p .local/autoprovision-poc/data .local/autoprovision-poc/config
  trap 'docker compose --env-file .env.example start opencloud' EXIT
  docker compose --env-file .env.example stop opencloud
  rsync -aX .local/opencloud/data/ .local/autoprovision-poc/data/
  cp -p .local/opencloud/config/opencloud.yaml .local/autoprovision-poc/config/opencloud.yaml
  docker compose --env-file .env.example start opencloud
  trap - EXIT
)
```

Then start the separate Compose project:

```bash
export OPENCLOUD_LOCAL_UID="$(id -u)" OPENCLOUD_LOCAL_GID="$(id -g)"
docker compose -p opencloud-autoprovision-poc \
  --env-file .env.example --env-file .local/entra-poc.env \
  -f docker-compose.yml -f docker-compose.entra.yml \
  -f docker-compose.autoprovision.yml config -q
docker compose -p opencloud-autoprovision-poc \
  --env-file .env.example --env-file .local/entra-poc.env \
  -f docker-compose.yml -f docker-compose.entra.yml \
  -f docker-compose.autoprovision.yml up -d
```

Open `https://localhost:19200/` in a private window; for a remote host forward port 19200 over SSH. Sign in as the new assigned test account twice and check its files. The copy and its config contain sensitive data and are ignored by Git; retain them only for the duration of this PoC. Do not send tokens, logs containing claims, or passwords.

To stop the isolated instance without removing its copied state:

```bash
docker compose -p opencloud-autoprovision-poc \
  --env-file .env.example --env-file .local/entra-poc.env \
  -f docker-compose.yml -f docker-compose.entra.yml \
  -f docker-compose.autoprovision.yml stop
```
