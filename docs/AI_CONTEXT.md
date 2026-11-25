# AI_CONTEXT.md

## Project summary

Phase 1 provides a university file store for up to 1,000 staff using OpenCloud, PosixFS and Microsoft Entra ID. The dev Swarm service has been deployed and restored from Borg; the owner confirmed Entra login, Space access and existing public links. Clean-node recovery, RTO/RPO and production acceptance remain open. See [ROADMAP.md](ROADMAP.md) for detailed evidence and remaining criteria.

## Decisions and constraints

- One non-root OpenCloud replica with PosixFS and no external database or Redis in the stack. Web access uses Entra OIDC and group-to-role mapping. Desktop/mobile clients, Drupal integration and Google Drive data migration are outside Phase 1.
- The official image, Docker Swarm, Cloudflare Tunnel, Traefik, SOPS/age, Swarm Secrets, Borg and rclone form the stack. [README.md](../README.md#architecture-and-technology-stack) describes the architecture and network risks.
- Entra JIT sync can remove manually assigned group memberships when claims are absent; denied users may still be provisioned. Audience validation and mutable UPN require attention; see [ROADMAP.md](ROADMAP.md) and [issue #4058](https://github.com/opencloud-eu/opencloud/issues/4058).
- Preserve secrets and matching state. Dev and prod use the same age recipient. Never run `opencloud init` over existing data; do not modify the storage tree while the service is running. Identify the environment and obtain approval for production or destructive operations.
- Storage uses user xattrs; a backup is not accepted as a full recovery until the relevant service and user workflows have been verified. See the [operator runbook](RUNBOOK.md), [script commands](scripts_runbook.md), and [Ukrainian recovery runbook](RESTORE_RUNBOOK_UA.md).

## Working in the repository

[SPEC.md](SPEC.md), [ROADMAP.md](ROADMAP.md) and applicable ADRs take precedence over this summary. Resolve relevant differences before implementation. Read the active changelog volume via [CHANGELOG.md](../CHANGELOG.md). Follow script categories, secret handling and validation requirements in the roadmap; distinguish observed evidence from assumptions and preserve unrelated changes.

## Last updated

2026-11-24
