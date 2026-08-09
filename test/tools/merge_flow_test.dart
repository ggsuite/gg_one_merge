// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_merge/gg_merge.dart' as gg_merge;
import 'package:gg_one_merge/gg_one_merge.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart' as gg_publish;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:gg_one_core/gg_one_core.dart';

class _FakeDirectory extends Fake implements Directory {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeDirectory());
  });

  late Directory d;
  final messages = <String>[];
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late MergeFlow mergeFlow;
  late MockGgMergeDoMerge mockGgMergeDoMerge;
  late MockGgMergeWaitForMerge mockWaitForMerge;
  late MockGgState mockGgState;
  late MockMainBranch mockMainBranch;
  late MockGgProcessWrapper mockProcessWrapper;

  void stubGitCommands({
    String mainBranchName = 'main',
    String currentBranch = 'feature/x',
  }) {
    when(
      () => mockMainBranch.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async => mainBranchName);

    when(
      () => mockProcessWrapper.run(
        'git',
        ['rev-parse', '--abbrev-ref', 'HEAD'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '$currentBranch\n', ''));

    when(
      () => mockProcessWrapper.run(
        'git',
        ['checkout', mainBranchName],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

    when(
      () => mockProcessWrapper.run(
        'git',
        ['checkout', currentBranch],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

    when(
      () => mockProcessWrapper.run(
        'git',
        ['fetch'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

    when(
      () => mockProcessWrapper.run(
        'git',
        ['pull', '--ff-only'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

    // Clean worktree by default, so no pre-merge commit is created.
    when(
      () => mockProcessWrapper.run(
        'git',
        ['status', '--porcelain', '--untracked-files=no'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

    // A real release change by default, so the pull-request path runs.
    when(
      () => mockProcessWrapper.run(
        'git',
        ['diff', '--name-only', 'origin/$mainBranchName', 'HEAD'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer(
      (_) async => ProcessResult(0, 0, 'lib/src/changed.dart\n', ''),
    );
  }

  setUp(() async {
    messages.clear();
    d = await Directory.systemTemp.createTemp();
    await initCachedRepo(
      d,
      key: 'merge_flow_base',
      build: (repo) async {
        await initGit(repo);
        await addAndCommitSampleFile(repo);
      },
    );
    mockGgMergeDoMerge = MockGgMergeDoMerge();
    mockWaitForMerge = MockGgMergeWaitForMerge();
    mockGgState = MockGgState();
    mockMainBranch = MockMainBranch();
    mockProcessWrapper = MockGgProcessWrapper();
    mergeFlow = MergeFlow(
      ggLog: ggLog,
      doMerge: mockGgMergeDoMerge,
      waitForMerge: mockWaitForMerge,
      state: mockGgState,
      mainBranch: mockMainBranch,
      processWrapper: mockProcessWrapper,
    );

    // Default: any state write succeeds (doCommit).
    when(
      () => mockGgState.writeSuccess(
        directory: any(named: 'directory'),
        key: any(named: 'key'),
        ignoreUnstaged: any(named: 'ignoreUnstaged'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  group('MergeFlow', () {
    group('constructor', () {
      test('should initialize with defaults', () {
        final instance = MergeFlow(ggLog: ggLog);
        expect(instance.ggLog, ggLog);
      });

      test('should initialize with provided parameters', () {
        final instance = MergeFlow(
          ggLog: ggLog,
          state: mockGgState,
          doMerge: mockGgMergeDoMerge,
          mainBranch: mockMainBranch,
          processWrapper: mockProcessWrapper,
        );
        expect(instance.ggLog, ggLog);
      });
    });

    test('should fetch and pull main, then call gg_merge DoMerge', () async {
      stubGitCommands();

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: false,
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog);

      verifyInOrder([
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--abbrev-ref', 'HEAD'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['fetch'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['pull', '--ff-only'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'feature/x'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: false,
        ),
        () => mockGgState.writeSuccess(
          directory: d,
          key: 'doCommit',
          ignoreUnstaged: true,
        ),
      ]);
    });

    test('resets a diverged main when only gg bookkeeping differs', () async {
      stubGitCommands();

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: false,
        ),
      ).thenAnswer((_) async => true);

      // The fast-forward pull fails: main and origin/main have diverged.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['pull', '--ff-only'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer(
        (_) async => ProcessResult(1, 1, '', 'You have divergent branches ...'),
      );

      // The local-only commits touch gg bookkeeping and lock files only.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['log', 'origin/main..HEAD', '--name-only', '--pretty=format:'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer(
        (_) async => ProcessResult(0, 0, '.gg/gg.json\npubspec.lock\n', ''),
      );

      when(
        () => mockProcessWrapper.run(
          'git',
          ['reset', '--hard', 'origin/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await mergeFlow.get(directory: d, ggLog: ggLog);

      verify(
        () => mockProcessWrapper.run(
          'git',
          ['reset', '--hard', 'origin/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
      expect(messages.any((m) => m.contains('gg bookkeeping only')), isTrue);
    });

    test('throws when main diverged with real local commits', () async {
      stubGitCommands();

      when(
        () => mockProcessWrapper.run(
          'git',
          ['pull', '--ff-only'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer(
        (_) async => ProcessResult(1, 1, '', 'You have divergent branches ...'),
      );

      // The local-only commits touch real source files.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['log', 'origin/main..HEAD', '--name-only', '--pretty=format:'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'lib/src/foo.dart\n', ''));

      await expectLater(
        mergeFlow.get(directory: d, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(contains('have diverged'), contains('lib/src/foo.dart')),
          ),
        ),
      );

      // Real commits are never discarded.
      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['reset', '--hard', 'origin/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      );
    });

    test('commits pending worktree changes before merge', () async {
      stubGitCommands();

      // A formatter / gg run left tracked files dirty after the last commit.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['status', '--porcelain', '--untracked-files=no'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, ' M pubspec.yaml\n', ''));

      when(
        () => mockProcessWrapper.run(
          'git',
          ['add', '--update'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      when(
        () => mockProcessWrapper.run(
          'git',
          [
            'commit',
            '-m',
            '#gg: Commit pending changes before merge '
                '(e.g. release formatting)',
          ],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: false,
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog);

      // Staged and committed before the branch switch.
      verifyInOrder([
        () => mockProcessWrapper.run(
          'git',
          ['status', '--porcelain', '--untracked-files=no'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['add', '--update'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          [
            'commit',
            '-m',
            '#gg: Commit pending changes before merge '
                '(e.g. release formatting)',
          ],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ]);
      expect(
        messages,
        contains(
          'Committed pending worktree changes before merge '
          '(e.g. formatter output or run state).',
        ),
      );
    });

    test('should not checkout when already on main branch', () async {
      stubGitCommands(currentBranch: 'main');

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: false,
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog);

      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'main'],
          runInShell: any(named: 'runInShell'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['fetch'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['pull', '--ff-only'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
    });

    test('should restore branch when fetch fails', () async {
      stubGitCommands();

      when(
        () => mockProcessWrapper.run(
          'git',
          ['fetch'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', 'fetch failed'));

      await expectLater(
        mergeFlow.get(directory: d, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Failed to fetch on main: fetch failed'),
          ),
        ),
      );

      verify(
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'feature/x'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
      verifyNever(
        () => mockGgMergeDoMerge.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          automerge: any(named: 'automerge'),
          local: any(named: 'local'),
          verbose: any(named: 'verbose'),
        ),
      );
    });

    test('logs each git command when verbose is true', () async {
      stubGitCommands();

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: true,
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog, verbose: true);

      expect(
        messages,
        containsAll(<String>[
          '\$ git rev-parse --abbrev-ref HEAD',
          '\$ git checkout main',
          '\$ git fetch',
          '\$ git pull --ff-only',
          '\$ git checkout feature/x',
        ]),
      );
    });

    test('removes and commits the ticket marker before merge', () async {
      // The marker as force-added by do add.
      final ggDir = Directory('${d.path}/.gg')..createSync();
      final ticketJson = File('${ggDir.path}/ticket.json')
        ..writeAsStringSync('{"issue_id":"x"}');

      stubGitCommands();
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rm', '-f', '--ignore-unmatch', '.gg/ticket.json'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockProcessWrapper.run(
          'git',
          ['commit', '-m', '#gg: Remove .gg/ticket.json'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: false,
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog);

      // git rm is mocked, so the command deletes the leftover file itself.
      expect(ticketJson.existsSync(), isFalse);
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['rm', '-f', '--ignore-unmatch', '.gg/ticket.json'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['commit', '-m', '#gg: Remove .gg/ticket.json'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
      expect(messages, contains('Removed .gg/ticket.json.'));
    });

    test('removes the hidden ticket marker of an older branch too', () async {
      // A branch created before the files inside .gg were unhidden carries
      // `.gg/.ticket.json` - it must not reach main either.
      final ggDir = Directory('${d.path}/.gg')..createSync();
      final legacyTicketJson = File('${ggDir.path}/.ticket.json')
        ..writeAsStringSync('{"issue_id":"x"}');

      stubGitCommands();
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rm', '-f', '--ignore-unmatch', '.gg/.ticket.json'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockProcessWrapper.run(
          'git',
          ['commit', '-m', '#gg: Remove .gg/ticket.json'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: false,
          local: false,
          verbose: false,
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog);

      expect(legacyTicketJson.existsSync(), isFalse);
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['rm', '-f', '--ignore-unmatch', '.gg/.ticket.json'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
    });

    test('merges via a pull request and waits for it, then updates '
        'main', () async {
      stubGitCommands();

      // Feature-branch push before creating the pull request.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['push'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      // Remote PR creation (auto-complete).
      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: false,
          verbose: false,
          deleteSourceBranch: true,
        ),
      ).thenAnswer((_) async => true);

      // Wait until merged.
      when(
        () => mockWaitForMerge.get(
          directory: d,
          ggLog: ggLog,
          branch: any(named: 'branch'),
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog, viaPullRequest: true);

      verifyInOrder([
        // _fetchAndPullMain refreshes the remote-tracking refs.
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--abbrev-ref', 'HEAD'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['fetch'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['pull', '--ff-only'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'feature/x'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        // Push the feature branch, then create + wait for the PR.
        () => mockProcessWrapper.run(
          'git',
          ['push'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: false,
          verbose: false,
          deleteSourceBranch: true,
        ),
        () => mockWaitForMerge.get(
          directory: d,
          ggLog: ggLog,
          branch: any(named: 'branch'),
        ),
        // Bring local main to the merged state.
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['pull', '--ff-only'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockGgState.writeSuccess(
          directory: d,
          key: 'doCommit',
          ignoreUnstaged: true,
        ),
      ]);

      // The local merge path must not run in the pull-request flow.
      verifyNever(
        () => mockGgMergeDoMerge.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          automerge: any(named: 'automerge'),
          local: true,
          verbose: any(named: 'verbose'),
        ),
      );
    });

    test(
      'forwards deleteSourceBranch:false to the pull-request merge',
      () async {
        stubGitCommands();

        when(
          () => mockProcessWrapper.run(
            'git',
            ['push'],
            runInShell: true,
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

        when(
          () => mockGgMergeDoMerge.get(
            directory: d,
            ggLog: ggLog,
            automerge: true,
            local: false,
            verbose: false,
            deleteSourceBranch: false,
          ),
        ).thenAnswer((_) async => true);

        when(
          () => mockWaitForMerge.get(
            directory: d,
            ggLog: ggLog,
            branch: any(named: 'branch'),
          ),
        ).thenAnswer((_) async => true);

        when(
          () => mockGgState.writeSuccess(
            directory: d,
            key: any(named: 'key'),
            ignoreUnstaged: any(named: 'ignoreUnstaged'),
          ),
        ).thenAnswer((_) async {});

        await mergeFlow.get(
          directory: d,
          ggLog: ggLog,
          viaPullRequest: true,
          deleteSourceBranch: false,
        );

        verify(
          () => mockGgMergeDoMerge.get(
            directory: d,
            ggLog: ggLog,
            automerge: true,
            local: false,
            verbose: false,
            deleteSourceBranch: false,
          ),
        ).called(1);
      },
    );

    test(
      'skips the pull request when the release is already on main',
      () async {
        stubGitCommands();

        // Only gg bookkeeping and lock-file drift differ from origin/main —
        // the pull request of an earlier, interrupted run was already merged
        // (squash merge, so ancestry checks cannot see it).
        when(
          () => mockProcessWrapper.run(
            'git',
            ['diff', '--name-only', 'origin/main', 'HEAD'],
            runInShell: true,
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer(
          (_) async => ProcessResult(0, 0, '.gg/gg.json\npubspec.lock\n', ''),
        );

        await mergeFlow.get(directory: d, ggLog: ggLog, viaPullRequest: true);

        // No push, no pull request, no waiting — straight to main.
        verifyNever(
          () => mockProcessWrapper.run(
            'git',
            ['push'],
            runInShell: any(named: 'runInShell'),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        );
        verifyNever(
          () => mockGgMergeDoMerge.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            automerge: any(named: 'automerge'),
            local: any(named: 'local'),
            verbose: any(named: 'verbose'),
            deleteSourceBranch: any(named: 'deleteSourceBranch'),
            message: any(named: 'message'),
          ),
        );
        verifyNever(
          () => mockWaitForMerge.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        );

        // Local main is still brought to the merged state.
        verify(
          () => mockProcessWrapper.run(
            'git',
            ['checkout', 'main'],
            runInShell: true,
            workingDirectory: d.path,
          ),
        ).called(2); // once in _fetchAndPullMain, once for the final checkout
        expect(
          messages.any((m) => m.contains('skipping the pull request')),
          isTrue,
        );
      },
    );

    test('commits and re-pushes pre-push-hook drift before creating the '
        'pull request', () async {
      stubGitCommands();

      // The status is checked three times: before the merge (clean), after
      // the first push (a »dart run« pre-push hook rewrote pubspec.lock) and
      // as safety net after the merge wait (clean again).
      var statusCalls = 0;
      when(
        () => mockProcessWrapper.run(
          'git',
          ['status', '--porcelain', '--untracked-files=no'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async {
        statusCalls++;
        return ProcessResult(
          0,
          0,
          statusCalls == 2 ? ' M pubspec.lock\n' : '',
          '',
        );
      });

      when(
        () => mockProcessWrapper.run(
          'git',
          ['add', '--update'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      when(
        () => mockProcessWrapper.run(
          'git',
          [
            'commit',
            '-m',
            '#gg: Commit pending changes before merge '
                '(e.g. release formatting)',
          ],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      when(
        () => mockProcessWrapper.run(
          'git',
          ['push'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: false,
          verbose: false,
          deleteSourceBranch: true,
        ),
      ).thenAnswer((_) async => true);

      when(
        () => mockWaitForMerge.get(
          directory: d,
          ggLog: ggLog,
          branch: any(named: 'branch'),
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog, viaPullRequest: true);

      // The drift commit was created and pushed with a second push; the
      // third push carries the recorded release state into the PR.
      verify(
        () => mockProcessWrapper.run(
          'git',
          [
            'commit',
            '-m',
            '#gg: Commit pending changes before merge '
                '(e.g. release formatting)',
          ],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['push'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(3);
      expect(statusCalls, 3);
    });

    test('records doCommit and doPush before creating the pull request, '
        'so the squashed main passes »gg did commit« and '
        '»gg did push«', () async {
      stubGitCommands();

      when(
        () => mockProcessWrapper.run(
          'git',
          ['push'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: false,
          verbose: false,
          deleteSourceBranch: true,
        ),
      ).thenAnswer((_) async => true);

      when(
        () => mockWaitForMerge.get(
          directory: d,
          ggLog: ggLog,
          branch: any(named: 'branch'),
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog, viaPullRequest: true);

      // Both states are written while the feature branch content is still
      // the content the squash merge puts on main.
      verifyInOrder([
        () => mockGgState.writeSuccess(
          directory: d,
          key: 'doCommit',
          ignoreUnstaged: true,
        ),
        () => mockGgState.writeSuccess(
          directory: d,
          key: 'doPush',
          ignoreUnstaged: true,
        ),
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: false,
          verbose: false,
          deleteSourceBranch: true,
        ),
      ]);
    });

    test('forwards the merge message to the pull-request merge', () async {
      stubGitCommands();

      when(
        () => mockProcessWrapper.run(
          'git',
          ['push'],
          runInShell: true,
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      when(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: false,
          verbose: false,
          deleteSourceBranch: true,
          message: 'Release 1.2.3',
        ),
      ).thenAnswer((_) async => true);

      when(
        () => mockWaitForMerge.get(
          directory: d,
          ggLog: ggLog,
          branch: any(named: 'branch'),
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(
        directory: d,
        ggLog: ggLog,
        viaPullRequest: true,
        message: 'Release 1.2.3',
      );

      verify(
        () => mockGgMergeDoMerge.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: false,
          verbose: false,
          deleteSourceBranch: true,
          message: 'Release 1.2.3',
        ),
      ).called(1);
    });

    group('get', () {
      test('forwards the provided parameters to the gg_merge merge', () async {
        stubGitCommands();

        when(
          () => mockGgMergeDoMerge.get(
            directory: d,
            ggLog: ggLog,
            automerge: true,
            local: true,
            verbose: false,
          ),
        ).thenAnswer((_) async => true);

        await mergeFlow.get(
          directory: d,
          ggLog: ggLog,
          automerge: true,
          local: true,
        );

        verify(
          () => mockGgMergeDoMerge.get(
            directory: d,
            ggLog: ggLog,
            automerge: true,
            local: true,
            verbose: false,
          ),
        ).called(1);
      });
    });
  });
}

class MockGgMergeDoMerge extends Mock implements gg_merge.DoMerge {}

class MockGgMergeWaitForMerge extends Mock implements gg_merge.WaitForMerge {}

class MockGgState extends Mock implements GgState {}

class MockMainBranch extends Mock implements gg_publish.MainBranch {}

class MockGgProcessWrapper extends Mock implements GgProcessWrapper {}
