# AI_CONTEXT.md

## Project Summary

Phase 1 plans a university file store for up to 1,000 staff using OpenCloud. A local instance has been started; deployment and runtime acceptance remain pending.

## Key Decisions

- One OpenCloud container, PosixFS in non-collaborative mode, no separate database or Redis.
- Web-only access via Microsoft Entra ID; Spaces provide per-user access. Direct OIDC and staff filtering require a PoC.
- Drupal, online editors, native clients and Google Drive migration are outside Phase 1. Built-in OIDC group synchronization remains enabled with JIT.

## Architecture Snapshot

Browser → Traefik → one OpenCloud replica in Docker Swarm; Entra ID provides authentication. The planned host data mount is `/srv/opencloud/data` → `/var/lib/opencloud` on XFS/ext4 with user xattrs. Do not modify the storage tree while the service is running.

The SPEC includes a separate host config directory; the ROADMAP proposes a Swarm Secret instead, subject to the state-layout investigation. Back up all required state and configuration; preserve xattrs and verify recovery of users, grants and public links.

## Tech Stack

Official `opencloudeu/opencloud:7.2.5` production image, Docker Swarm, Traefik, Microsoft Entra ID/OIDC, SOPS/age, Swarm Secrets and BorgBackup. The image tag was confirmed by the project owner.

## Security Constraints

- Keep secrets out of Git, logs and generated mappings; use SOPS and Swarm Secrets. The owner selected the SMTP2Graph age recipient for both dev and prod; its private key grants access to both.
- Identify the target environment before changes; obtain explicit approval for production or destructive operations. Never expose credentials.
- Initialize OpenCloud once per environment; do not rerun `opencloud init` over existing data. Failed restores must leave the service stopped.

## Repository Structure

- `docs/SPEC.md`, `docs/ROADMAP.md`: requirements and implementation plan.
- `CHANGELOG.md` and `docs/changelogs/`: changelog index and active volume.
- `scripts/preflight-host.sh`: storage preflight; `docker-compose.yml`: isolated local setup. `docker-stack.yml` defines a Swarm service with a configurable memory limit defaulting to 2.5 GiB; deployment, Traefik and CI are planned.
- Local Compose defaults to Entra on port 9200; `docker-compose.internal.yml` switches the same instance to its internal IdP. The main instance has not yet been validated with Entra and group synchronization.
- `scripts/reconcile-sops-secrets.sh`: planned Swarm secret preparation; selects dev/prod from `/etc/environment` and verifies exported `SERVER_ENV`. Encrypted environment files contain placeholders and require configuration.

## Important Documents

Use [SPEC.md](SPEC.md), [ROADMAP.md](ROADMAP.md) and any applicable ADRs as authoritative sources over this summary. The roadmap explicitly lists proposed deviations from the SPEC; resolve relevant differences before implementation. No ADR was found in the current tree.

## Implementation Rules for AI Agents

- Read the relevant source sections and acceptance criteria before changes; preserve unrelated work and keep changes minimal.
- Script categories: 1a `preflight-host` checks the host without env, SOPS or Docker; planned 1b `init-volumes` and `reconcile-sops-secrets` prepare deployment; category 2 `backup` handles maintenance and backup. The orchestrator coordinates deployment.
- Follow the roadmap's Bash, idempotency, secret handling and YAML requirements. When applicable, check with `shellcheck`, `yamllint`, `docker compose config -q` and `docker stack config`; run only checks supported by the current files and environment.
- Record observed results separately from assumptions; update this file only after material architecture changes or as specified by the roadmap.

## Known Assumptions

Local Entra PoC: group-role mapping and denial were verified; denied users can still be provisioned. JIT synchronizes group memberships and can remove manually assigned memberships; an absent claim can result in an empty membership set. Keep the official image without a custom patch; independent sync control is requested in [issue #4058](https://github.com/opencloud-eu/opencloud/issues/4058). Audience is not enforced and UPN is mutable; keep the PoC loopback-only.

## State layout

Local inspection: `.local/opencloud/data` maps to `/var/lib/opencloud`; PosixFS uses `storage/users`, identity data includes `idm/idm.boltdb`, NATS state uses `nats/jetstream`, and Bleve data appears under `search/bleve`. `user.oc.id` was readable on the uploaded PDF. Compose mounts `opencloud.yaml` read-only over a writable Docker volume at `/etc/opencloud`; metadata did not change after typical UI actions. On an isolated data copy with a fresh config volume, the user confirmed login and file access; no extra config entries remained. Transient writes, SOPS/Swarm secret recovery and index rebuild remain unverified.

## Open Questions

Confirm Entra Education A1 role assignment and staff filtering, fallback account provisioning, token validation, stable user identity, actual state layout and recovery, health endpoint, and maintenance commands. See roadmap tasks 1.3, 2.1–2.2 and 6.1–6.4.

## Last Updated

2026-11-23
