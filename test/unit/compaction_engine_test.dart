import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';

Message _msg(String role, String content, {String? toolCallsJson}) {
  return Message(
    id: 'm${content.hashCode}',
    sessionId: 's',
    role: role,
    content: content,
    toolCallsJson: toolCallsJson,
    createdAt: content.length,
  );
}

void main() {
  group('CompactionEngine.buildTree', () {
    test('under budget -> no compact, everything verbatim', () {
      final history = [_msg('user', 'hi'), _msg('assistant', 'hello')];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 100000);
      expect(plan.shouldCompact, isFalse);
      expect(plan.folded, isEmpty);
      expect(plan.verbatim.length, 2);
    });

    test('over budget -> folds far span, keeps near verbatim', () {
      // Long far content + short near content under a tight budget.
      final far = [
        for (var i = 0; i < 40; i++) _msg(i.isEven ? 'user' : 'assistant', 'A' * 120),
      ];
      final near = [_msg('assistant', 'recent'), _msg('user', 'now')];
      final history = [...far, ...near];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 450);
      expect(plan.shouldCompact, isTrue);
      expect(plan.folded, isNotEmpty);
      expect(plan.verbatim, isNotEmpty, reason: 'near span must be kept verbatim');
      expect(plan.projectedTokens, lessThanOrEqualTo(450));
      // Order preservation: the folded (far) span is entirely older than the
      // verbatim (near) span — folding never reorders the conversation.
      final highestFolded = history.indexOf(plan.folded.last);
      final lowestVerbatim = history.indexOf(plan.verbatim.first);
      expect(highestFolded, lessThan(lowestVerbatim),
          reason: 'folded span must strictly precede verbatim span');
    });

    test('deterministic: same history+budget -> same plan', () {
      final history = [
        for (var i = 0; i < 30; i++) _msg(i.isEven ? 'user' : 'assistant', 'body${i} ' * 20),
      ];
      final a = CompactionEngine.buildTree(history: history, maxContextTokens: 200);
      final b = CompactionEngine.buildTree(history: history, maxContextTokens: 200);
      expect(a.folded.length, b.folded.length);
      expect(a.verbatim.length, b.verbatim.length);
      expect(a.projectedTokens, b.projectedTokens);
    });

    test('interior far-span chunk boundaries are snapped to a safe boundary', () {
      // NON-DEGENERATE fold (>=2 summary chunks => interior boundaries EXIST).
      // An assistant-with-tool_calls is placed at index 10 — the k=2 chunk
      // boundary (chunkSize = ceil(20/2) = 10). Without _isSafeBoundary snapping
      // in _budgetSegments, chunk 2 would BEGIN on the tool-call assistant, making
      // the D6 assertion fail. This is a non-vacuous guard of the interior-snap.
      final history = [
        for (var i = 0; i < 10; i++) _msg(i.isEven ? 'user' : 'assistant', 'a$i ' * 20),
        _msg('assistant', '', toolCallsJson: '[{"id":"tc","name":"read_file","input":{"path":"/p"}}]'),
        for (var i = 0; i < 9; i++) _msg(i.isEven ? 'user' : 'assistant', 'b$i ' * 20),
      ];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 160);
      // [OBS] show the summary-segment start indices, so a reader can see the fold.
      // ignore: avoid_print
      print('  [OBS] summary chunks=${plan.segments.where((s) => s.summary).length} '
          'starts=${plan.segments.where((s) => s.summary).map((s) => history.indexOf(s.messages.first)).join(",")} '
          'shouldCompact=${plan.shouldCompact}');
      expect(plan.shouldCompact, isTrue, reason: 'an over-budget conversation must fold');
      // Must actually create interior boundaries (>=2 chunks), else the snapping
      // is never exercised and the test is vacuous.
      expect(plan.segments.where((s) => s.summary).length, greaterThanOrEqualTo(2),
          reason: 'the fold must produce >=2 summary chunks so interior boundaries exist');
      for (final seg in plan.segments.where((s) => s.summary)) {
        if (seg.messages.isEmpty) continue;
        expect(seg.messages.first.toolCallsJson, anyOf(isNull, isEmpty),
            reason: 'a summary chunk must never begin on an assistant carrying tool_calls');
      }
    });
  });
}
