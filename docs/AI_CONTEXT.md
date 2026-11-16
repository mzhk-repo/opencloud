# AI_CONTEXT.md

## Project Summary

Phase 1 plans a university file store for up to 1,000 staff using OpenCloud. This repository currently contains planning documents; implementation and runtime acceptance are pending.

## Key Decisions

- One OpenCloud container, PosixFS in non-collaborative mode, no separate database or Redis.
- Web-only access via Microsoft Entra ID; Spaces provide per-user access. Direct OIDC and staff filtering require a PoC.
- Drupal, online editors, native clients, group synchronization and Google Drive migration are outside Phase 1.

## Architecture Snapshot

Browser → Traefik → one OpenCloud replica in Docker Swarm; Entra ID provides authentication. The planned host data mount is `/srv/opencloud/data` → `/var/lib/opencloud` on XFS/ext4 with user xattrs. Do not modify the storage tree while the service is running.

The SPEC includes a separate host config directory; the ROADMAP proposes a Swarm Secret instead, subject to the state-layout investigation. Back up all required state and configuration; preserve xattrs and verify recovery of users, grants and public links.

## Tech Stack

Official `opencloudeu/opencloud:7.2.5` production image, Docker Swarm, Traefik, Microsoft Entra ID/OIDC, SOPS/age, Swarm Secrets and BorgBackup. The image tag was confirmed by the project owner.

## Security Constraints

- Keep secrets out of Git, logs and generated mappings; use SOPS and Swarm Secrets. Separate dev and production keys.
- Identify the target environment before changes; obtain explicit approval for production or destructive operations. Never expose credentials.
- Initialize OpenCloud once per environment; do not rerun `opencloud init` over existing data. Failed restores must leave the service stopped.

## Repository Structure

- `docs/SPEC.md`, `docs/ROADMAP.md`: requirements and implementation plan.
- `CHANGELOG.md` and `docs/changelogs/`: changelog index and active volume.
- `scripts/preflight-host.sh`: storage preflight; `docker-compose.yml`: isolated local setup. Swarm and CI are planned.

## Important Documents

Use [SPEC.md](SPEC.md), [ROADMAP.md](ROADMAP.md) and any applicable ADRs as authoritative sources over this summary. The roadmap explicitly lists proposed deviations from the SPEC; resolve relevant differences before implementation. No ADR was found in the current tree.

## Implementation Rules for AI Agents

- Read the relevant source sections and acceptance criteria before changes; preserve unrelated work and keep changes minimal.
- Script categories: 1a `preflight-host` checks the host without env, SOPS or Docker; planned 1b `init-volumes` and `reconcile-sops-secrets` prepare deployment; category 2 `backup` handles maintenance and backup. The orchestrator coordinates deployment.
- Follow the roadmap's Bash, idempotency, secret handling and YAML requirements. When applicable, check with `shellcheck`, `yamllint`, `docker compose config -q` and `docker stack config`; run only checks supported by the current files and environment.
- Record observed results separately from assumptions; update this file only after material architecture changes or as specified by the roadmap.

## Known Assumptions

The internal state layout, required configuration backup and OIDC claim mapping are unverified. The roadmap's SOPS-to-Swarm-Secret design and backup scope depend on the local state-layout investigation.

## State layout

Pending local runtime inspection: identify user files, idm, NATS KV, search indexes and whether indexes rebuild; verify config writes and secret recovery. Local Compose uses `.local/opencloud/data` and a read-only `.local/opencloud/config/opencloud.yaml` mount; these are not yet runtime-validated.

## Open Questions

Confirm Entra Education A1 role assignment and staff filtering, fallback account provisioning, token validation, stable user identity, actual state layout and recovery, health endpoint, and maintenance commands. See roadmap tasks 1.3, 2.1–2.2 and 6.1–6.4.

## Last Updated

2026-11-16
