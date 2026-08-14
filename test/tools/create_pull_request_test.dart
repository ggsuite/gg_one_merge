// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_merge/gg_merge.dart' as gg_merge;
import 'package:gg_one_merge/gg_one_merge.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _FakeDirectory extends Fake implements Directory {}

class _MockMergeGit extends Mock implements gg_merge.MergeGit {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeDirectory());
  });

  late Directory d;
  final messages = <String>[];
  final ggLog = messages.add;
  late CreatePullRequest createPullRequest;
  late _MockMergeGit mockMergeGit;
  late MockGgProcessWrapper mockProcessWrapper;

  // ...........................................................................
  void stubOrigin(String? url) {
    when(
      () => mockProcessWrapper.run(
        'git',
        ['config', '--get', 'remote.origin.url'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer(
      (_) async => url == null
          ? ProcessResult(0, 1, '', 'no origin')
          : ProcessResult(0, 0, '$url\n', ''),
    );
  }

  // ...........................................................................
  void stubBranch(String branch, {int exitCode = 0}) {
    when(
      () => mockProcessWrapper.run(
        'git',
        ['rev-parse', '--abbrev-ref', 'HEAD'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer(
      (_) async => ProcessResult(
        0,
        exitCode,
        exitCode == 0 ? '$branch\n' : '',
        exitCode == 0 ? '' : 'not a git repository',
      ),
    );
  }

  // ...........................................................................
  /// Stubs `gh pr list` with [responses] — one per call, so a lookup before
  /// and after the creation can answer differently.
  void stubGitHubList(List<ProcessResult> responses, {String branch = '72'}) {
    var call = 0;
    when(
      () => mockProcessWrapper.run(
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
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer(
      (_) async => responses[call++ < responses.length ? call - 1 : 0],
    );
  }

  // ...........................................................................
  void stubAzureList(List<ProcessResult> responses, {String branch = '72'}) {
    var call = 0;
    when(
      () => mockProcessWrapper.run(
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
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer(
      (_) async => responses[call++ < responses.length ? call - 1 : 0],
    );
  }

  // ...........................................................................
  /// One pull request as `az repos pr list` prints it: the repository holds
  /// the rest api url plus the project and repository names, and no web url
  /// at all. `remoteUrl` is null, as it is on current `az` versions.
  String azurePr(
    int id, {
    String organization = 'o',
    String project = 'p',
    String repository = 'r',
  }) =>
      '[{"pullRequestId":$id,"repository":{'
      '"name":"$repository",'
      '"project":{"name":"$project"},'
      '"remoteUrl":null,'
      '"url":"https://dev.azure.com/$organization/902c4d10'
      '/_apis/git/repositories/e8321401"}}]';

  // ...........................................................................
  void stubMergeGit() {
    when(
      () => mockMergeGit.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
        automerge: any(named: 'automerge'),
        message: any(named: 'message'),
      ),
    ).thenAnswer((_) async => true);
  }

  setUp(() async {
    messages.clear();
    d = await Directory.systemTemp.createTemp();
    mockMergeGit = _MockMergeGit();
    mockProcessWrapper = MockGgProcessWrapper();
    createPullRequest = CreatePullRequest(
      ggLog: ggLog,
      mergeGit: mockMergeGit,
      processWrapper: mockProcessWrapper,
    );
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  group('CreatePullRequest', () {
    group('get(directory, ggLog, message)', () {
      group('returns null and logs why', () {
        test('when the repository has no »origin« remote', () async {
          stubOrigin(null);

          final url = await createPullRequest.get(directory: d, ggLog: ggLog);

          expect(url, isNull);
          expect(messages.last, contains('No pull request'));
          verifyNever(
            () => mockMergeGit.get(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
              automerge: any(named: 'automerge'),
              message: any(named: 'message'),
            ),
          );
        });

        test('when »origin« is neither GitHub nor Azure DevOps', () async {
          stubOrigin('git@gitlab.example.com:me/repo.git');

          final url = await createPullRequest.get(directory: d, ggLog: ggLog);

          expect(url, isNull);
          expect(messages.last, contains('gitlab.example.com'));
        });
      });

      group('with a GitHub repository', () {
        setUp(() {
          stubOrigin('git@github.com:ggsuite/gg_one.git');
          stubBranch('72');
          stubMergeGit();
        });

        test('reuses an open pull request without creating one', () async {
          stubGitHubList([
            ProcessResult(
              0,
              0,
              '[{"url":"https://github.com/x/y/pull/1"}]',
              '',
            ),
          ]);

          final url = await createPullRequest.get(directory: d, ggLog: ggLog);

          expect(url, 'https://github.com/x/y/pull/1');
          verifyNever(
            () => mockMergeGit.get(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
              automerge: any(named: 'automerge'),
              message: any(named: 'message'),
            ),
          );
        });

        test('creates the pull request without automerge', () async {
          stubGitHubList([
            ProcessResult(0, 0, '[]', ''),
            ProcessResult(
              0,
              0,
              '[{"url":"https://github.com/x/y/pull/2"}]',
              '',
            ),
          ]);

          final url = await createPullRequest.get(
            directory: d,
            ggLog: ggLog,
            message: 'My ticket',
          );

          expect(url, 'https://github.com/x/y/pull/2');
          verify(
            () => mockMergeGit.get(
              directory: d,
              ggLog: ggLog,
              automerge: false,
              message: 'My ticket',
            ),
          ).called(1);
        });

        test('throws when the url cannot be read after the creation', () async {
          stubGitHubList([ProcessResult(0, 0, '[]', '')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('was created, but its url could not be read'),
              ),
            ),
          );
        });

        test('ignores a failing »gh pr list«', () async {
          stubGitHubList([ProcessResult(0, 1, '', 'gh: not found')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
          verify(
            () => mockMergeGit.get(
              directory: d,
              ggLog: ggLog,
              automerge: false,
              message: null,
            ),
          ).called(1);
        });

        test('ignores unreadable »gh pr list« output', () async {
          stubGitHubList([ProcessResult(0, 0, 'not json', '')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores an empty url', () async {
          stubGitHubList([ProcessResult(0, 0, '[{"url":""}]', '')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores a json object instead of an array', () async {
          stubGitHubList([ProcessResult(0, 0, '{"url":"https://x"}', '')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores an array of non-objects', () async {
          stubGitHubList([ProcessResult(0, 0, '["nope"]', '')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('throws when the current branch cannot be determined', () async {
          stubBranch('72', exitCode: 128);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('Failed to determine the pull request source branch'),
              ),
            ),
          );
        });
      });

      group('with an Azure DevOps repository', () {
        setUp(() {
          stubOrigin('https://dev.azure.com/org/project/_git/repo');
          stubBranch('72');
          stubMergeGit();
        });

        test('builds the url from organization, project, repo, id', () async {
          stubAzureList([ProcessResult(0, 0, azurePr(42), '')]);

          final url = await createPullRequest.get(directory: d, ggLog: ggLog);

          expect(url, 'https://dev.azure.com/o/p/_git/r/pullrequest/42');
          verifyNever(
            () => mockMergeGit.get(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
              automerge: any(named: 'automerge'),
              message: any(named: 'message'),
            ),
          );
        });

        test('creates the pull request without automerge', () async {
          stubAzureList([
            ProcessResult(0, 0, '[]', ''),
            ProcessResult(0, 0, azurePr(43), ''),
          ]);

          final url = await createPullRequest.get(
            directory: d,
            ggLog: ggLog,
            message: 'My ticket',
          );

          expect(url, 'https://dev.azure.com/o/p/_git/r/pullrequest/43');
          verify(
            () => mockMergeGit.get(
              directory: d,
              ggLog: ggLog,
              automerge: false,
              message: 'My ticket',
            ),
          ).called(1);
        });

        test('ignores a failing »az repos pr list«', () async {
          stubAzureList([ProcessResult(0, 1, '', 'az: not found')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores a pull request without a repository url', () async {
          stubAzureList([ProcessResult(0, 0, '[{"pullRequestId":44}]', '')]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores a repository the web url cannot be built from', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              '[{"pullRequestId":45,"repository":{"name":"r"}}]',
              '',
            ),
          ]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores an entry without a pull request id', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              '[{"repository":{"name":"r","project":{"name":"p"},'
                  '"url":"https://dev.azure.com/o/x/_apis/git/repositories/y"}}]',
              '',
            ),
          ]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('falls back to »remoteUrl« without its user info', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              '[{"pullRequestId":46,"repository":'
                  '{"remoteUrl":"https://o@dev.azure.com/o/p/_git/r"}}]',
              '',
            ),
          ]);

          final url = await createPullRequest.get(directory: d, ggLog: ggLog);

          expect(url, 'https://dev.azure.com/o/p/_git/r/pullrequest/46');
        });

        test('keeps a »remoteUrl« that has no user info', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              '[{"pullRequestId":48,"repository":'
                  '{"remoteUrl":"https://dev.azure.com/o/p/_git/r"}}]',
              '',
            ),
          ]);

          final url = await createPullRequest.get(directory: d, ggLog: ggLog);

          expect(url, 'https://dev.azure.com/o/p/_git/r/pullrequest/48');
        });

        test('ignores a repository url that is not a rest api url', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              '[{"pullRequestId":49,"repository":{"name":"r",'
                  '"project":{"name":"p"},'
                  '"url":"https://dev.azure.com/o/p"}}]',
              '',
            ),
          ]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores a repository url without scheme and host', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              '[{"pullRequestId":50,"repository":{"name":"r",'
                  '"project":{"name":"p"},'
                  '"url":"o/_apis/git/repositories/x"}}]',
              '',
            ),
          ]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('ignores an unparsable repository url', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              '[{"pullRequestId":51,"repository":{"name":"r",'
                  '"project":{"name":"p"},'
                  r'"url":"https://dev.azure.com:port/o/_apis/x"}}]',
              '',
            ),
          ]);

          await expectLater(
            createPullRequest.get(directory: d, ggLog: ggLog),
            throwsA(isA<Exception>()),
          );
        });

        test('encodes project and repository names', () async {
          stubAzureList([
            ProcessResult(
              0,
              0,
              azurePr(47, project: 'my project', repository: 'my repo'),
              '',
            ),
          ]);

          final url = await createPullRequest.get(directory: d, ggLog: ggLog);

          expect(
            url,
            'https://dev.azure.com/o/my%20project/_git/my%20repo'
            '/pullrequest/47',
          );
        });
      });
    });

    test('uses real dependencies by default', () {
      expect(CreatePullRequest(ggLog: ggLog), isNotNull);
    });
  });

  test('MockCreatePullRequest', () {
    expect(MockCreatePullRequest(), isA<CreatePullRequest>());
  });
}
