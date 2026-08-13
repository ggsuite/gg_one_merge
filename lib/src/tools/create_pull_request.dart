// @license
// Copyright (c) ggsuite
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
  /// [directory] and returns its web url. [message] becomes the title of a
  /// newly created pull request and [body] its description (the title when
  /// no body is given); an existing pull request keeps the ones it has.
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
    String? body,
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
      body: body,
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
    if (id == null || repository is! Map) {
      return null;
    }

    final repositoryUrl = _azureRepositoryWebUrl(repository);
    if (repositoryUrl == null) {
      return null;
    }

    // `az` reports the repository, not the pull request page. The page is the
    // repository url plus the pull request id.
    return '$repositoryUrl/pullrequest/$id';
  }

  /// The web page of the [repository] `az repos pr list` describes —
  /// `https://dev.azure.com/<org>/<project>/_git/<repo>`.
  ///
  /// `az` does not report that url: `remoteUrl` is null on current versions
  /// and there is no `webUrl` at all. What it does report is the rest api url
  /// (`https://dev.azure.com/<org>/<projectId>/_apis/git/repositories/<id>`)
  /// together with the project and repository names — the pieces the web url
  /// is assembled from. `remoteUrl` is only the fallback: where `az` fills it,
  /// it is the clone url and carries the organization as user info
  /// (`https://<org>@dev.azure.com/…`), which is stripped here.
  String? _azureRepositoryWebUrl(Map<dynamic, dynamic> repository) {
    final project = repository['project'];
    final projectName = project is Map ? project['name']?.toString() : null;
    final repositoryName = repository['name']?.toString();
    final apiUrl = repository['url']?.toString();
    final organizationUrl = apiUrl == null
        ? null
        : _azureOrganizationUrl(apiUrl);

    if (projectName != null &&
        projectName.isNotEmpty &&
        repositoryName != null &&
        repositoryName.isNotEmpty &&
        organizationUrl != null) {
      // Project and repository names may contain spaces — Azure DevOps allows
      // them, so they must survive into the url encoded.
      return '$organizationUrl/${Uri.encodeComponent(projectName)}'
          '/_git/${Uri.encodeComponent(repositoryName)}';
    }

    return _withoutUserInfo(repository['remoteUrl']?.toString());
  }

  /// [url] without its user info part, or null when there is no [url]. Azure
  /// DevOps clone urls carry the organization as user info
  /// (`https://<org>@dev.azure.com/…`); the web url does not.
  String? _withoutUserInfo(String? url) {
    if (url == null || url.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.userInfo.isEmpty) {
      return url;
    }
    return uri.replace(userInfo: '').toString();
  }

  /// The organization part of an Azure DevOps rest api [apiUrl]:
  /// `https://dev.azure.com/<org>/<projectId>/_apis/…` becomes
  /// `https://dev.azure.com/<org>`. The legacy host form
  /// `https://<org>.visualstudio.com/<projectId>/_apis/…` becomes
  /// `https://<org>.visualstudio.com`, which is its equivalent.
  ///
  /// Returns null for urls that do not have this shape — the pull request url
  /// is then unknown rather than guessed.
  String? _azureOrganizationUrl(String apiUrl) {
    final uri = Uri.tryParse(apiUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }

    final segments = uri.pathSegments;
    final apiIndex = segments.indexOf('_apis');
    // The segment right before `_apis` is the project, everything before it
    // the organization. Without both the url is not the expected one.
    if (apiIndex < 1) {
      return null;
    }

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      pathSegments: segments.take(apiIndex - 1),
    ).toString();
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
