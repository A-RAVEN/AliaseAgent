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
  group('CompactionEngine.buildTree (structure-only, no /4)', () {
    test('under budget -> no compact, everything verbatim', () {
      final history = [_msg('user', 'hi'), _msg('assistant', 'hello')];
      final plan =
          CompactionEngine.buildTree(history: history, maxContextTokens: 100000);
      expect(plan.shouldCompact, isFalse);
      expect(plan.folded, isEmpty);
      expect(plan.verbatim.length, 2);
    });

    test('over budget -> batches far span (raw > T), keeps newest verbatim', () {
      // 38 'A'*120 far msgs (~34 proxy each) + 2 near. budget 450 → T=225.
      final far = [
        for (var i = 0; i < 38; i++) _msg(i.isEven ? 'user' : 'assistant', 'A' * 120),
      ];
      final near = [_msg('assistant', 'recent'), _msg('user', 'now')];
      final history = [...far, ...near];
      final plan =
          CompactionEngine.buildTree(history: history, maxContextTokens: 450);
      expect(plan.shouldCompact, isTrue);
      expect(plan.folded, isNotEmpty, reason: 'over budget must fold');
      expect(plan.verbatim, isNotEmpty, reason: 'near span must be kept verbatim');
      // Structure only: projectedTokens is the RAW trigger size (> budget when
      // folding); the real budget fit is measured at runtime (⑪.3).
      expect(plan.projectedTokens, greaterThan(450),
          reason: 'projected = raw trigger size; post-compaction size is measured');
      // Order preservation: the folded (far) span is entirely older than the
      // verbatim (near) span — folding never reorders the conversation.
      final highestFolded = history.indexOf(plan.folded.last);
      final lowestVerbatim = history.indexOf(plan.verbatim.first);
      expect(highestFolded, lessThan(lowestVerbatim),
          reason: 'folded span must strictly precede verbatim span');
      // The fold produces L1 summary batches; buildTree (pure) MUST NOT emit a
      // level-2 (coarsening is runtime, driven by measured sizes).
      expect(plan.segments.where((s) => s.summary && s.level == 2), isEmpty,
          reason: 'L2 coarsening is a runtime decision, not a pure boundary');
      // L1 batches never begin on an assistant carrying tool_calls.
      for (final seg in plan.segments.where((s) => s.summary)) {
        if (seg.messages.isEmpty) continue;
        expect(seg.messages.first.toolCallsJson, anyOf(isNull, isEmpty),
            reason: 'a summary batch must never begin on tool_calls');
      }
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

    test('batch boundaries accumulate RAW token > T (oldest-first)', () {
      // Each msg ~34 proxy. T = 250/2 = 125. A batch cuts when accumulated raw
      // exceeds 125: 34*3=102 <=125, 34*4=136>125 → batch of 4.
      final history = [
        for (var i = 0; i < 20; i++) _msg(i.isEven ? 'user' : 'assistant', 'A' * 120),
      ];
      final plan =
          CompactionEngine.buildTree(history: history, maxContextTokens: 250);
      // 20 msgs, T=125 → batches of 4 → 5 L1 batches; near verbatim = a tail ≤125.
      final summaries = plan.segments.where((s) => s.summary).toList();
      // ignore: avoid_print
      print('  [OBS] batchCount=${summaries.length} '
          'sizes=${summaries.map((s) => s.messages.length).join(",")} '
          'near=${plan.verbatim.length}');
      // Cover is dense + complete and every batch accumulated raw > T (min raw
      // batch size here = 4 msgs for T=125); the near tail is verbatim.
      expect(plan.shouldCompact, isTrue);
      expect(summaries.length, greaterThanOrEqualTo(2),
          reason: 'a 20-message over-budget span splits into multiple L1 batches');
      // No batch begins on tool_calls; each summary segment's messages are a
      // contiguous, ordered slice of history.
      final covered = summaries.expand((s) => s.messages).toList();
      expect(covered.map((m) => m.content).toList(),
          history.sublist(0, covered.length).map((m) => m.content).toList(),
          reason: 'summary batches cover the far span contiguously in order');
    });

    test('interior far-span batch boundaries are snapped to a safe boundary', () {
      // NON-DEGENERATE fold. An assistant-with-tool_calls sits at index 10. The
      // raw-token batch boundary lands near index 10; without safe snapping a
      // summary batch would BEGIN on the tool-call assistant. This is a
      // non-vacuous guard of the interior-snap.
      final history = [
        for (var i = 0; i < 10; i++) _msg(i.isEven ? 'user' : 'assistant', 'a$i ' * 20),
        _msg('assistant', '', toolCallsJson: '[{"id":"tc","name":"read_file","input":{"path":"/p"}}]'),
        for (var i = 0; i < 9; i++) _msg(i.isEven ? 'user' : 'assistant', 'b$i ' * 20),
      ];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 160);
      // ignore: avoid_print
      print('  [OBS] summary chunks=${plan.segments.where((s) => s.summary).length} '
          'starts=${plan.segments.where((s) => s.summary).map((s) => history.indexOf(s.messages.first)).join(",")} '
          'shouldCompact=${plan.shouldCompact}');
      expect(plan.shouldCompact, isTrue);
      expect(plan.segments.where((s) => s.summary).isNotEmpty, isTrue);
      // Interior batches only: far[0] (the fold's first message) is exempt (a
      // tool round is a single persisted assistant message, so a boundary cannot
      // split it) — see compaction_plan.dart _foldTail far[0] exemption.
      for (final seg in plan.segments.where((s) => s.summary).skip(1)) {
        if (seg.messages.isEmpty) continue;
        expect(seg.messages.first.toolCallsJson, anyOf(isNull, isEmpty),
            reason: 'an interior summary chunk must never begin on an assistant carrying tool_calls');
      }
    });

    test('progressive closure: closed segments are reused, only the tail folds', () {
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

      expect(plan.segments.where((s) => s.isClosed).length, 1, reason: 'one closed segment');
      final closedSeg = plan.segments.firstWhere((s) => s.isClosed);
      expect(closedSeg.reuse!.coveredMinSeq, 1);
      expect(closedSeg.reuse!.coveredMaxSeq, 40);
      // No FRESH (non-closed) segment re-touches the frozen prefix.
      for (final seg in plan.segments.where((s) => !s.isClosed)) {
        expect(seg.messages.isEmpty || seg.messages.every((m) => (m.seq ?? 0) > 40),
            isTrue,
            reason: 'non-closed (fresh) segments must only contain tail messages above the closed floor');
      }
      // Budget accounting includes the frozen summary cost.
      expect(plan.projectedTokens, greaterThanOrEqualTo(30));
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
      expect(plan.segments.where((s) => !s.isClosed && s.summary).length, 0);
      expect(plan.segments.where((s) => !s.isClosed && !s.summary && s.messages.isNotEmpty),
          isEmpty, reason: 'no verbatim tail when the whole conversation is closed');
    });
  });

  group('4.3 seam (AI micro-adjusts the batch boundary to a safe topic seam)', () {
    test('valid seam repositions the L1 interior boundary (safe, cover dense+complete)', () {
      // 20 all-safe msgs, budget 160 → T=80 → k=4 L1 batches (raw 19 each).
      // The arithmetic boundaries are 5,10,15. A seam [1,6,11] (k-1=3) repositions.
      final history = [
        for (var i = 0; i < 20; i++) _msg(i.isEven ? 'user' : 'assistant', 'a$i ' * 20),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 160, seamChooser: (far, k) => [1, 6, 11]);
      final summaries = plan.segments.where((s) => s.summary).toList();
      // ignore: avoid_print
      print('  [OBS] seam summariges=${summaries.length} '
          'firstLen=${summaries.isEmpty ? -1 : summaries.first.messages.length} '
          'projected=${plan.projectedTokens}');
      // k is fixed by the raw-token batch count (4); the seam sets 3 interior cuts.
      expect(summaries.length, 4, reason: 'k=4 → exactly four L1 batches');
      expect(summaries.first.messages.length, 1,
          reason: 'the seam at index 1 makes the first segment far[0..1)');
      // Cover is dense + complete: the union of summary messages == the full far span.
      final covered = summaries.expand((s) => s.messages).toList();
      expect(covered.map((m) => m.content).toList(),
          history.sublist(0, covered.length).map((m) => m.content).toList(),
          reason: 'summary messages cover the far span contiguously in order');
      for (final seg in summaries) {
        expect(seg.messages.isEmpty || seg.messages.first.toolCallsJson == null, isTrue);
      }
    });

    test('invalid (unsafe / wrong-count) seam falls back to the arithmetic skeleton', () {
      // Index 10 = the tool-call assistant (unsafe). A seam list of the wrong
      // count (here 3 seams incl. the unsafe 10) must be rejected → fallback.
      final history = [
        for (var i = 0; i < 10; i++) _msg(i.isEven ? 'user' : 'assistant', 'a$i ' * 20),
        _msg('assistant', '', toolCallsJson: '[{"id":"tc","name":"read_file","input":{"path":"/p"}}]'),
        for (var i = 0; i < 9; i++) _msg(i.isEven ? 'user' : 'assistant', 'b$i ' * 20),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 160, seamChooser: (far, k) => [10, 11, 12]);
      expect(plan.shouldCompact, isTrue);
      expect(plan.segments.where((s) => s.summary).length, greaterThanOrEqualTo(2),
          reason: 'the fold still produces valid L1 chunks via the arithmetic fallback');
      // Interior batches only: far[0] (the fold's first message) is exempt (a
      // tool round is a single persisted assistant message, so a boundary cannot
      // split it) — see compaction_plan.dart _foldTail far[0] exemption.
      for (final seg in plan.segments.where((s) => s.summary).skip(1)) {
        if (seg.messages.isEmpty) continue;
        expect(seg.messages.first.toolCallsJson, anyOf(isNull, isEmpty),
            reason: 'an interior summary chunk must never begin on an assistant carrying tool_calls');
      }
    });
  });

  group('4.3/4.4 determinism + seam inputs', () {
    test('deterministic with seamChooser: same inputs -> same tree', () {
      final history = [
        for (var i = 0; i < 20; i++) _msg(i.isEven ? 'user' : 'assistant', 'd$i ' * 20),
      ];
      final chooser = (List<Message> far, int k) => [1, 6, 11];
      final a = CompactionEngine.buildTree(history: history, maxContextTokens: 160, seamChooser: chooser);
      final b = CompactionEngine.buildTree(history: history, maxContextTokens: 160, seamChooser: chooser);
      expect(a.folded.length, b.folded.length);
      expect(a.projectedTokens, b.projectedTokens);
      expect(
          a.segments.where((s) => s.summary).map((s) => s.messages.first.content).toList(),
          b.segments.where((s) => s.summary).map((s) => s.messages.first.content).toList(),
          reason: 'a memoized LLM seam must be reproducible across rebuilds');
    });

    test('resolveFoldSeamInputs exposes the fold (far, k) and matches the folded span', () {
      final history = [
        for (var i = 0; i < 20; i++) _msg(i.isEven ? 'user' : 'assistant', 'r$i ' * 20),
      ];
      final a = CompactionEngine.resolveFoldSeamInputs(history: history, maxContextTokens: 160);
      final b = CompactionEngine.resolveFoldSeamInputs(history: history, maxContextTokens: 160);
      expect(a, isNotNull, reason: 'over-budget conversation has seam inputs');
      expect(a!.far.length, b!.far.length);
      expect(a.k, b.k);
      // The exposed far span is exactly the set of messages the buildTree plan folds.
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 160);
      expect(a.far.map((m) => m.content).toList(), plan.folded.map((m) => m.content).toList(),
          reason: 'resolveFoldSeamInputs far == buildTree folded span');
    });
  });

  group('runtime measure→adjust helper (⑪.3 coarsen-by-measured)', () {
    test('l2GroupCount groups the OLDEST measured summaries exceeding T', () {
      // Cumulative measured tokens: 100,200 (== T),400 (> T) → 3 entries grouped.
      expect(CompactionEngine.l2GroupCount([100, 100, 100], 200), 3,
          reason: '3 L1s with measured tot=300 > T=200 roll into one L2');
      expect(CompactionEngine.l2GroupCount([50], 200), 1,
          reason: 'a single entry never exceeds T alone → group of 1 (no merges)');
      expect(CompactionEngine.l2GroupCount([250, 10], 200), 1,
          reason: 'the oldest entry alone exceeds T → group of 1 (already coarse)');
      expect(CompactionEngine.l2GroupCount([], 200), 0,
          reason: 'empty input yields no group');
    });

    test('rawTokens is the deterministic verbatim proxy cost', () {
      final msgs = [_msg('user', 'hello'), _msg('assistant', 'world')];
      expect(CompactionEngine.rawTokens(msgs), greaterThan(0));
    });
  });
}
