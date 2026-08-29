import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';

Message _msg(String role, String content, {String? toolCallsJson, int? seq}) {
  return Message(
    id: 'm${content.hashCode}',
    sessionId: 's',
    role: role,
    content: content,
    toolCallsJson: toolCallsJson,
    seq: seq,
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

    test('progressive closure: closed segments are reused, only the tail folds', () {
      // 40 old messages (seq 1..40) closed/frozen + 6 recent (seq 41..46).
      final old = [
        for (var i = 1; i <= 40; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'old$i ' * 20, seq: i),
      ];
      final recent = [
        for (var i = 41; i <= 46; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'recent$i ' * 20, seq: i),
      ];
      final history = [...old, ...recent];
      final closed = [const ClosedSummary(level: 1, coveredMinSeq: 1, coveredMaxSeq: 40, tokenCost: 30)];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 200, closed: closed);

      // Exactly one closed (reused) segment, covering the frozen span.
      expect(plan.segments.where((s) => s.isClosed).length, 1, reason: 'one closed segment');
      final closedSeg = plan.segments.firstWhere((s) => s.isClosed);
      expect(closedSeg.reuse!.coveredMinSeq, 1);
      expect(closedSeg.reuse!.coveredMaxSeq, 40);
      expect(closedSeg.messages.every((m) => (m.seq ?? 0) <= 40), isTrue,
          reason: 'closed segment messages lie at or below the closed floor');

      // No FRESH (non-closed) segment re-touches the frozen prefix — every
      // non-closed segment is over messages strictly newer than the closed floor.
      for (final seg in plan.segments.where((s) => !s.isClosed)) {
        expect(seg.messages.isEmpty || seg.messages.every((m) => (m.seq ?? 0) > 40),
            isTrue,
            reason: 'non-closed (fresh) segments must only contain tail messages above the closed floor');
      }
      // Budget accounting includes the frozen summary cost.
      expect(plan.projectedTokens, greaterThanOrEqualTo(30));
    });

    test('4.2 gradient: far span coarsens to [L2 oldest][L1 medium] + verbatim, budget-fitted', () {
      // 48 old messages (far) + 4 recent (near). Chunked into L1 (~8 each), but
      // the L1 total exceeds the far budget -> coarsen the OLDEST L1s into a
      // level-2 "summary of summaries", keeping medium L1s. Projection order
      // must be [L2][L1...][verbatim] (oldest->newest), never reorders.
      final history = [
        for (var i = 1; i <= 48; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'old$i ' * 20, seq: i),
        for (var i = 49; i <= 52; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'recent$i ' * 20, seq: i),
      ];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 420);
      // [OBS] dump the gradient so a failure is attributable.
      // ignore: avoid_print
      print('  [OBS] level2=${plan.segments.where((s) => s.level == 2).length} '
          'level1=${plan.segments.where((s) => s.level == 1).length} '
          'verbatim=${plan.segments.where((s) => !s.summary).expand((s) => s.messages).length} '
          'projected=${plan.projectedTokens}');
      expect(plan.shouldCompact, isTrue);
      // Budget respected.
      expect(plan.projectedTokens, lessThanOrEqualTo(420));
      // At least one summary territory was produced (compaction happened).
      expect(plan.segments.where((s) => s.summary).length, greaterThanOrEqualTo(1));
      // Order (coarsen-only, gradient): IF a level-2 (deep/oldest) and a level-1
      // (medium) tier both exist, L2 must precede L1; and L1 must precede verbatim.
      final l2 = plan.segments.where((s) => s.level == 2).toList();
      final l1 = plan.segments.where((s) => s.level == 1).toList();
      final verb = plan.segments.where((s) => !s.summary).toList();
      int idx(CompactionSegment s) => history.indexOf(s.messages.isEmpty ? history.first : s.messages.first);
      if (l2.isNotEmpty && l1.isNotEmpty) {
        expect(idx(l2.last), lessThan(idx(l1.first)),
            reason: 'oldest (L2) tier must strictly precede medium (L1) tier');
      }
      if (l1.isNotEmpty && verb.isNotEmpty) {
        expect(idx(l1.last), lessThan(idx(verb.first)),
            reason: 'medium (L1) tier must strictly precede verbatim');
      }
      // No summary chunk can begin on an assistant carrying tool_calls.
      for (final seg in plan.segments.where((s) => s.summary)) {
        expect(seg.messages.isEmpty || seg.messages.first.toolCallsJson == null,
            isTrue, reason: 'summary chunk never begins on tool_calls');
      }
    });

    test('4.2 gradient: lone level-2 over budget omits oldest from projection (data kept)', () {
      // Deeply over budget: even a lone level-2 over the whole far still exceeds
      // the far budget, so the OLDEST messages are omitted from the projection.
      final history = [
        for (var i = 1; i <= 60; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'x$i ' * 30, seq: i),
      ];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 150);
      // ignore: avoid_print
      print('  [OBS] fully-coarsened level2=${plan.segments.where((s) => s.level == 2).length} '
          'summaries=${plan.segments.where((s) => s.summary).length} projected=${plan.projectedTokens}');
      expect(plan.shouldCompact, isTrue);
      // The OLDEST content is omitted (fewer messages summarized than the full
      // history), i.e. the far span was truncated from the projection.
      final totalSummarized = plan.segments.where((s) => s.summary).expand((s) => s.messages).length;
      expect(totalSummarized, lessThan(history.length),
          reason: 'lone L2 over budget omits the oldest content from the projection');
    });

    test('progressive closure: fully-closed conversation reuses everything, no fresh fold', () {
      final history = [
        for (var i = 1; i <= 12; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'body$i ' * 20, seq: i),
      ];
      final closed = [const ClosedSummary(level: 1, coveredMinSeq: 1, coveredMaxSeq: 12, tokenCost: 60)];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 100, closed: closed);
      expect(plan.segments.where((s) => s.isClosed).length, 1);
      expect(plan.segments.where((s) => !s.isClosed && s.summary).length, 0,
          reason: 'a fully-closed conversation folds nothing fresh');
      expect(plan.segments.where((s) => !s.isClosed && !s.summary && s.messages.isNotEmpty),
          isEmpty, reason: 'no verbatim tail when the whole conversation is closed');
    });
  });
}
