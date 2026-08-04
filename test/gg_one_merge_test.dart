// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_merge/gg_one_merge.dart';
import 'package:test/test.dart';

void main() {
  group('GgOneMerge()', () {
    group('foo()', () {
      test('should return foo', () async {
        const ggOneMerge = GgOneMerge();
        expect(ggOneMerge.foo(), 'foo');
      });
    });
  });
}
