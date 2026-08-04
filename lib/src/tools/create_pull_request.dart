// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_merge/gg_merge.dart' as gg_merge;
import 'package:gg_process/gg_process.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

/// Opens the pull request of the current feature branch and returns its url.
///
/// The pull request is created **without** auto-merge: `gg do review` opens it
/// so the work becomes reviewable while the ticket is still being worked on,
/// and only `gg do publish` adds the auto-merge flag (see [MergeFlow]) — a
/// pull request that auto-merges while the ticket is under review would put
/// unreleased work on the main branch.
///
/// Creating is idempotent: an already open pull request of the branch is
/// reused, so every `gg do review` run ends up with exactly one.
class CreatePullRequest {
  /// Constructor
  CreatePullRequest({
    required this.ggLog,
    gg_merge.MergeGit? mergeGit,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _mergeGit = mergeGit ?? gg_merge.MergeGit(ggLog: ggLog),
       _processWrapper = processWrapper;

  /// The log function
  final GgLog ggLog;

  final gg_merge.MergeGit _mergeGit;
  final GgProcessWrapper _processWrapper;

  /// Opens — or reuses — the pull request of the branch checked out in
  /// [directory] and returns its web url. [message] becomes title and body of
  /// a newly created pull request; an existing one keeps the ones it has.
  ///
  /// Returns null when `origin` is neither GitHub nor Azure DevOps: those are
  /// the providers gg can open a pull request on. That is no error — the
  /// reason is logged and the caller carries on.
  ///
  /// Throws when the pull request could not be created, or when it was
  /// created but its url could not be read afterwards.
  Future<String?> get({
    required Directory directory,
    required GgLog ggLog,
    String? message,
  }) async {
    final remoteUrl = await gg_merge.readOriginUrl(
      directory: directory,
      processWrapper: _processWrapper,
    );
    final provider = remoteUrl == null
        ? null
        : gg_merge.providerFromRemoteUrl(remoteUrl);

    if (provider == null) {
      ggLog(
        cWarn(
          'No pull request: »origin« is neither a GitHub nor an Azure DevOps '
          'repository${remoteUrl == null ? '' : ' ($remoteUrl)'}.',
        ),
      );
      return null;
    }

    final branch = await _currentBranch(directory);

    // An open pull request of the branch is the result — nothing to create.
    // Only OPEN ones count: a merged pull request of a reused ticket branch
    // would hand back a url that says »merged« for work that is not.
    final existing = await _pullRequestUrl(
      directory: directory,
      provider: provider,
      branch: branch,
    );
    if (existing != null) {
      return existing;
    }

    await _mergeGit.get(
      directory: directory,
      ggLog: ggLog,
      // Never auto-merge here: this pull request is opened for the review.
      automerge: false,
      message: message,
    );

    final url = await _pullRequestUrl(
      directory: directory,
      provider: provider,
      branch: branch,
    );
    if (url == null) {
      throw Exception(
        cError(
          'The pull request for »$branch« was created, but its url could not '
          'be read.',
        ),
      );
    }
    return url;
  }

  /// The branch the pull request is created from.
  Future<String> _currentBranch(Directory directory) async {
    final result = await _processWrapper.run(
      'git',
      ['rev-parse', '--abbrev-ref', 'HEAD'],
      runInShell: true,
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      throw Exception(
        cError(
          'Failed to determine the pull request source branch: '
          '${result.stderr}',
        ),
      );
    }
    return result.stdout.toString().trim();
  }

  /// The web url of the open pull request of [branch], or null when there is
  /// none.
  Future<String?> _pullRequestUrl({
    required Directory directory,
    required gg_merge.GitProvider provider,
    required String branch,
  }) => switch (provider) {
    gg_merge.GitProvider.github => _gitHubPullRequestUrl(directory, branch),
    gg_merge.GitProvider.azure => _azurePullRequestUrl(directory, branch),
  };

  /// Asks `gh` for the open pull request of [branch].
  Future<String?> _gitHubPullRequestUrl(
    Directory directory,
    String branch,
  ) async {
    final result = await _processWrapper.run(
      'gh',
      [
        'pr',
        'list',
        '--head',
        branch,
        '--state',
        'open',
        '--json',
        'url',
        '--limit',
        '1',
      ],
      runInShell: true,
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      return null;
    }

    final url = _firstEntry(result.stdout.toString())?['url']?.toString();
    return (url == null || url.isEmpty) ? null : url;
  }

  /// Asks `az` for the active pull request of [branch].
  Future<String?> _azurePullRequestUrl(
    Directory directory,
    String branch,
  ) async {
    final result = await _processWrapper.run(
      'az',
      [
        'repos',
        'pr',
        'list',
        '--source-branch',
        'refs/heads/$branch',
        '--status',
        'active',
        '--output',
        'json',
      ],
      runInShell: true,
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      return null;
    }

    final pullRequest = _firstEntry(result.stdout.toString());
    final id = pullRequest?['pullRequestId'];
    final repository = pullRequest?['repository'];
    final webUrl = repository is Map ? repository['webUrl']?.toString() : null;
    if (id == null || webUrl == null || webUrl.isEmpty) {
      return null;
    }

    // `az` reports the repository, not the pull request page. The page is the
    // repository url plus the pull request id.
    return '$webUrl/pullrequest/$id';
  }

  /// The first object of the json array `gh`/`az` print, or null when the
  /// output holds none — no pull request, or output that cannot be read. The
  /// latter is not decided here: creating the pull request afterwards
  /// surfaces the actual problem with a precise error.
  Map<dynamic, dynamic>? _firstEntry(String stdout) {
    try {
      final decoded = jsonDecode(stdout.trim());
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        return decoded.first as Map;
      }
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Mock for [CreatePullRequest].
class MockCreatePullRequest extends mocktail.Mock
    implements CreatePullRequest {}
