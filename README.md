# OpenCloud storage

Phase 1 plans a university file store using OpenCloud, PosixFS and Microsoft Entra ID. See [the specification](docs/SPEC.md) and [implementation roadmap](docs/ROADMAP.md) for requirements and acceptance criteria.

## Repository

- `docs/`: requirements, roadmap, AI context and changelog volumes.
- `scripts/`: planned host checks, deployment and backup scripts.
- `config/`: planned static service configuration.
- `.github/workflows/`: reserved for the shared CI/CD workflow.
- `.env.example`: image repository and version; contains no secrets.

## Local development

The local Compose setup and startup instructions are planned in roadmap task 1.3; there is no runnable service yet. Use a Linux host for the planned bind mount and xattr checks. Do not commit local state or plaintext environment files.

Check a prepared storage directory with `./scripts/preflight-host.sh /srv/opencloud/data`. The check needs `findmnt`, `df`, `awk`, `mktemp` and Python 3. It requires at least 10 GiB free for the planned test file; provision additional space for real data and overhead. The printed 70% memory reference does not set a limit; choose a separate dev limit after measuring actual usage.
