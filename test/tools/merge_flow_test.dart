// @license
// Copyright (c) ggsuite
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
  late gg_merge.MockCanMerge mockCanMerge;
  late MockGgState mockGgState;
  late MockMainBranch mockMainBranch;
  late MockGgProcessWrapper mockProcessWrapper;
  late MockGgSystemCommit mockSystemCommit;

  // Fixed shas for the plumbing squash of the checkout-free local merge.
  const originMainSha = '1111111111111111111111111111111111111111';
  const treeSha = '2222222222222222222222222222222222222222';
  const squashSha = '3333333333333333333333333333333333333333';

  void stubGitCommands({
    String mainBranchName = 'main',
    String currentBranch = 'feature/x',
    String localMainSha = originMainSha,
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
        ['fetch'],
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

    // The refs of the checkout-free sync: origin/<main> and the local
    // <main> point at the same commit by default, so the sync is a no-op.
    when(
      () => mockProcessWrapper.run(
        'git',
        [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/remotes/origin/$mainBranchName',
        ],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '$originMainSha\n', ''));
    when(
      () => mockProcessWrapper.run(
        'git',
        ['rev-parse', '--verify', '--quiet', 'refs/heads/$mainBranchName'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '$localMainSha\n', ''));

    // The plumbing squash: main is contained in the feature branch, the
    // feature tree becomes the squash commit, the main ref moves onto it.
    when(
      () => mockProcessWrapper.run(
        'git',
        ['merge-base', '--is-ancestor', localMainSha, 'HEAD'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
    when(
      () => mockProcessWrapper.run(
        'git',
        ['rev-parse', 'HEAD:'],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '$treeSha\n', ''));
    when(
      () => mockProcessWrapper.run(
        'git',
        [
          'commit-tree',
          treeSha,
          '-p',
          localMainSha,
          '-m',
          'Merged $currentBranch into $mainBranchName',
        ],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '$squashSha\n', ''));
    when(
      () => mockProcessWrapper.run(
        'git',
        ['update-ref', 'refs/heads/$mainBranchName', squashSha, localMainSha],
        runInShell: true,
        workingDirectory: any(named: 'workingDirectory'),
      ),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
  }

  /// Stubs the system commit — [ggFiles] and [foreignFiles] describe what it
  /// found dirty and committed.
  void stubSystemCommit({
    List<String> ggFiles = const [],
    List<String> foreignFiles = const [],
  }) {
    when(
      () => mockSystemCommit.commit(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
        message: any(named: 'message'),
        paths: any(named: 'paths'),
        includeUntracked: any(named: 'includeUntracked'),
        ammendWhenNotPushed: any(named: 'ammendWhenNotPushed'),
        userCommitMessage: any(named: 'userCommitMessage'),
        stateKey: any(named: 'stateKey'),
      ),
    ).thenAnswer(
      (_) async => GgSystemCommitResult(
        userCommitCreated: foreignFiles.isNotEmpty,
        systemCommitCreated: ggFiles.isNotEmpty,
        ggOwnedPaths: ggFiles,
        foreignPaths: foreignFiles,
      ),
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
    mockCanMerge = gg_merge.MockCanMerge();
    mockGgState = MockGgState();
    mockMainBranch = MockMainBranch();
    mockProcessWrapper = MockGgProcessWrapper();
    mockSystemCommit = MockGgSystemCommit();
    mergeFlow = MergeFlow(
      ggLog: ggLog,
      doMerge: mockGgMergeDoMerge,
      waitForMerge: mockWaitForMerge,
      canMerge: mockCanMerge,
      state: mockGgState,
      mainBranch: mockMainBranch,
      systemCommit: mockSystemCommit,
      processWrapper: mockProcessWrapper,
    );

    // Default: nothing pending, so no bookkeeping commit is created.
    stubSystemCommit();

    // Default: the merge pre-conditions are fulfilled.
    when(
      () => mockCanMerge.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async => true);

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
          canMerge: mockCanMerge,
          mainBranch: mockMainBranch,
          processWrapper: mockProcessWrapper,
        );
        expect(instance.ggLog, ggLog);
      });
    });

    test('squash-merges locally without checking anything out', () async {
      stubGitCommands();

      await mergeFlow.get(directory: d, ggLog: ggLog);

      verifyInOrder([
        // The gate of the pull-request path runs here too.
        () => mockCanMerge.get(directory: d, ggLog: ggLog),
        // The squash commit is built with plumbing on the feature branch …
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', 'HEAD:'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          [
            'commit-tree',
            treeSha,
            '-p',
            originMainSha,
            '-m',
            'Merged feature/x into main',
          ],
          runInShell: true,
          workingDirectory: d.path,
        ),
        // … and the main ref is moved onto it, guarded by its old tip.
        () => mockProcessWrapper.run(
          'git',
          ['update-ref', 'refs/heads/main', squashSha, originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockGgState.writeSuccess(
          directory: d,
          key: 'doCommit',
          ignoreUnstaged: true,
        ),
      ]);

      // Neither branch is ever checked out — no editor tooling can descend
      // on an old worktree state — and gg_merge's DoMerge (whose local
      // merge checks main out) is not involved at all.
      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'main'],
          runInShell: any(named: 'runInShell'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'feature/x'],
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
          message: any(named: 'message'),
          verbose: any(named: 'verbose'),
        ),
      );
      expect(
        messages.any((m) => m.contains('Squash-merged feature/x into main')),
        isTrue,
      );
    });

    test('resets a diverged main when only gg bookkeeping differs', () async {
      const divergedSha = '4444444444444444444444444444444444444444';
      stubGitCommands();

      // The local main ref diverged from origin/main. After the forced move
      // the ref is read again, so the stub answers with the diverged sha
      // first and with origin/main afterwards.
      var localMainReads = 0;
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--verify', '--quiet', 'refs/heads/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async {
        localMainReads++;
        return ProcessResult(
          0,
          0,
          localMainReads == 1 ? '$divergedSha\n' : '$originMainSha\n',
          '',
        );
      });
      when(
        () => mockProcessWrapper.run(
          'git',
          ['merge-base', '--is-ancestor', divergedSha, originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));

      // The local-only commits touch gg bookkeeping and lock files only.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['log', 'origin/main..main', '--name-only', '--pretty=format:'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer(
        (_) async => ProcessResult(0, 0, '.gg/gg.json\npubspec.lock\n', ''),
      );

      when(
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await mergeFlow.get(directory: d, ggLog: ggLog);

      // The ref was force-moved — no checkout, no reset of any worktree.
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
      expect(messages.any((m) => m.contains('gg bookkeeping only')), isTrue);
    });

    test('throws when main diverged with real local commits', () async {
      const divergedSha = '4444444444444444444444444444444444444444';
      stubGitCommands(localMainSha: divergedSha);

      when(
        () => mockProcessWrapper.run(
          'git',
          ['merge-base', '--is-ancestor', divergedSha, originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));

      // The local-only commits touch real source files.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['log', 'origin/main..main', '--name-only', '--pretty=format:'],
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

      // Real commits are never discarded, and no squash commit is created.
      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      );
      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['update-ref', 'refs/heads/main', squashSha, divergedSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      );
    });

    test('commits pending worktree changes before merge', () async {
      stubGitCommands();

      // A formatter / gg run left tracked files dirty after the last commit.
      stubSystemCommit(ggFiles: ['pubspec.yaml']);

      await mergeFlow.get(directory: d, ggLog: ggLog);

      // Committed before the squash commit is built, so the leftovers are
      // part of the release tree. Untracked files stay out — stray build
      // output must never be swept in.
      final call = verify(
        () => mockSystemCommit.commit(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: captureAny(named: 'message'),
          includeUntracked: captureAny(named: 'includeUntracked'),
        ),
      )..called(1);
      expect(
        call.captured[0],
        '${ggCommitPrefix}Commit pending changes before merge '
        '(e.g. release formatting)',
      );
      expect(call.captured[1], isFalse);

      expect(
        messages,
        contains(
          'Committed pending worktree changes before merge '
          '(e.g. formatter output or run state).',
        ),
      );
    });

    test('throws when HEAD is already on the main branch', () async {
      stubGitCommands(currentBranch: 'main');

      await expectLater(
        mergeFlow.get(directory: d, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Already on main branch; nothing to merge.'),
          ),
        ),
      );

      // Nothing was merged or moved.
      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', 'HEAD:'],
          runInShell: any(named: 'runInShell'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
    });

    test('leaves the local main ref alone when origin has no main', () async {
      stubGitCommands();

      // No remote main — e.g. a repository whose default branch was never
      // pushed. The local ref stays where it is and the squash proceeds.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));

      await mergeFlow.get(directory: d, ggLog: ggLog);

      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', originMainSha],
          runInShell: any(named: 'runInShell'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['update-ref', 'refs/heads/main', squashSha, originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
    });

    test('creates the local main ref from origin when it is missing', () async {
      stubGitCommands();

      // The local main ref does not exist yet; after the sync created it,
      // the ref is read again and answers with origin/main.
      var localMainReads = 0;
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--verify', '--quiet', 'refs/heads/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async {
        localMainReads++;
        return localMainReads == 1
            ? ProcessResult(0, 1, '', '')
            : ProcessResult(0, 0, '$originMainSha\n', '');
      });
      when(
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await mergeFlow.get(directory: d, ggLog: ggLog);

      verify(
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(1);
    });

    test('throws when there is no main branch at all', () async {
      stubGitCommands();

      // Neither a remote nor a local main exists — nothing to merge into.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--verify', '--quiet', 'refs/heads/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));

      await expectLater(
        mergeFlow.get(directory: d, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('There is no main branch to merge into.'),
          ),
        ),
      );
    });

    test('throws when main is not contained in the feature branch', () async {
      stubGitCommands();

      // The belt-and-braces check behind CanMerge: the plumbing squash would
      // silently drop main's extra content, so it must refuse.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['merge-base', '--is-ancestor', originMainSha, 'HEAD'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));

      await expectLater(
        mergeFlow.get(directory: d, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('main contains commits the feature branch does not'),
          ),
        ),
      );

      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', 'HEAD:'],
          runInShell: any(named: 'runInShell'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
    });

    test('surfaces a failing git command with its stderr', () async {
      stubGitCommands();

      // A concurrent move of the main ref makes the guarded update-ref fail.
      when(
        () => mockProcessWrapper.run(
          'git',
          ['update-ref', 'refs/heads/main', squashSha, originMainSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer(
        (_) async => ProcessResult(0, 1, '', 'ref moved concurrently'),
      );

      await expectLater(
        mergeFlow.get(directory: d, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains('Failed to move main onto the squash commit'),
              contains('ref moved concurrently'),
            ),
          ),
        ),
      );
    });

    test('logs each git command when verbose is true', () async {
      stubGitCommands();

      await mergeFlow.get(directory: d, ggLog: ggLog, verbose: true);

      expect(
        messages,
        containsAll(<String>[
          '\$ git rev-parse --abbrev-ref HEAD',
          '\$ git rev-parse HEAD:',
          '\$ git commit-tree $treeSha -p $originMainSha '
              '-m Merged feature/x into main',
          '\$ git update-ref refs/heads/main $squashSha $originMainSha',
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
      final call = verify(
        () => mockSystemCommit.commit(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: captureAny(named: 'message'),
          paths: captureAny(named: 'paths'),
        ),
      )..called(1);
      expect(call.captured[0], '${ggCommitPrefix}Remove .gg/ticket.json');
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

    test('merges via a pull request and waits for it, then fast-forwards '
        'the local main ref without a checkout', () async {
      const mergedSha = '5555555555555555555555555555555555555555';
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
          autoMerge: any(named: 'autoMerge'),
        ),
      ).thenAnswer((_) async => true);

      // After the provider merged, origin/main points at the squash commit;
      // the stale local main is an ancestor of it (fast-forwardable).
      when(
        () => mockProcessWrapper.run(
          'git',
          ['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '$mergedSha\n', ''));
      when(
        () => mockProcessWrapper.run(
          'git',
          ['merge-base', '--is-ancestor', originMainSha, mergedSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', mergedSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await mergeFlow.get(directory: d, ggLog: ggLog, viaPullRequest: true);

      verifyInOrder([
        // Refresh the remote-tracking refs, then push + create + wait.
        () => mockProcessWrapper.run(
          'git',
          ['fetch'],
          runInShell: true,
          workingDirectory: d.path,
        ),
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
          autoMerge: any(named: 'autoMerge'),
        ),
        // Fetch again (the provider merged after the last fetch), then
        // fast-forward the local main REF — no checkout.
        () => mockProcessWrapper.run(
          'git',
          ['fetch'],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockProcessWrapper.run(
          'git',
          ['branch', '-f', 'main', mergedSha],
          runInShell: true,
          workingDirectory: d.path,
        ),
        () => mockGgState.writeSuccess(
          directory: d,
          key: 'doCommit',
          ignoreUnstaged: true,
        ),
      ]);

      // No branch is ever checked out, and the local merge path never runs.
      verifyNever(
        () => mockProcessWrapper.run(
          'git',
          ['checkout', 'main'],
          runInShell: any(named: 'runInShell'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
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
            autoMerge: any(named: 'autoMerge'),
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

        // The local main ref is still synced to origin — without a checkout.
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
        ).called(2); // once at the start, once for the final ref sync
        expect(
          messages.any((m) => m.contains('skipping the pull request')),
          isTrue,
        );
      },
    );

    test('commits and re-pushes pre-push-hook drift before creating the '
        'pull request', () async {
      stubGitCommands();

      // The system commit runs twice: before the merge (nothing pending) and
      // after the first push (a »dart run« pre-push hook rewrote
      // pubspec.lock).
      var commitCalls = 0;
      when(
        () => mockSystemCommit.commit(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          paths: any(named: 'paths'),
          includeUntracked: any(named: 'includeUntracked'),
          ammendWhenNotPushed: any(named: 'ammendWhenNotPushed'),
          userCommitMessage: any(named: 'userCommitMessage'),
          stateKey: any(named: 'stateKey'),
        ),
      ).thenAnswer((_) async {
        commitCalls++;
        final drift = commitCalls == 2;
        return GgSystemCommitResult(
          userCommitCreated: false,
          systemCommitCreated: drift,
          ggOwnedPaths: drift ? ['pubspec.lock'] : const [],
          foreignPaths: const [],
        );
      });

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
          autoMerge: any(named: 'autoMerge'),
        ),
      ).thenAnswer((_) async => true);

      await mergeFlow.get(directory: d, ggLog: ggLog, viaPullRequest: true);

      // The drift commit was created and pushed with a second push; the
      // third push carries the recorded release state into the PR.
      expect(commitCalls, 2);
      verify(
        () => mockProcessWrapper.run(
          'git',
          ['push'],
          runInShell: true,
          workingDirectory: d.path,
        ),
      ).called(3);
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
          autoMerge: any(named: 'autoMerge'),
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
          autoMerge: any(named: 'autoMerge'),
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
      test('passes the merge message into the squash commit', () async {
        stubGitCommands();

        when(
          () => mockProcessWrapper.run(
            'git',
            [
              'commit-tree',
              treeSha,
              '-p',
              originMainSha,
              '-m',
              'Release 1.2.3',
            ],
            runInShell: true,
            workingDirectory: d.path,
          ),
        ).thenAnswer((_) async => ProcessResult(0, 0, '$squashSha\n', ''));

        await mergeFlow.get(
          directory: d,
          ggLog: ggLog,
          message: 'Release 1.2.3',
        );

        verify(
          () => mockProcessWrapper.run(
            'git',
            [
              'commit-tree',
              treeSha,
              '-p',
              originMainSha,
              '-m',
              'Release 1.2.3',
            ],
            runInShell: true,
            workingDirectory: d.path,
          ),
        ).called(1);
      });
    });

    test('real repository: the squash lands on main, HEAD stays on the '
        'feature branch and no checkout ever happens', () async {
      // A real repo pair: main is pushed, the feature branch is ahead of it.
      final local = await Directory.systemTemp.createTemp('merge_flow_real_');
      final remote = await Directory.systemTemp.createTemp(
        'merge_flow_real_remote_',
      );
      addTearDown(() async {
        await local.delete(recursive: true);
        await remote.delete(recursive: true);
      });
      await initLocalGit(local);
      await initRemoteGit(remote);
      await addRemoteToLocal(local: local, remote: remote);

      Future<String> git(List<String> args) async {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: local.path,
        );
        expect(result.exitCode, 0, reason: 'git $args: ${result.stderr}');
        return (result.stdout as String).trim();
      }

      await git(['checkout', '-b', 'feat_real']);
      File('${local.path}/feature.txt')
          .writeAsStringSync('the release content');
      await git(['add', 'feature.txt']);
      await git(['commit', '-m', 'Add feature']);
      await git(['push', '--set-upstream', 'origin', 'feat_real']);

      final mainShaBefore = await git(['rev-parse', 'refs/heads/main']);
      final checkoutsBefore = (await git(['reflog']))
          .split('\n')
          .where((l) => l.contains('checkout:'))
          .length;

      // Everything real — git, CanMerge, GgState, MainBranch.
      final realFlow = MergeFlow(ggLog: ggLog);
      await realFlow.get(
        directory: local,
        ggLog: ggLog,
        message: 'The real release',
      );

      // HEAD never moved: still on the feature branch, and the reflog shows
      // not a single new checkout — the reason this flow exists, because a
      // checkout of the old main state makes editor tooling descend on the
      // worktree and rewrite lock files mid-release.
      expect(await git(['rev-parse', '--abbrev-ref', 'HEAD']), 'feat_real');
      final checkoutsAfter = (await git(['reflog']))
          .split('\n')
          .where((l) => l.contains('checkout:'))
          .length;
      expect(checkoutsAfter, checkoutsBefore);

      // The squash commit sits on main: parented on the old main tip,
      // carrying the feature branch's release content and the merge
      // message. (feat_real itself moved one commit further in the
      // meantime — the doCommit state bookkeeping — so the trees are
      // compared via the released file, not via the branch tips.)
      final mainShaAfter = await git(['rev-parse', 'refs/heads/main']);
      expect(mainShaAfter, isNot(mainShaBefore));
      expect(await git(['rev-parse', 'main^']), mainShaBefore);
      expect(await git(['show', 'main:feature.txt']), 'the release content');
      expect(
        await git(['log', '-1', '--format=%s', 'main']),
        'The real release',
      );
    });
  });
}

class MockGgMergeDoMerge extends Mock implements gg_merge.DoMerge {}

class MockGgMergeWaitForMerge extends Mock implements gg_merge.WaitForMerge {}

class MockGgState extends Mock implements GgState {}

class MockMainBranch extends Mock implements gg_publish.MainBranch {}

class MockGgProcessWrapper extends Mock implements GgProcessWrapper {}
