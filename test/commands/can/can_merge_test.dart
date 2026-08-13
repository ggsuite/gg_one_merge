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
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:gg_one_commit/gg_one_commit.dart';

void main() {
  late Directory d;
  final messages = <String>[];
  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late CanMerge canMerge;
  late MockGgMergeCanMerge mockGgMergeCanMerge;
  late MockDidCommit mockDidCommit;

  setUp(() async {
    registerFallbackValue(Directory(''));
    messages.clear();
    d = await Directory.systemTemp.createTemp();
    await initGit(d);
    await addAndCommitSampleFile(d);
    mockGgMergeCanMerge = MockGgMergeCanMerge();
    mockDidCommit = MockDidCommit();
    when(
      () => mockDidCommit.exec(directory: d, ggLog: ggLog),
    ).thenAnswer((_) async => true);
    canMerge = CanMerge(
      ggLog: ggLog,
      canMerge: mockGgMergeCanMerge,
      didCommit: mockDidCommit,
    );
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  group('CanMerge', () {
    group('constructor', () {
      test('should initialize with defaults', () {
        final instance = CanMerge(ggLog: ggLog);
        expect(instance.name, 'merge');
        expect(instance.description, 'Check if this repo can be merged');
        expect(instance.shortDescription, 'Can merge?');
        expect(instance.stateKey, 'canMerge');
        expect(instance.commands.length, 2);
        expect(instance.commands[0], isA<DidCommit>());
        expect(instance.commands[1], isA<gg_merge.CanMerge>());
      });

      test('should initialize with provided parameters', () {
        final instance = CanMerge(
          ggLog: ggLog,
          didCommit: mockDidCommit,
          canMerge: mockGgMergeCanMerge,
        );
        expect(instance.commands.length, 2);
        expect(instance.commands[0], mockDidCommit);
        expect(instance.commands[1], mockGgMergeCanMerge);
      });
    });

    test('should call gg_merge CanMerge', () async {
      when(
        () => mockGgMergeCanMerge.exec(directory: d, ggLog: ggLog),
      ).thenAnswer((_) async => true);

      await canMerge.get(directory: d, ggLog: ggLog);

      verify(() => mockDidCommit.exec(directory: d, ggLog: ggLog)).called(1);
      verify(
        () => mockGgMergeCanMerge.exec(directory: d, ggLog: ggLog),
      ).called(1);
    });
  });
}

class MockGgMergeCanMerge extends Mock implements gg_merge.CanMerge {}

class MockDidCommit extends Mock implements DidCommit {}
