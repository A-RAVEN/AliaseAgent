import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/compaction/guard_anchors.dart';

void main() {
  group('GuardAnchors (non-compressible anchor)', () {
    test('enabled + seeded requirements injects a guard prefix', () {
      final g = GuardAnchors();
      g.setStandingRequirements(['never touch the config file', 'keep the workspace root']);
      final prefix = g.inject();
      expect(prefix, contains('## 不可压缩约束'));
      expect(prefix, contains('never touch the config file'));
      expect(prefix, contains('keep the workspace root'));
    });

    test('no anchors injects nothing', () {
      final g = GuardAnchors();
      expect(g.inject(), isEmpty, reason: 'no anchors -> no guard prefix');
    });

    test('seed with empty requirements disables the guard', () {
      final g = GuardAnchors();
      g.setStandingRequirements(const []);
      g.add('foo'); // add after explicit-disable via empty requirements
      expect(g.inject(), isEmpty,
          reason: 'an empty standing-requirements list disables the guard');
    });

    test('deduplicated by normalized text', () {
      final g = GuardAnchors();
      g.add('Do not touch X');
      g.add('do not touch x'); // same, normalized
      g.add('Do not touch X.'); // different text -> separate
      expect(g.active.length, 2);
    });

    test('bounded by maxAnchors (evicts oldest)', () {
      final g = GuardAnchors();
      for (var i = 0; i < GuardAnchors.maxAnchors + 5; i++) {
        g.add('requirement $i');
      }
      expect(g.active.length, GuardAnchors.maxAnchors);
      // Oldest ('requirement 0') was evicted.
      expect(g.active.any((a) => a.text == 'requirement 0'), isFalse);
    });

    test('revoke removes an anchor from injection', () {
      final g = GuardAnchors();
      final a = g.add('level-2 invariant');
      expect(g.inject(), contains('level-2 invariant'));
      g.revoke(a.id);
      expect(g.inject(), isNot(contains('level-2 invariant')));
      expect(g.isRevoked(a.id), isTrue);
    });
  });
}
