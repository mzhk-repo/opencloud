# CHANGELOG 2026 VOL 01

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
