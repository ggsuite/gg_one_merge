// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
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
    gg_publish.MainBranch? mainBranch,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _state = state ?? GgState(ggLog: ggLog),
       _doMerge = doMerge ?? gg_merge.DoMerge(ggLog: ggLog),
       _waitForMerge = waitForMerge ?? gg_merge.WaitForMerge(ggLog: ggLog),
       _mainBranch = mainBranch ?? gg_publish.MainBranch(ggLog: ggLog),
       _processWrapper = processWrapper;

  /// The log function
  final GgLog ggLog;

  final GgState _state;
  final gg_merge.DoMerge _doMerge;
  final gg_merge.WaitForMerge _waitForMerge;
  final gg_publish.MainBranch _mainBranch;
  final GgProcessWrapper _processWrapper;

  /// Merges the current feature branch into the default branch — locally or
  /// through an auto-complete pull request ([viaPullRequest]).
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
    // the tracked ».gg/gg.json«. Commit those leftovers first, otherwise the
    // upcoming »git checkout <main>« aborts with "local changes would be
    // overwritten by checkout" and the release fails halfway through.
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
      // Update local main branch via fetch + pull
      await _fetchAndPullMain(
        directory: directory,
        ggLog: ggLog,
        verbose: verbose,
      );

      // Perform merge using gg_merge
      await _doMerge.get(
        directory: directory,
        ggLog: ggLog,
        automerge: automerge,
        local: local,
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
  /// are deliberately excluded (`--untracked-files=no` / `git add --update`)
  /// so stray build output is never swept into the commit. Returns whether a
  /// commit was created.
  Future<bool> _commitPendingChanges({
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    final status = await _runGitCommand(
      directory: directory,
      arguments: const ['status', '--porcelain', '--untracked-files=no'],
      actionDescription: 'check for pending changes before merge',
      ggLog: ggLog,
      verbose: verbose,
    );

    if (status.trim().isEmpty) {
      return false;
    }

    await _runGitCommand(
      directory: directory,
      arguments: const ['add', '--update'],
      actionDescription: 'stage pending changes before merge',
      ggLog: ggLog,
      verbose: verbose,
    );

    await _runGitCommand(
      directory: directory,
      arguments: const [
        'commit',
        '-m',
        '#gg: Commit pending changes before merge (e.g. release formatting)',
      ],
      actionDescription: 'commit pending changes before merge',
      ggLog: ggLog,
      verbose: verbose,
    );

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

    await _runGitCommand(
      directory: directory,
      arguments: const ['commit', '-m', '#gg: Remove .gg/ticket.json'],
      actionDescription: 'commit removal of .gg/ticket.json',
      ggLog: ggLog,
      verbose: verbose,
    );
    ggLog(darkGray('Removed .gg/ticket.json.'));
  }

  /// Merges the feature branch through an auto-complete pull request and blocks
  /// until the provider merged it. Used for protected main branches (e.g. Azure
  /// DevOps `TF402455`) where a direct push to main is rejected. Afterwards the
  /// local main branch is updated to the merged state so a version tag can be
  /// placed on it.
  Future<void> _mergeViaPullRequest({
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
    required bool deleteSourceBranch,
    required String? message,
  }) async {
    // Refresh remote-tracking refs so the merge pre-conditions are accurate.
    await _fetchAndPullMain(
      directory: directory,
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

      // Block until the provider merged the pull request.
      await _waitForMerge.get(
        directory: directory,
        ggLog: ggLog,
        branch: sourceBranch,
      );
    }

    // Safety net: absorb any dirt that appeared since the pushes (the branch
    // is merged already, so a throwaway commit stays local) — the checkout of
    // the main branch below must not fail on a dirty worktree.
    await _commitPendingChanges(
      directory: directory,
      ggLog: ggLog,
      verbose: verbose,
    );

    // Bring local main to the merged state so the version tag lands on it.
    await _runGitCommand(
      directory: directory,
      arguments: ['checkout', mainBranchName],
      actionDescription: 'checkout $mainBranchName',
      ggLog: ggLog,
      verbose: verbose,
    );
    await _pullMainSafely(
      directory: directory,
      mainBranchName: mainBranchName,
      ggLog: ggLog,
      verbose: verbose,
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

  /// Fast-forwards the local main branch to `origin/<main>` — robust against
  /// the divergence gg itself creates: after a merge, gg's state bookkeeping
  /// commits `.gg/gg.json` onto main, and in the pull-request flow main is
  /// never pushed. The next release then finds main and `origin/<main>`
  /// diverged, and a plain »git pull« aborts with "You have divergent
  /// branches". After a pull-request merge origin is the truth for main:
  /// when the local extra commits carry only gg bookkeeping or lock-file
  /// drift, main is hard-reset to `origin/<main>`. Real local commits are
  /// never discarded — the sync fails with a clear message instead.
  Future<void> _pullMainSafely({
    required Directory directory,
    required String mainBranchName,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    try {
      await _runGitCommand(
        directory: directory,
        arguments: const ['pull', '--ff-only'],
        actionDescription: 'pull on $mainBranchName',
        ggLog: ggLog,
        verbose: verbose,
      );
      return;
    } on Exception {
      // Not fast-forwardable — decide below whether the local extra commits
      // may be dropped. The failed pull already fetched, so origin/<main>
      // is up to date.
    }

    final localOnlyFiles = await _runGitCommand(
      directory: directory,
      arguments: [
        'log',
        'origin/$mainBranchName..HEAD',
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
          'Local $mainBranchName and origin/$mainBranchName have diverged, '
          'and the local commits touch ${realFiles.join(', ')}. '
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
    await _runGitCommand(
      directory: directory,
      arguments: ['reset', '--hard', 'origin/$mainBranchName'],
      actionDescription: 'reset $mainBranchName to origin/$mainBranchName',
      ggLog: ggLog,
      verbose: verbose,
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

  /// Fetches and pulls the main branch before performing the merge.
  Future<void> _fetchAndPullMain({
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
  }) async {
    final mainBranchName = await _mainBranch.get(
      directory: directory,
      ggLog: <String>[].add,
    );

    final currentBranch = await _runGitCommand(
      directory: directory,
      arguments: const ['rev-parse', '--abbrev-ref', 'HEAD'],
      actionDescription: 'determine the current branch',
      ggLog: ggLog,
      verbose: verbose,
    );
    final originalBranch = currentBranch.trim();
    final switchBranches = originalBranch != mainBranchName;

    if (switchBranches) {
      await _runGitCommand(
        directory: directory,
        arguments: ['checkout', mainBranchName],
        actionDescription: 'checkout $mainBranchName',
        ggLog: ggLog,
        verbose: verbose,
      );
    }

    try {
      await _runGitCommand(
        directory: directory,
        arguments: const ['fetch'],
        actionDescription: 'fetch on $mainBranchName',
        ggLog: ggLog,
        verbose: verbose,
      );
      await _pullMainSafely(
        directory: directory,
        mainBranchName: mainBranchName,
        ggLog: ggLog,
        verbose: verbose,
      );
    } finally {
      if (switchBranches) {
        await _runGitCommand(
          directory: directory,
          arguments: ['checkout', originalBranch],
          actionDescription: 'checkout $originalBranch',
          ggLog: ggLog,
          verbose: verbose,
        );
      }
    }
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
