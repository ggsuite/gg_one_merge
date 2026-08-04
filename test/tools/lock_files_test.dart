// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_merge/gg_one_merge.dart';
import 'package:test/test.dart';

void main() {
  group('isLockFile', () {
    test('recognizes the lock file of every supported language', () {
      expect(isLockFile('pubspec.lock'), isTrue);
      expect(isLockFile('package-lock.json'), isTrue);
      expect(isLockFile('pnpm-lock.yaml'), isTrue);
      expect(isLockFile('yarn.lock'), isTrue);
    });

    test('recognizes a lock file in a subfolder', () {
      expect(isLockFile('packages/x/pubspec.lock'), isTrue);
      expect(isLockFile('ts/pnpm-lock.yaml'), isTrue);
    });

    test('does not recognize a manifest or another file', () {
      expect(isLockFile('pubspec.yaml'), isFalse);
      expect(isLockFile('package.json'), isFalse);
      expect(isLockFile('lib/src/tools/lock_files.dart'), isFalse);
      expect(isLockFile('my_pubspec.lock.bak'), isFalse);
    });

    test('tolerates surrounding whitespace', () {
      expect(isLockFile('  pubspec.lock  '), isTrue);
    });
  });

  group('lockFilesInStatus', () {
    test('returns the lock files git reported, in order', () {
      const status =
          ' M pubspec.yaml\n'
          ' M pubspec.lock\n'
          '?? packages/x/pubspec.lock\n';

      expect(lockFilesInStatus(status), <String>[
        'pubspec.lock',
        'packages/x/pubspec.lock',
      ]);
    });

    test('reports a renamed lock file under its new name', () {
      const status = 'R  old/pubspec.lock -> new/pubspec.lock\n';

      expect(lockFilesInStatus(status), <String>['new/pubspec.lock']);
    });

    test('returns nothing for a clean tree', () {
      expect(lockFilesInStatus(''), isEmpty);
    });

    test('parses trimmed output, where ` M x` lost its leading space', () {
      // `runGit` trims, so the first line arrives without its status padding.
      expect(lockFilesInStatus('M pubspec.lock\n M pnpm-lock.yaml'), <String>[
        'pubspec.lock',
        'pnpm-lock.yaml',
      ]);
    });

    test('parses a staged file, whose second status column is a space', () {
      expect(lockFilesInStatus('A  pubspec.lock'), <String>['pubspec.lock']);
    });
  });

  group('isLockFileOnlyDrift', () {
    test('is true when nothing but lock files changed', () {
      expect(isLockFileOnlyDrift(' M pubspec.lock\n'), isTrue);
      expect(
        isLockFileOnlyDrift(' M pubspec.lock\n?? pnpm-lock.yaml\n'),
        isTrue,
      );
    });

    test('is false when a single other file changed as well', () {
      expect(
        isLockFileOnlyDrift(' M pubspec.lock\n M lib/src/main.dart\n'),
        isFalse,
      );
    });

    test('is false for a clean tree — there is nothing to commit', () {
      expect(isLockFileOnlyDrift(''), isFalse);
      expect(isLockFileOnlyDrift('\n'), isFalse);
    });
  });
}
