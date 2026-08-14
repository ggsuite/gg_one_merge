// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_lang/gg_lang.dart' as gg_lang;
import 'package:path/path.dart' as p;

/// Whether [file] is a dependency lock file — `pubspec.lock` or one of the
/// TypeScript package managers' lock files.
///
/// [file] is a path as git reports it, so only its basename is compared: the
/// canonical set in `gg_lang.allLockFileNames` holds bare names, and a repo
/// that keeps a package in a subfolder reports `packages/x/pubspec.lock`.
/// Matching the whole path would silently stop recognizing exactly those.
bool isLockFile(String file) =>
    gg_lang.allLockFileNames.contains(p.basename(file.trim()));

/// The lock files reported as changed in the `git status --porcelain` output
/// [status], in the order git listed them.
///
/// Renames (`R  old -> new`) are reported under their new name, which is the
/// one a later `git add` has to stage.
List<String> lockFilesInStatus(String status) => <String>[
  for (final file in _filesInStatus(status))
    if (isLockFile(file)) file,
];

/// Whether [status] — a `git status --porcelain` output — reports changes and
/// *every one of them* is a lock file.
///
/// This is what turns a blocked check into a recoverable one: a working tree
/// that differs from the last commit in nothing but lock files carries no
/// user work, so the drift can be committed instead of aborting the run. A
/// clean tree is not drift and returns false — there is nothing to commit.
bool isLockFileOnlyDrift(String status) {
  final files = _filesInStatus(status);
  return files.isNotEmpty && files.every(isLockFile);
}

/// The file paths of a `git status --porcelain` output.
///
/// Each line is `XY <path>`. The two status columns are fixed-width, but the
/// path is *not* taken from column 3: callers hand in trimmed output as often
/// as raw output (`runGit` trims), and trimming eats the leading space of an
/// unstaged ` M path`, shifting every path by one character. So the path is
/// whatever follows the first space of the trimmed line, which is the same
/// answer for both shapes.
///
/// A rename adds ` -> <new path>`; the new name is what is returned, because
/// that is the path that exists on disk now. A path git quoted (because it
/// holds special characters) does not parse into a bare name and simply will
/// not match a lock file — which errs toward treating it as real work.
Iterable<String> _filesInStatus(String status) sync* {
  for (final line in status.split('\n')) {
    final trimmed = line.trim();
    final space = trimmed.indexOf(' ');
    if (space < 0) {
      continue;
    }

    final path = trimmed.substring(space + 1).trim();
    final arrow = path.indexOf(' -> ');
    yield arrow >= 0 ? path.substring(arrow + 4).trim() : path;
  }
}
