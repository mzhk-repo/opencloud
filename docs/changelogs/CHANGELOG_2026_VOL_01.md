# CHANGELOG 2026 VOL 01

## 2026-11-18 — Allow passwordless public read links

- **Context:** Public read-only links should be usable without a password.
- **Change:** Configured local Compose to allow passwordless public links while requiring passwords for writable links; recorded the same policy for the planned Swarm stack and its acceptance check.
- **Verification:** OpenCloud 7.2 documentation describes both settings; `docker compose --env-file .env.example config -q` and `git diff --check` passed. Browser behavior remains unverified.
- **Risks:** Anyone possessing a passwordless link can access its contents. Runtime behavior remains unverified.
- **Rollback:** Remove the two sharing environment entries and revert the related documentation changes.

## 2026-11-18 — Accept built-in OIDC group synchronization

- **Context:** The project owner chose the official OpenCloud image and reported upstream feature request opencloud-eu/opencloud#4058.
- **Change:** Documented the accepted JIT group synchronization behavior, observed membership removal, upstream request and remaining deployment gates in the specification, roadmap and AI context.
- **Verification:** The upstream issue was accessible and describes independently disabling group synchronization; user-reported isolated PoC results and existing source inspection underpin the documented behavior.
- **Risks:** Manually managed memberships can be removed; missing group claims, token audience, UPN stability and group overage remain relevant risks. The issue's proposed setting is not implemented in 7.2.5.
- **Rollback:** Revert the related specification, roadmap and AI context updates.

## 2026-11-18 — Manual group membership synchronization confirmed

- **Context:** Isolated PoC tests the effect of Entra group claims on locally managed OpenCloud groups.
- **Change:** Recorded the user's observed removal of a manually assigned group membership and the absent-claim behavior of OpenCloud 7.2.5.
- **Verification:** The user confirmed membership was removed after the next login. Source inspection shows an absent configured groups claim yields an empty desired set and synchronization removes existing memberships.
- **Risks:** Changing `PROXY_AUTOPROVISION_CLAIM_GROUPS` to a nonexistent claim does not disable synchronization; group memberships can be removed. Audience and mutable UPN risks remain.
- **Rollback:** Revert the AI context documentation update.

## 2026-11-18 — Isolated Entra group authorization tested

- **Context:** Test group claims with Entra app-role assignment requirements disabled on the isolated PoC.
- **Change:** Recorded the user's observed role mapping, denied-user provisioning and internal groups in AI context.
- **Verification:** The user reports admin and staff received their expected roles, a user outside both groups was denied but appeared without a role, and 13 internal groups included the two Entra GUIDs. Running container configuration confirms OIDC role mapping from `groups` with autoprovisioning enabled.
- **Risks:** Code inspection shows provisioning and group synchronization occur before role assignment, and synchronization can remove memberships. Live removal behavior, group overage and audience validation remain untested.
- **Rollback:** Revert the AI context documentation update; PoC state is unchanged by this entry.

## 2026-11-18 — Isolated Entra group-claim PoC preparation

- **Context:** The user requested group IDs for administrator and staff role mapping and disabled Entra assignment requirements and app roles for the test.
- **Change:** Added an isolated Compose override and a role-mapping template; the user-specific mapping remains outside Git. After the user confirmed test-user cleanup, enabled the override only on the isolated service.
- **Verification:** Compose rendering and GUID mapping validated; isolated service runs with read-only mapping and returned HTTP 200, with no startup errors observed. Actual authorization and negative scenarios require browser tests.
- **Risks:** Autoprovisioning can create and remove group memberships. Token audience and UPN risks remain; the Entra changes apply to every instance using the application registration.
- **Rollback:** Recreate the isolated project without the group override and restore the app's role and assignment settings in Entra if returning to the previous scenario.

## 2026-11-18 — Prepare isolated group-claim investigation

- **Context:** The user requested internal login on the isolated PoC for test-user cleanup before testing Entra Security groups.
- **Change:** Recreated only the isolated Compose service with its internal IdP; the original instance remained stopped.
- **Verification:** The isolated service uses its separate data directory, returned HTTP 200 and advertised `https://localhost:19200` as its issuer.
- **Risks:** Users have not been removed; group claims, autoprovisioning group synchronization, audience enforcement and overage handling remain untested.
- **Rollback:** Recreate the isolated project using the Entra and autoprovisioning Compose overrides after the planned account cleanup.

## 2026-11-18 — Isolated Entra role scenarios confirmed

- **Context:** Task 2.2 validates administrator, staff and student access on the isolated PoC.
- **Change:** Recorded the user's confirmed role scenarios in the roadmap and AI context.
- **Verification:** The user confirmed the administrator creates a Space and assigns a Manager, staff receive the user role, and a student cannot sign in.
- **Risks:** Bulk staff assignment, final access mode and break-glass validation remain pending; token audience, mutable UPN and group synchronization risks remain.
- **Rollback:** Revert the task 2.2 checklist and AI context updates.

## 2026-11-17 — Isolated role PoC tested

- **Context:** The user tested administrator, staff and student accounts on the isolated Entra PoC.
- **Change:** Recorded the reported sign-in results and remaining student-denial confirmation in AI context.
- **Verification:** The user reports the tests work; Docker inspection confirms OIDC role assignment, `roles` claim, autoprovisioning and disabled default Graph role assignment in the running isolated service.
- **Risks:** Explicit confirmation of student denial and role permissions is pending; autoprovisioning group synchronization, token audience and mutable UPN remain risks.
- **Rollback:** Revert the AI context update.

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
