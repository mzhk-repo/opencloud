# CHANGELOG 2026 VOL 01

## 2026-11-16 — Local Entra manual-user PoC preparation

- **Context:** Start task 2.1 with manually created OpenCloud users matched to Entra UPN, as requested.
- **Change:** Added an opt-in local Compose override with JWT verification, access-token claims, disabled provisioning and placeholders for Entra identifiers.
- **Verification:** Merged Compose configuration passed `config -q`; tenant OIDC discovery returned the expected issuer and a JWKS endpoint. Authentication requires the tenant configuration and a real assigned test account.
- **Risks:** OpenCloud 7.2.5 access-token validation does not enforce audience in its verifier; UPN is mutable. The override is restricted to a local PoC and requires further security assessment before use beyond it.
- **Rollback:** Start the local Compose service without the Entra override; do not reinitialize or remove state.

## 2026-11-16 — Isolated file access check

- **Context:** Follow-up to the fresh configuration volume startup check.
- **Change:** Recorded the user's isolated login and file access result in AI context.
- **Verification:** The user reported successful checks on an isolated copy with a fresh config volume. Afterward, only `opencloud.yaml` appeared in `/etc/opencloud`; the original OIDC endpoint returned HTTP 200. The temporary container, network, volume and copied state were removed.
- **Risks:** Brief config writes, index rebuild and SOPS/Swarm secret recovery remain unverified.
- **Rollback:** Revert the state-layout documentation update.

## 2026-11-16 — Fresh configuration volume check

- **Context:** Task 1.3 must establish whether a separate persistent configuration directory is needed.
- **Change:** Recorded the isolated startup result in AI context; the original service was briefly stopped for a consistent copy and restarted.
- **Verification:** A network-isolated container with a fresh empty writable config volume, read-only `opencloud.yaml` and xattr-preserving data copy returned HTTP 200 for the UI and OIDC discovery. The copied test folder and file retained `user.oc.id`; the original discovery endpoint returned HTTP 200 after restart. Test resources were removed.
- **Risks:** Login and file access on the isolated copy, transient config writes, index rebuild and secret recovery remain unverified.
- **Rollback:** Revert the state-layout documentation update.

## 2026-11-16 — Local configuration mount inspection

- **Context:** Reviewed outstanding state and recovery checks for task 1.3.
- **Change:** Recorded the writable Docker volume at `/etc/opencloud` beneath the read-only file mount.
- **Verification:** Docker inspect reports a writable volume for the config directory and a read-only bind mount for `opencloud.yaml`. Metadata snapshots before and after user-reported UI operations matched; the same container remained running without restart.
- **Risks:** Transient writes and recreation with a fresh config volume, index rebuild and secret recovery remain unverified.
- **Rollback:** Revert the state-layout documentation update.

## 2026-11-16 — Local state inspection

- **Context:** Roadmap task 1.3 requires local login, upload and inspection of persistent state.
- **Change:** Recorded observed local storage, identity, NATS and search paths in AI context.
- **Verification:** The user reported successful login and upload; host inspection confirmed `user.oc.id` on the uploaded PDF and observed `idm.boltdb`, NATS JetStream and Bleve directories. The container is running and OIDC discovery returned HTTP 200.
- **Risks:** Index rebuild, other config writes and secret recovery remain unverified.
- **Rollback:** Revert the state-layout documentation update.

## 2026-11-16 — Local PosixFS Compose setup

- **Context:** Roadmap task 1.3 prepares a local OpenCloud instance and requires runtime inspection of its state.
- **Change:** Added a loopback-only Compose service, guarded first-time initialization instructions and a pending state-layout entry.
- **Verification:** Docker Compose configuration rendered successfully; YAML parsed, Git ignore rules cover local config and data, and `git diff --check` passed. Docker daemon access was denied.
- **Risks:** Container startup, login, uploads, xattrs, read-only config mount and actual state layout remain unverified; local self-signed TLS settings are for isolated testing only.
- **Rollback:** Remove `docker-compose.yml` and revert the related documentation changes; retain any existing local state until its owner decides otherwise.

## 2026-11-16 — Storage host preflight

- **Context:** Roadmap task 1.2 checks storage readiness without Docker or secrets.
- **Change:** Added an ext4/XFS, free-space and xattr preflight with an informational RAM reference, a focused check, and usage instructions. Documented the requested smaller dev memory limit as pending measurement.
- **Verification:** ShellCheck and focused checks passed on the repository's ext4 filesystem, including repeated runs, missing directory and simulated xattr failure; temporary files were removed. The default data directory does not exist on this host.
- **Risks:** The 10 GiB free-space floor only covers the planned test file; capacity and the dev memory limit require validation for actual workloads. The target data filesystem has not been checked.
- **Rollback:** Remove the preflight and its check and revert the related documentation changes.

## 2026-11-16 — Initial repository skeleton

- **Context:** Roadmap task 1.1 establishes the Phase 1 repository structure.
- **Change:** Added configuration files, reserved directories, README and the confirmed OpenCloud 7.2.5 image reference; aligned the roadmap, AI context and changelog index.
- **Verification:** Image variables and disallowed tags checked; AI context is 56 lines; YAML config parsed with PyYAML; ShellCheck accepts its configuration. `yamllint` and Git repository checks unavailable in this environment.
- **Risks:** Local Compose, deployment and runtime behavior remain unimplemented and unverified.
- **Rollback:** Remove the new skeleton files and revert the associated documentation updates.

## 2026-11-16 — Example

- **Context:** 
- **Change:**
- **Verification:**
- **Risks:** 
- **Rollback:** 
