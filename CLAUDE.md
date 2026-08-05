# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`gg_one_merge` holds the merge machinery of the gg_one tool family: `MergeFlow` (driven by `DoPublish`), `CreatePullRequest` (driven by gg_multi's `do review`), the lock-file helpers and `CanMerge`.

The package is part of the gg_one tool family (see the `gg_one` umbrella repo for the family overview). All commands extend `DirCommand<T>` from `gg_args`; the primary logic lives in `get()`, and `exec()` delegates to it. `ggLog` is constructor-injected everywhere for testability.

## Behavior notes

  - There is **no `do merge` command** — `gg do merge` was folded into `gg do publish --merge-only` (below), so there is exactly one flow. Its implementation lives on as the plain tool `MergeFlow` (`tools/merge_flow.dart`, formerly the `DoMerge` command): no `Command`/`DirCommand` base, no `argParser`, no CLI surface — every parameter arrives from `DoPublish`, which is its only caller. It drops the `.gg/ticket.json` / `.gg/.ticket.json` ticket marker before merging, so it never lands on the main branch. `do_publish` calls the same removal (`MergeFlow.removeTicketJson`) before the version bump and registry upload — the upload happens before the merge, so the merge-time removal alone would ship the marker to pub.dev/npm inside the published package. gg_multi no longer writes that marker into a repo at all (a ticket's `ticket.json` stays in the ticket folder and is never committed), so this removal now only scrubs branches that an older gg pushed.
  - `CreatePullRequest` (`tools/create_pull_request.dart`) opens the pull request of the current feature branch and returns its **url** — the piece `gg_merge`'s `MergeGit` does not hand back (it returns a bool and only logs). It delegates the creation to `MergeGit` with `automerge: false` and asks `gh pr list` / `az repos pr list` for the url (Azure: `<repository.webUrl>/pullrequest/<id>`); an already open pull request of the branch is reused, so it is idempotent and never duplicates. It returns `null` (with a logged reason, not an error) when `origin` is neither GitHub nor Azure DevOps, and throws when the creation fails or the url cannot be read afterwards. gg_multi's `do review` is its caller: a review-time pull request must **not** auto-merge — that flag is `do publish`'s (below), otherwise a ticket under review would land on main.

## Testing Conventions

- 100% code coverage is required. Exempt lines with `// coverage:ignore-line` or `// coverage:ignore-start` / `// coverage:ignore-end`.
- Each implementation file must have a corresponding `_test.dart` in the mirrored path under `test/`.
- Mock classes are defined at the bottom of the **same file** as the class they mock, using `mocktail` and extending `MockDirCommand<T>`.
- Tests use `gg_git_test_helpers` (including the cached repo helpers) and `gg_capture_print`.
