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
