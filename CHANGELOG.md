# Changelog

## Unreleased

### Changed

- Documentation: `removeTicketJson` is called by `do publish` right at the
start, before the version bump — the marker must neither ride into the
release commits the merge puts on the main branch nor ship inside the
package the registry upload publishes afterwards (the publish flow now
merges before it uploads).
- Merge in main before publishing

## 2.1.0 - 2026-08-09

### Changed

- Allow to publish hybrid packages

## 2.0.0 - 2026-08-08

## 1.0.2 - 2026-08-07

### Fixed

- Fix issue with azure URLs

## 1.0.1 - 2026-08-05

### Added

- Merge machinery of the gg_one tool family, extracted from gg_one: `MergeFlow`, `CreatePullRequest`, the lock-file helpers and `CanMerge`.
- Add the missing example to each new package

### Changed

- Split gg_one into gg_one_core, gg_one_commit, gg_one_merge and gg_one_do_publish
