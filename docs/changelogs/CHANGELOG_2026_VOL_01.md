# CHANGELOG 2026 VOL 01

## 2026-11-17 — Prepare isolated Entra role mapping

- **Context:** The user reported successful isolated autoprovisioning after adding the `email` access-token claim; task 2.2 tests staff and administrator roles.
- **Change:** Prepared OIDC role assignment and disabled default Graph role assignment in the isolated Compose override; added an isolated internal-IdP override for account administration and documented the reported result.
- **Verification:** OpenCloud 7.2.5 source maps `opencloudAdmin` to admin and `opencloudUser` to user. Compose rendering is checked; actual role assignment, token claims and denial cases remain pending.
- **Risks:** The override has not been deployed. Autoprovisioning can change group memberships; audience validation and UPN risks remain. Isolated accounts have not been removed.
- **Rollback:** Remove the three role-related environment entries from the isolated override and recreate only the isolated service.

## 2026-11-16 — Isolated Entra autoprovisioning diagnosis

- **Context:** A new Entra user could not complete login in the isolated autoprovisioning PoC.
- **Change:** Recorded diagnostic findings; no runtime configuration or user state was changed.
- **Verification:** OpenCloud logged HTTP 400 while updating a user through LibreGraph. The received access-token claims contained `upn` and `name`, but no nonempty `email`; matching UPN and display-name bytes were found in the isolated IDM data. Values and tokens were not printed.
- **Risks:** Missing `email` is a hypothesis for the rejected update; the Graph response does not establish its cause. The copied state may already contain a partially created account.
- **Rollback:** Remove this diagnostic entry if no longer needed.

## 2026-11-16 — Isolated Entra autoprovisioning PoC preparation

- **Context:** Task 2.1 requires testing a new Entra user without manual provisioning.
- **Change:** Added an opt-in Compose override and instructions using an isolated copy with UPN as the provisioned username.
- **Verification:** Rendered Compose configuration confirms separate data/config mounts, loopback port 19200 and the intended provisioning settings. A real new-account login and repeat-login acceptance are pending.
- **Risks:** OpenCloud 7.2.5 autoprovisioning can change existing group memberships; UPN is mutable and access-token audience is not enforced. Use only an isolated copy.
- **Rollback:** Stop the separate PoC project; the manual-user service and original state are unaffected by the override.

## 2026-11-16 — Manual Entra account PoC confirmed

- **Context:** Local Entra PoC uses a manually created OpenCloud account and UPN matching.
- **Change:** Recorded the user's successful account mapping and file access in AI context.
- **Verification:** The user confirmed the mapped account, file access and repeat login work.
- **Risks:** Automatic provisioning and audience enforcement remain unverified; mutable UPN remains a security risk. The PoC is loopback-only.
- **Rollback:** Revert the AI context update.

## 2026-11-16 — Local Microsoft sign-in reported

- **Context:** Follow-up to the local Entra CSP change.
- **Change:** Recorded the user's reported successful Microsoft sign-in in AI context.
- **Verification:** The local container is running and the login page returned HTTP 200; the user reported successful sign-in through Microsoft 365.
- **Risks:** OpenCloud account mapping, file access and token audience enforcement are not yet validated; the PoC remains loopback-only.
- **Rollback:** Revert the AI context update.

## 2026-11-16 — Allow Entra discovery in local PoC CSP

- **Context:** The Entra PoC login page could not fetch the provider's discovery document.
- **Change:** Added a local Compose CSP extension allowing connections to `https://login.microsoftonline.com` while retaining the default directives.
- **Verification:** Entra discovery returned HTTP 200 with CORS allowed. A separate network-isolated OpenCloud 7.2.5 container emitted the expected CSP with the Entra origin and existing default restrictions.
- **Risks:** Browser login and token validation remain unverified; the original container must be recreated to apply the change.
- **Rollback:** Remove the CSP bind mount and `PROXY_CSP_CONFIG_FILE_LOCATION` from the local Entra override.

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
