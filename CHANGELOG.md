# Changelog

## 2.6.0 - 2026-09-02

### Changed

- Use ggwsm in pipelines
- Install the dna_ggsuite DNA

## 2.5.0 - 2026-08-14

### Changed

- Rework copyright headers

### Fixed

- Cleanup copy right headers. Update to dart 3.13. Auto fixes.
- Cleanup copy right headers. Update to dart 3.13. Auto fixes. Setup quick-check pipeline.

## 2.4.1 - 2026-08-11

### Changed

- Provide gg via npm
- Fix shell changes

## 2.4.0 - 2026-08-10

### Added

- `CreatePullRequest.get` takes a `body` — the pull-request description

## 2.3.2 - 2026-08-10

### Fixed

- Fix org-url repo add, code-workspace upkeep on rm and the auto-merge PR hint

## 2.3.1 - 2026-08-10

### Removed

- Merge .ticket with ticket.json. Remove usage of .ticket

## 2.3.0 - 2026-08-09

### Changed

- Improve commit behavior
- Move gg commit conventions from gg_git to gg_one_core

## 2.2.0 - 2026-08-09

### Changed

- **`MergeFlow` never checks a branch out anymore.** The local flow builds
the squash commit with git plumbing on the feature branch
(`git commit-tree` + `git update-ref`) — its tree IS the merge result,
because `CanMerge` refuses a branch that is behind main — and the
pull-request flow fast-forwards the local main REF (`git branch -f`) after
the provider merged. HEAD stays on the feature branch throughout, so editor
tooling (e.g. the Dart extension of VS Code) never sees the old main state
in the worktree and cannot rewrite lock files in the middle of a release.
The divergence handling of the former pull survives in the ref sync: gg
bookkeeping / lock-file drift is force-moved to origin with a warning, real
local commits still fail with instructions, a missing local main is created
from origin and a missing origin/main leaves the local ref alone.
- The local merge no longer goes through gg_merge's `DoMerge`/`LocalMerge`
(which check main out); the merge pre-conditions run through gg_merge's
`CanMerge` — the same gate the pull-request path uses.
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
