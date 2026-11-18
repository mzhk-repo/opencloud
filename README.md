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

Public read-only links can be created without a password; writable public links require one. Anyone with a passwordless link can access its contents.

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

After initialization, prepare the Entra settings and group-to-role mapping as described below before starting the main service. Use the internal login override for local administration.

Check a prepared storage directory with `./scripts/preflight-host.sh /srv/opencloud/data`. The check needs `findmnt`, `df`, `awk`, `mktemp` and Python 3. It requires at least 10 GiB free for the planned test file; provision additional space for real data and overhead. The printed 70% memory reference does not set a limit; choose a separate dev limit after measuring actual usage.

## Local Entra and internal login

The main Compose configuration uses Entra with JIT provisioning and group-to-role mapping at `https://localhost:9200`. OpenCloud 7.2.5 does not enforce the access-token audience and UPN is mutable; keep this instance on loopback until those risks are resolved. Entra must supply `upn`, `name`, `email` and group claims. Configure the SPA redirect URIs for port 9200 and the `access_as_user` scope.

Put `ENTRA_TENANT_ID` and `ENTRA_CLIENT_ID` in the ignored `.local/entra-poc.env` using `.env.example` as a template. Place the group mapping in `.local/opencloud/config/proxy.yaml`, using `config/proxy.groups.example.yaml` as a template; the existing isolated PoC mapping can be copied there. Do not commit the local mapping or environment file.

JIT synchronizes group membership at login and can remove manually assigned memberships, including when the group claim is absent. A denied user can still be provisioned. See [OpenCloud issue #4058](https://github.com/opencloud-eu/opencloud/issues/4058); group overage and final deployment remain unverified.

To start the main instance with Entra, from the repository root:

```bash
export OPENCLOUD_LOCAL_UID="$(id -u)" OPENCLOUD_LOCAL_GID="$(id -g)"
docker compose --env-file .env.example --env-file .local/entra-poc.env config -q
docker compose --env-file .env.example --env-file .local/entra-poc.env up -d
```

To switch the same instance to its internal IdP and existing local administrator account:

```bash
export OPENCLOUD_LOCAL_UID="$(id -u)" OPENCLOUD_LOCAL_GID="$(id -g)"
docker compose --env-file .env.example -f docker-compose.yml -f docker-compose.internal.yml config -q
docker compose --env-file .env.example -f docker-compose.yml -f docker-compose.internal.yml up -d
```

The example environment file supplies placeholders required when Compose parses the base file; the internal override removes the Entra settings. Switching recreates the container and interrupts service. To return to Entra, run the main instance commands above. Do not run both modes as separate projects against the same data, reinitialize OpenCloud, or delete state. For a remote host use an SSH local port forward to `127.0.0.1:9200`. Keep tokens, passwords and configuration contents out of diagnostics.
