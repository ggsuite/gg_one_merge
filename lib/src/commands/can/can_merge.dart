// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_args/gg_args.dart';
import 'package:gg_merge/gg_merge.dart' as gg_merge;
import 'package:gg_one_commit/gg_one_commit.dart';

/// Are the last changes ready to be merged?
class CanMerge extends CommandCluster {
  /// Constructor
  CanMerge({
    required super.ggLog,
    super.name = 'merge',
    super.description = 'Check if this repo can be merged',
    super.shortDescription = 'Can merge?',
    super.stateKey = 'canMerge',
    DidCommit? didCommit,
    gg_merge.CanMerge? canMerge,
  }) : super(
         commands: [
           didCommit ?? DidCommit(ggLog: ggLog),
           canMerge ?? gg_merge.CanMerge(ggLog: ggLog),
         ],
       );
}

// .............................................................................
/// A mocktail mock
class MockCanMerge extends MockDirCommand<void> implements CanMerge {}
