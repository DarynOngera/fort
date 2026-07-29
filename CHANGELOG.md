# Changelog

## [0.1.1] - 2026-7-29

### Added

- `audited_transaction/4` — one Multi, one audit step, atomic.
- `log_best_effort/4` — post-transaction audit, no atomicity guarantee.
- Tier comparison table in docs: atomic vs best-effort vs standalone.

### Changed

- **Breaking:** Removed `new/0`. Use `Multi.new() |> wrap()` instead.
- `wrap/1` doc now documents greenfield entry.
- README/moduledoc: `audited_transaction/4` is primary example; three-call chain under "Advanced".
- Greenfield and Existing-Multi merged into one shape.

### Fixed

- Greenfield doc example: destructure-rebuild pattern caused `KeyError`.
- Dynamic attrs README example: `AuditedMulti` piped into `Multi.run/3`.

## [0.1.0] — 2026-07-28

### Added

- `wrap/1`, `append_to_multi/3`, `transact/4`, `log/1`, `from_changeset/1`, `reconcile/2`.
- `AuditedMulti` struct enforcing audit step presence.
- `MissingAuditStepError`.
- Automatic failure audit on business-step failure.
- Atomic commit of business + audit rows.
- Logger emission after commit with `emitted_at` stamp.
- Logger metadata two-tier structure (labels vs body).
- `mix fort.install` and `mix fort.reconcile`.

[Unreleased]: https://github.com/DarynOngera/fort_audit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/DarynOngera/fort_audit/releases/tag/v0.1.0
