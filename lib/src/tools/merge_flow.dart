// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_merge/gg_merge.dart' as gg_merge;
import 'package:gg_one_merge/src/tools/lock_files.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart' as gg_publish;
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:path/path.dart' as p;

/// Performs the merge operation.
///
/// This is a plain tool, not a CLI command: `gg do merge` was folded into
/// `gg do publish --merge-only`, which runs the whole publish flow without
/// any release artifact. What is left is the merge *implementation*
/// `DoPublish` drives (the merge step itself and [removeTicketJson]), so both
/// a real publish and a merge-only run go through exactly one code path.
class MergeFlow {
  /// Constructor
  MergeFlow({
    required this.ggLog,
    GgState? state,
    gg_merge.DoMerge? doMerge,
    gg_merge.WaitForMerge? waitForMerge,
    gg_merge.CanMerge? canMerge,
    gg_publish.MainBranch? mainBranch,
    GgSystemCommit? systemCommit,
    this._processWrapper = const GgProcessWrapper(),
  }) : _state = state ?? GgState(ggLog: ggLog),
       _doMerge = doMerge ?? gg_merge.DoMerge(ggLog: ggLog),
       _waitForMerge = waitForMerge ?? gg_merge.WaitForMerge(ggLog: ggLog),
       _canMerge = canMerge ?? gg_merge.CanMerge(ggLog: ggLog),
       _mainBranch = mainBranch ?? gg_publish.MainBranch(ggLog: ggLog),
       _systemCommit = systemCommit ?? GgSystemCommit(ggLog: ggLog);

  /// The log function
  final GgLog ggLog;

  final GgState _state;
  final gg_merge.DoMerge _doMerge;
  final gg_merge.WaitForMerge _waitForMerge;
  final gg_merge.CanMerge _canMerge;
  final gg_publish.MainBranch _mainBranch;
  final GgSystemCommit _systemCommit;
  final GgProcessWrapper _processWrapper;

  /// Merges the current feature branch into the default branch — locally or
  /// through an auto-complete pull request ([viaPullRequest]).
  ///
  /// The default branch is NEVER checked out, in neither flow: a checkout of
  /// its old state makes editor tooling (e.g. the Dart extension of VS Code)
  /// descend on the suddenly-changed worktree and rewrite lock files in the
  /// middle of the release. The local flow builds the squash commit with git
  /// plumbing on the feature branch and moves the default-branch ref onto
  /// it; the pull-request flow lets the provider merge and fast-forwards the
  /// local ref afterwards. HEAD stays on the feature branch throughout.
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? automerge,
    bool? local,
    String? message,
    bool? verbose,
    bool? viaPullRequest,
    bool? deleteSourceBranch,
  }) async {
    automerge ??= false;
    local ??= false;
    verbose ??= false;
    viaPullRequest ??= false;
    deleteSourceBranch ??= true;

    // The publish step runs build/test (incl. formatters like
    // »prettier --write«) after the last commit, and gg writes run state into
    // the tracked ».gg/gg.json«. Commit those leftovers first, so the squash
    // tree below contains them and the later push finds a clean state.
    await _commitPendingChanges(
      directory: directory,
      ggLog: ggLog,
      verbose: verbose,
    );

    // Drop the ticket marker (written by `gg do add`) so it never lands on
    // the main branch.
    await removeTicketJson(
      directory: directory,
      ggLog: ggLog,
      verbose: verbose,
    );

    if (viaPullRequest) {
      // Protected branches (e.g. Azure DevOps) reject a direct push to main;
      // merge through an auto-complete pull request and wait for it instead.
      await _mergeViaPullRequest(
        directory: directory,
        ggLog: ggLog,
        verbose: verbose,
        deleteSourceBranch: deleteSourceBranch,
        message: message,
      );
    } else {
      await _mergeLocallyWithoutCheckout(
        directory: directory,
        ggLog: ggLog,
        message: message,
        verbose: verbose,
      );
    }

    // A merge produces a fully-committed, gg-verified HEAD, so it satisfies
    // »gg did commit«. Record that, otherwise every later »gg did commit« —
    // CI, and any repo-level hook that runs it — rejects the merge commit.
    await _recordReleaseState(directory, 'doCommit');
  }

  // ...........................................................................
  /// Merges the feature branch into the default branch without checking the
  /// default branch out.
  ///
  /// The squash commit is built on the feature branch with git plumbing:
  /// its tree is simply the feature branch's tree — which IS the merge
  /// result, because [gg_merge.CanMerge] refuses a branch that is behind
  /// main — parented on the default branch's tip (`git commit-tree`), and
  /// the default-branch ref is moved onto it (`git update-ref`). The
  /// worktree never changes, so no editor tooling ever sees the old default
  /// branch state.
  Future<void> _mergeLocallyWithoutCheckout({
    required Directory directory,
    required GgLog ggLog,
    required String? message,
    required bool verbose,
  }) async {
    final mainBranchName = await _mainBranch.get(
      directory: directory,
      ggLog: <String>[].add,
    );

    final currentBranch = (await _runGitCommand(
      directory: directory,
      arguments: const ['rev-parse', '--abbrev-ref', 'HEAD'],
      actionDescription: 'determine the current branch',
      ggLog: ggLog,
      verbose: verbose,
    )).trim();
    if (currentBranch == mainBranchName) {
      throw Exception('Already on $mainBranchName branch; nothing to merge.');
    }

    // The same gate the pull-request path runs inside gg_merge's DoMerge:
    // fetches, refuses localized manifest refs, refuses a branch that is
    // behind main — the precondition that makes the plumbing squash below
    // correct — and demands something to merge.
    final ok = await _canMerge.get(directory: directory, ggLog: ggLog);
    if (!ok) {
      throw Exception('Not allowed to merge.'); // coverage:ignore-line
    }

    // Bring the local default-branch ref up to date — without a checkout.
    // CanMerge's fetch already refreshed the remote-tracking refs.
    await _syncLocalMainRef(
      directory: directory,
      mainBranchName: mainBranchName,
      ggLog: ggLog,
      verbose: verbose,
      fetch: false,
    );

    final mainSha = _trimmedStdoutOrEmpty(
      await _tryGitCommand(
        directory: directory,
        arguments: [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/$mainBranchName',
        ],
        verbose: verbose,
        ggLog: ggLog,
      ),
    );
    if (mainSha.isEmpty) {
      throw Exception(
        cError('There is no $mainBranchName branch to merge into.'),
      );
    }

    // Belt and braces: the squash tree is the feature branch's tree, which
    // is the correct merge result only when $mainBranchName is fully
    // contained in it. CanMerge checked that against origin/$mainBranchName;
    // re-check against the local ref the squash is parented on.
    final mainIsContained = await _tryGitCommand(
      directory: directory,
      arguments: ['merge-base', '--is-ancestor', mainSha, 'HEAD'],
      verbose: verbose,
      ggLog: ggLog,
    );
    if (mainIsContained.exitCode != 0) {
      throw Exception(
        cError(
          '$mainBranchName contains commits the feature branch does not. '
          'Merge $mainBranchName into the feature branch first '
          '(e.g. via »gg do push«), then try again.',
        ),
      );
    }

    final tree = (await _runGitCommand(
      directory: directory,
      arguments: const ['rev-parse', 'HEAD:'],
      actionDescription: 'read the tree of the feature branch',
      ggLog: ggLog,
      verbose: verbose,
    )).trim();

    // No gg prefix here, even in the fallback: this commit lands on the
    // default branch, and a »#gg: « subject there would claim it is gg
    // bookkeeping — the default branch carries releases and tags only. The
    // multi-repo flow always supplies the user's merge message anyway.
    final commitMessage =
        message ?? 'Merged $currentBranch into $mainBranchName';
    final squashCommit = (await _runGitCommand(
      directory: directory,
      arguments: ['commit-tree', tree, '-p', mainSha, '-m', commitMessage],
      actionDescription: 'create the squash commit',
      ggLog: ggLog,
      verbose: verbose,
    )).trim();

    // Move the default-branch ref onto the squash commit. The old tip is
    // passed as the expected previous value, so a concurrent move of the
    // ref fails loudly instead of being overwritten.
    await _runGitCommand(
      directory: directory,
      arguments: [
        'update-ref',
        'refs/heads/$mainBranchName',
        squashCommit,
        mainSha,
      ],
      actionDescription: 'move $mainBranchName onto the squash commit',
      ggLog: ggLog,
      verbose: verbose,
    );

    ggLog(
      cDetail(
        '✓ Squash-merged $currentBranch into $mainBranchName — without '
        'checking $mainBranchName out.',
      ),
    );
  }

  // ...........................................................................
  /// Records [key] for the **committed** content of [directory].
  ///
  /// `ignoreUnstaged: true` is what makes the recorded hash reproducible after
  /// the release window closes. [GgState] hashes the working tree *including
  /// untracked files*, while [_commitPendingChanges] deliberately commits only
  /// tracked ones (`git add --update`) so no stray build output is swept into
  /// a release commit. An untracked file that exists for a moment — a
  /// generated artifact, a tool's scratch file, anything a build/test/publish
  /// script leaves behind — would therefore be hashed into the state without
  /// ever being committed, and every later »gg did commit« would fail with
  /// »Not committed yet« the instant that file is gone again.
  ///
  /// Hashing the committed content only is also what these call sites *mean*:
  /// they state something about the tree that is about to become the default
  /// branch, and untracked files are by definition not part of it. Real
  /// uncommitted work still fails the later check, which reads the full
  /// working tree.
  Future<void> _recordReleaseState(Directory directory, String key) =>
      _state.writeSuccess(directory: directory, key: key, ignoreUnstaged: true);

  /// Commits pending changes to tracked files on the current (feature) branch
  /// before the merge switches branches. During a release the publish step
  /// can leave tracked files dirty after the last commit — e.g. a
  /// `prettier --write` in the build→test chain reformats `pubspec.yaml`, or
  /// gg records run state in the tracked `.gg/gg.json` — which makes
  /// `git checkout <main>` abort with "local changes would be overwritten by
  /// checkout". These are post-check release artifacts, so committing them
  /// keeps the merge robust instead of failing mid-publish. Untracked files
  /// are deliberately excluded so stray build output is never swept in.
  ///
  /// Whatever is dirty here that gg does *not* own is the user's, and it gets
  /// its own commit without the gg prefix — a release artifact and a
  /// half-finished edit must not end up indistinguishable in one commit.
  /// Returns whether anything was committed.
  Future<bool> _commitPendingChanges({
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    // Always logging: when the split saves pending *user* changes into their
    // own commit, the user has to learn about it — verbose or not.
    final result = await _systemCommit.commit(
      directory: directory,
      ggLog: ggLog,
      message:
          '${ggCommitPrefix}Commit pending changes before merge '
          '(e.g. release formatting)',
      includeUntracked: false,
    );

    if (!result.systemCommitCreated && !result.userCommitCreated) {
      return false;
    }

    ggLog(
      cDetail(
        'Committed pending worktree changes before merge '
        '(e.g. formatter output or run state).',
      ),
    );
    return true;
  }

  /// Removes the `.gg/ticket.json` marker (force-added by `gg do add`) and
  /// commits the removal onto the current branch, so the marker never
  /// reaches the main branch. A no-op when the marker is absent.
  ///
  /// Public because `do publish` calls it too — right at the start, before
  /// the version bump: the marker must neither ride into the release
  /// commits the merge puts on the main branch nor ship to pub.dev/npm
  /// inside the package the registry upload publishes afterwards.
  ///
  /// The hidden `.gg/.ticket.json` of the days before the files inside `.gg`
  /// were unhidden is removed alongside it: a branch created back then still
  /// carries it, and it must not reach the main branch either.
  Future<void> removeTicketJson({
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    final markers = <File>[
      File(p.join(directory.path, '.gg', 'ticket.json')),
      File(p.join(directory.path, '.gg', '.ticket.json')),
    ].where((f) => f.existsSync()).toList();

    if (markers.isEmpty) {
      return;
    }

    await _runGitCommand(
      directory: directory,
      arguments: <String>[
        'rm',
        '-f',
        '--ignore-unmatch',
        ...markers.map((f) => '.gg/${p.basename(f.path)}'),
      ],
      actionDescription: 'remove .gg/ticket.json',
      ggLog: ggLog,
      verbose: verbose,
    );
    // `git rm` removes a tracked file; delete a still-present (untracked) copy
    // explicitly so the worktree is clean either way.
    for (final marker in markers) {
      if (marker.existsSync()) {
        marker.deleteSync();
      }
    }

    // The removal already sits in the index after »git rm«; the pathspec
    // keeps anything else that turned dirty meanwhile out of this commit.
    await _systemCommit.commit(
      directory: directory,
      ggLog: ggLog,
      message: '${ggCommitPrefix}Remove .gg/ticket.json',
      paths: markers.map((f) => '.gg/${p.basename(f.path)}').toList(),
    );
    ggLog(darkGray('Removed .gg/ticket.json.'));
  }

  /// Merges the feature branch through an auto-complete pull request and blocks
  /// until the provider merged it. Used for protected main branches (e.g. Azure
  /// DevOps `TF402455`) where a direct push to main is rejected. Afterwards the
  /// local main-branch REF is fast-forwarded to the merged state — without a
  /// checkout, so no editor tooling ever sees the old main state; the tag
  /// step checks main out only once it already carries the release.
  Future<void> _mergeViaPullRequest({
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
    required bool deleteSourceBranch,
    required String? message,
  }) async {
    // Refresh remote-tracking refs so the merge pre-conditions are accurate.
    await _runGitCommand(
      directory: directory,
      arguments: const ['fetch'],
      actionDescription: 'fetch the remote refs',
      ggLog: ggLog,
      verbose: verbose,
    );

    final mainBranchName = await _mainBranch.get(
      directory: directory,
      ggLog: <String>[].add,
    );

    // The source branch of the pull request. Captured before anything can
    // move HEAD, so the wait below never looks for a pull request of the
    // default branch.
    final sourceBranch = (await _runGitCommand(
      directory: directory,
      arguments: const ['rev-parse', '--abbrev-ref', 'HEAD'],
      actionDescription: 'determine the pull request source branch',
      ggLog: ggLog,
      verbose: verbose,
    )).trim();

    // A resumed run may find its release already on main: the previous run
    // crashed after the provider merged the pull request but before the
    // merge step was marked done. Detected by content (a squash merge
    // changes the commit SHAs), the pull request and the wait are skipped.
    final alreadyMerged = await _releaseAlreadyOnMain(
      directory: directory,
      mainBranchName: mainBranchName,
      ggLog: ggLog,
      verbose: verbose,
    );

    if (alreadyMerged) {
      ggLog(
        cDetail(
          'All release changes are already on $mainBranchName (the pull '
          'request of an earlier run was merged) — skipping the pull request.',
        ),
      );
    } else {
      // Push the feature branch (incl. version bump + changelog) so the pull
      // request contains everything before it is created.
      await _runGitCommand(
        directory: directory,
        arguments: const ['push'],
        actionDescription:
            'push feature branch before creating the pull request',
        ggLog: ggLog,
        verbose: verbose,
      );

      // A repo-level pre-push hook can dirty the worktree during the push —
      // e.g. a »dart run« based hook whose implicit »pub get« rewrites
      // pubspec.lock after the version bump. gg does not install such a hook,
      // but a repo may carry one of its own. Commit that drift and push again
      // (the second hook run finds everything up to date), otherwise the
      // checkout of the main branch below aborts with "local changes would be
      // overwritten by checkout".
      final hookDriftCommitted = await _commitPendingChanges(
        directory: directory,
        ggLog: ggLog,
        verbose: verbose,
      );
      if (hookDriftCommitted) {
        await _runGitCommand(
          directory: directory,
          arguments: const ['push'],
          actionDescription: 'push pre-push-hook drift commit',
          ggLog: ggLog,
          verbose: verbose,
        );
      }

      // Record »doCommit« and »doPush« for the content that is about to be
      // merged. A squash merge keeps the tree, and [GgState] hashes the tree
      // (ignoring `.gg/`), so the hashes written here are exactly the hashes
      // of the default branch afterwards. Without this, main carries the
      // hashes of an older feature-branch state and »gg did commit« /
      // »gg did push« fail on it — blocking CI and the next release. The
      // state must ride along inside the pull request:
      // main is merged by the provider, so gg cannot push a fix afterwards.
      await _writeReleaseState(
        directory: directory,
        ggLog: ggLog,
        verbose: verbose,
      );

      // Create the auto-complete pull request on the provider (GitHub/Azure).
      // The merge message becomes the PR title and squash commit message.
      await _doMerge.get(
        directory: directory,
        ggLog: ggLog,
        automerge: true,
        local: false,
        verbose: verbose,
        deleteSourceBranch: deleteSourceBranch,
        message: message,
      );

      // Block until the provider merged the pull request. The pull request
      // above carries auto-merge, so the wait reports its url instead of
      // asking the user to merge it by hand.
      await _waitForMerge.get(
        directory: directory,
        ggLog: ggLog,
        branch: sourceBranch,
        autoMerge: true,
      );
    }

    // Bring the local main REF to the merged state — without a checkout:
    // HEAD stays on the feature branch, so no editor tooling ever sees the
    // old main state in the worktree. The provider merged after the last
    // fetch, so fetch again first.
    await _syncLocalMainRef(
      directory: directory,
      mainBranchName: mainBranchName,
      ggLog: ggLog,
      verbose: verbose,
      fetch: true,
    );
  }

  /// Writes the `doCommit` and `doPush` success states for the current
  /// feature-branch content and pushes the resulting bookkeeping commit, so
  /// the pull request carries them into the default branch.
  ///
  /// [GgState] hashes the tracked tree and ignores `.gg/`, so recording the
  /// state neither changes the hash nor invalidates itself.
  Future<void> _writeReleaseState({
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    await _recordReleaseState(directory, 'doCommit');
    await _recordReleaseState(directory, 'doPush');

    // A no-op when the states were already up to date ("Everything
    // up-to-date"), so this never creates an empty extra round trip.
    await _runGitCommand(
      directory: directory,
      arguments: const ['push'],
      actionDescription: 'push the recorded release state',
      ggLog: ggLog,
      verbose: verbose,
    );
  }

  /// Brings the local main REF to `origin/<main>` without ever checking it
  /// out — `git branch -f` moves the ref while HEAD stays on the feature
  /// branch, so the worktree never shows the old main state.
  ///
  /// Robust against the divergence gg itself creates: after a merge, gg's
  /// state bookkeeping used to commit `.gg/gg.json` onto main, and in the
  /// pull-request flow main is never pushed. After a pull-request merge
  /// origin is the truth for main: when the local extra commits carry only
  /// gg bookkeeping or lock-file drift, main is force-moved to
  /// `origin/<main>`. Real local commits are never discarded — the sync
  /// fails with a clear message instead. A missing `origin/<main>` leaves
  /// the local ref alone (the local flow pushes it later); a missing local
  /// ref is created from origin.
  Future<void> _syncLocalMainRef({
    required Directory directory,
    required String mainBranchName,
    required GgLog ggLog,
    required bool verbose,
    required bool fetch,
  }) async {
    if (fetch) {
      await _runGitCommand(
        directory: directory,
        arguments: const ['fetch'],
        actionDescription: 'fetch the remote refs',
        ggLog: ggLog,
        verbose: verbose,
      );
    }

    final originSha = _trimmedStdoutOrEmpty(
      await _tryGitCommand(
        directory: directory,
        arguments: [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/remotes/origin/$mainBranchName',
        ],
        ggLog: ggLog,
        verbose: verbose,
      ),
    );
    if (originSha.isEmpty) {
      return;
    }

    final localSha = _trimmedStdoutOrEmpty(
      await _tryGitCommand(
        directory: directory,
        arguments: [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/$mainBranchName',
        ],
        ggLog: ggLog,
        verbose: verbose,
      ),
    );
    if (localSha == originSha) {
      return;
    }

    if (localSha.isNotEmpty) {
      final fastForwardable =
          (await _tryGitCommand(
            directory: directory,
            arguments: ['merge-base', '--is-ancestor', localSha, originSha],
            ggLog: ggLog,
            verbose: verbose,
          )).exitCode ==
          0;

      if (!fastForwardable) {
        final localOnlyFiles = await _runGitCommand(
          directory: directory,
          arguments: [
            'log',
            'origin/$mainBranchName..$mainBranchName',
            '--name-only',
            '--pretty=format:',
          ],
          actionDescription: 'list local-only commits on $mainBranchName',
          ggLog: ggLog,
          verbose: verbose,
        );

        final realFiles = localOnlyFiles
            .split('\n')
            .map((line) => line.trim())
            .where((file) => file.isNotEmpty)
            .where((file) => !file.startsWith('.gg/'))
            .where((file) => !isLockFile(file))
            .toSet();

        if (realFiles.isNotEmpty) {
          throw Exception(
            cError(
              'Local $mainBranchName and origin/$mainBranchName have '
              'diverged, and the local commits touch '
              '${realFiles.join(', ')}. '
              'Reconcile $mainBranchName manually (e.g. rebase it onto '
              'origin/$mainBranchName), then run the command again.',
            ),
          );
        }

        ggLog(
          cWarn(
            'Local $mainBranchName diverged from origin/$mainBranchName with '
            'gg bookkeeping only — resetting it to origin/$mainBranchName.',
          ),
        );
      }
    }

    await _runGitCommand(
      directory: directory,
      arguments: ['branch', '-f', mainBranchName, originSha],
      actionDescription: 'move $mainBranchName to origin/$mainBranchName',
      ggLog: ggLog,
      verbose: verbose,
    );
    ggLog(
      cDetail(
        '✓ Updated $mainBranchName to origin/$mainBranchName — without '
        'checking it out.',
      ),
    );
  }

  /// Returns whether the feature branch holds no release content that is
  /// missing on `origin/<main>`. True when the pull request of an earlier,
  /// interrupted run was already merged — a squash merge changes the commit
  /// SHAs, so this compares content, not ancestry. gg bookkeeping (`.gg/`)
  /// and lock-file drift are ignored: a real release always changes the
  /// version in the manifest, so it can never be mistaken for drift.
  Future<bool> _releaseAlreadyOnMain({
    required Directory directory,
    required String mainBranchName,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    final changedFiles = await _runGitCommand(
      directory: directory,
      arguments: ['diff', '--name-only', 'origin/$mainBranchName', 'HEAD'],
      actionDescription:
          'compare the feature branch with origin/$mainBranchName',
      ggLog: ggLog,
      verbose: verbose,
    );

    // Lock files rewritten by pre-push hooks and resumed runs are drift, not
    // release content; `isLockFile` owns the canonical set of names.
    return changedFiles
        .split('\n')
        .map((line) => line.trim())
        .where((file) => file.isNotEmpty)
        .where((file) => !file.startsWith('.gg/'))
        .where((file) => !isLockFile(file))
        .isEmpty;
  }

  /// Runs a git command and returns its result without throwing. Used for
  /// probes whose non-zero exit code is an answer, not an error —
  /// `rev-parse --verify` for a ref that may not exist,
  /// `merge-base --is-ancestor` for a containment question.
  Future<ProcessResult> _tryGitCommand({
    required Directory directory,
    required List<String> arguments,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    if (verbose) {
      ggLog('\$ git ${arguments.join(' ')}');
    }
    return _processWrapper.run(
      'git',
      arguments,
      runInShell: true,
      workingDirectory: directory.path,
    );
  }

  /// Runs a git command and throws when it fails. Returns stdout on success.
  Future<String> _runGitCommand({
    required Directory directory,
    required List<String> arguments,
    required String actionDescription,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    if (verbose) {
      ggLog('\$ git ${arguments.join(' ')}');
    }
    final result = await _processWrapper.run(
      'git',
      arguments,
      runInShell: true,
      workingDirectory: directory.path,
    );

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      final stdout = result.stdout.toString().trim();
      final details = stderr.isNotEmpty ? stderr : stdout;
      throw Exception(cError('Failed to $actionDescription: $details'));
    }
    return result.stdout.toString();
  }
}

/// Mock for [MergeFlow].
class MockMergeFlow extends mocktail.Mock implements MergeFlow {}

/// The trimmed stdout of [result] when the command succeeded, an empty
/// string when it failed — the probe pattern of `_tryGitCommand`.
///
/// A top-level function, not an extension on [ProcessResult]: inside an
/// extension the top-level `stdout`/`exitCode` getters of `dart:io` shadow
/// the members of the receiver.
String _trimmedStdoutOrEmpty(ProcessResult result) =>
    result.exitCode == 0 ? result.stdout.toString().trim() : '';
