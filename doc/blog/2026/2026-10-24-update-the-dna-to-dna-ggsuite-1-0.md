<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Update the DNA to dna_ggsuite 1.0

## Motivation

- gg_one_merge holds the merge flow: merging feature branches via pull
  requests or local merges. Its guides, skills and the managed block of
  `CLAUDE.md` are generated from the dna_ggsuite DNA
- With dna_ggsuite 0.5 they had no `/gg-review` skill, wrote the blog posts
  only at publish time and asked for a package prefix on every type
- This change is small: it brings the generated files to dna_ggsuite 1.0
  and leaves the code of gg_one_merge untouched

## Strategy

- Raise the dev dependency `dna_ggsuite` from ^0.5.0 to ^1.0.0
- Let helix regenerate the DNA files, committed as `#gg: generated DNA`
- Change nothing in `lib/` and `test/`

## Implementation 1: Ticket workflow

- New skill `/gg-review`: checks the diff of every repo against its scope,
  writes the blog posts, updates README.md and `index.jsonc`, then opens
  the pull requests and runs `/review-light`
- The blog posts move from the publish to the review phase; `/gg` and the
  `CLAUDE.md` block list `/gg-review`, `/gg-publish` checks for the post
- `/gg-commit` proposes one message per repo, in the repo's own terms;
  repos that depend on each other are committed one by one
- `ai-dev-guide.md` and `/gg-ticket` gain: keep every repo in its scope,
  keep the `index.jsonc` up to date, describe every repo in its own terms,
  and engineer the requirements before the plan
- `/gg-ticket` reads the `index.jsonc` of the candidate repos, no longer an
  `index.md`

## Implementation 2: Code guides and prompts

- The code guide no longer asks for the package prefix on types and file
  names; the examples of code and test guide read `User`, not `GgUser`
- New hooks in `.claude/settings.json` keep the prompts, never the
  answers, in the project management repo, with tokens redacted; the
  develop and install guides explain them

## Dependency updates

- `dna_ggsuite` 1.0.0 brings `dna_gg` 1.0.0 (workflow skills, AI guide,
  hooks) and `dna_clean_code` 0.2.2 (code and test guides)
- No runtime dependency constraint changed

## Open Points

- `.claude/hooks/pm-prompts.json` names no project management repo yet, so
  the hooks keep no prompts; they need Node.js to run at all
- The repo has no `index.jsonc` yet, although the new guides ask for one
- `pubspec_overrides.yaml` points the dependencies at the sibling
  checkouts while the ticket is open; it goes when the references return
  to pub.dev
