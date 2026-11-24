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
    opencloudeu/opencloud:9.1.1 init
)
```

If initialization fails or leaves partial state, stop and investigate; do not rerun it on existing data. The example runs the container as the current Linux UID/GID. Docker user namespace remapping can change host ownership requirements; resolve access for both mounts before proceeding.

After initialization, prepare the Entra settings and group-to-role mapping as described below before starting the main service. Use the internal login override for local administration.

Prepare the target data directory with `scripts/init-volumes.sh` on the storage node and then check it with `scripts/preflight-host.sh`; see the [scripts runbook](docs/scripts_runbook.md). Preflight needs `findmnt`, `df`, `awk`, `mktemp` and Python 3. It requires at least 10 GiB free for the planned test file; provision additional space for real data and overhead. The stack defaults to 2.5 GiB; validate the limit under the expected workload.

For an existing 7.2.x installation, follow the [9.1.1 Swarm upgrade procedure](docs/scripts_runbook.md#upgrade-dev-from-72x-to-911) before starting the new image.

## SOPS and Swarm secret preparation

`.sops.yaml` uses the same public age recipient as SMTP2Graph for both dev and prod. Anyone with its private key can decrypt both environments; keep the key outside the repository and retain a separate recovery copy. `env.dev.enc` and `env.prod.enc` contain encrypted placeholders and must be populated with the appropriate values before use. Use `config/sops-env.example` as a field reference. Store each environment's `opencloud.yaml` in `OPENCLOUD_YAML_B64`; see [the scripts runbook](docs/scripts_runbook.md) for writing and checking the value without exposing it. Never save the decrypted configuration in the repository, and never run `opencloud init` over existing state.

The host must have exactly one literal `SERVER_ENV=dev` or `SERVER_ENV=prod` in `/etc/environment`, and the same value exported to the script. The script decodes the configuration into tmpfs and requires Python 3 with PyYAML to validate it. Encrypted filenames must match the host. A plaintext CI dotenv file is accepted only with owner-only permissions; do not use plaintext `env.*.enc` files. Placeholders and empty entries are rejected. With a manager node and a prepared encrypted file, first run a dry run and then, when authorized, apply:

```bash
./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-map.env
./scripts/reconcile-sops-secrets.sh -env-file env.dev.enc -environment dev -mapping-file /tmp/opencloud-map.env -apply
```

Use `env.prod.enc`, `-environment prod`, and `-approval-context <approval-id>` for an explicitly authorized production apply. The identifier records context and does not itself grant approval. Apply requires access to a Swarm manager, creates the content-addressed secret if absent, and atomically updates a mapping containing only its name. It does not deploy a service or remove old secrets. Securely remove temporary plaintext and mapping files when no longer needed. Service startup from the secret and recovery remain to be validated.

## Swarm stack preparation

`docker-stack.yml` defines one non-root OpenCloud replica with a PosixFS data bind mount and the external secret produced by reconciliation. Its default memory limit is `2.5G` (2.5 GiB); `OPENCLOUD_MEM_LIMIT` overrides it. Confirm the limit under the expected load.

Set the image, domain, Entra identifiers and secret name before rendering. `./.local/proxy.yaml` is ignored by Git and is not created by cloning the repository. Generate it on the Swarm manager with `scripts/render-proxy-config.py`; the script validates the two Entra group IDs and emits content-based names for the proxy and CSP Swarm Configs. See [the scripts runbook](docs/scripts_runbook.md) for the preparation commands. The stack uploads these files as Swarm Configs; they must not contain secrets.

Store `ENTRA_ADMIN_GROUP_ID` and `ENTRA_STAFF_GROUP_ID` in each environment's SOPS file; the generator can read them directly with `--env-file`. The existing encrypted environment files are not updated by this change. The deployment orchestrator and CI workflow do not yet exist; task 5.3 must invoke the generator and pass its name-only output to the stack before CI is connected in task 6.6.

The stack routes through the external `OPENCLOUD_PROXY_NETWORK` overlay (default `proxy-net`) to Traefik's `web` entrypoint. TLS terminates at Cloudflare Tunnel; Traefik and OpenCloud use HTTP on the overlay, and the router sets the external HTTPS forwarding headers. The orchestrator creates the overlay if missing during deployment and accepts an unencrypted overlay in both environments. Configure Traefik to join the same network. On an unencrypted overlay, this hop carries application data and tokens without TLS. Docker overlay encryption protects inter-node traffic and does not provide end-to-end TLS within a node.

The stack uses the built-in `opencloud proxy health` command to check proxy HTTP reachability. The deployment orchestrator currently requires the storage node to be the manager. On deployment it assigns `storage=primary` to that node if no node already has the label; conflicting labels stop the deployment. Prepare the data directory with the correct UID and xattr support, configure Entra and resolve the identity security gates described in the roadmap. CI integration and dev acceptance are later tasks.

## Local Entra and internal login

The main Compose configuration uses Entra with JIT provisioning and group-to-role mapping at `https://localhost:9200`. The 7.2.5 PoC did not enforce the access-token audience and UPN is mutable; these security properties require revalidation on 9.1.1; keep this instance on loopback until those risks are resolved. Entra must supply `upn`, `name`, `email` and group claims. Configure the SPA redirect URIs for port 9200 and the `access_as_user` scope.

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
