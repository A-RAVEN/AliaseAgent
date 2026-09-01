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

/// A message with a large, uniform raw proxy size (~755 tokens each): content
/// `'$i:' + 3000×'x'` → estimateTokens = (3003+3)~/4 = 751 + 4 overhead = 755.
/// Uniform so raw-token batch boundaries land deterministically (8×755 = 6040 >
/// 6000 = T) — needed to exercise the D5 seam dual guard, which is only meaningful
/// for LARGE batches (≥ the 1025 compressibility floor; a small budget's batches
/// are all < 1025 so a seam is always rejected — the design's small-conversation case).
Message _bigMsg(String role, int i) => _msg(role, '$i:${'x' * 3000}');

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
      // 30 all-safe msgs (~755 proxy each), budget 12000 → T=6000 → the newest
      // verbatim span stops at 7 msgs (7×755=5285 ≤ 6000) → far = msgs[0..23) →
      // k=3 (raw-token arithmetic boundaries [8,16]). The OLD deviation cut far at
      // the AI seam [1,6,11] (tiny first batch < the 1025 floor → bloat-omitted);
      // the D5 dual guard REJECTS that. A genuine micro-adjust seam [9,15] (within
      // half a batch of [8,16]) passes SIZE (all segments ≥ T~/2 = 3000) + ANCHOR
      // → the seam is KEPT (boundary moved to the nearest safe topic seam).
      final history = [
        for (var i = 0; i < 30; i++) _bigMsg(i.isEven ? 'user' : 'assistant', i),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 12000, seamChooser: (far, k) => [9, 15]);
      final summaries = plan.segments.where((s) => s.summary).toList();
      // ignore: avoid_print
      print('  [OBS] seam summaries=${summaries.length} '
          'firstLen=${summaries.isEmpty ? -1 : summaries.first.messages.length} '
          'projected=${plan.projectedTokens}');
      // k=3 (raw-token batching [8,16] → two interior cuts); a micro-adjust seam at
      // 9 sets the first segment to far[0..9) — the seam IS applied, not overwritten.
      expect(summaries.length, 3, reason: 'k=3 → exactly three L1 batches');
      expect(summaries.first.messages.length, 9,
          reason: 'the size+anchor-guarded seam at index 9 is kept (first batch = '
              'far[0..9)); a rejected seam would fall back to the arithmetic boundary '
              'at index 8 (first batch = 8 messages)');
      // Cover is dense + complete: the union of summary messages == the full far span.
      final covered = summaries.expand((s) => s.messages).toList();
      expect(covered.map((m) => m.content).toList(),
          history.sublist(0, covered.length).map((m) => m.content).toList(),
          reason: 'summary messages cover the far span contiguously in order');
      for (final seg in summaries) {
        expect(seg.messages.isEmpty || seg.messages.first.toolCallsJson == null, isTrue);
      }
    });

    test('size guard rejects a seam carving a tiny batch → arithmetic skeleton (keys stay large)', () {
      // Same far (23 msgs, k=3, arithmetic [8,16]) but a seam [11,13] punches a tiny
      // MIDDLE batch (far[11..13) = 2 msgs ~1510 raw < the 3000 size floor). It sits
      // within the anchor window of [8,16] (|11-8|=3, |13-16|=3 ≤ 3), so the SIZE
      // guard alone rejects it → the whole arithmetic skeleton is used. The first
      // batch is far[0..8) (~6040 raw > 1024) — the key-bearing batch stays large
      // and compressible, never a tiny independently-compressed (bloat-omitted) piece.
      final history = [
        for (var i = 0; i < 30; i++) _bigMsg(i.isEven ? 'user' : 'assistant', i),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 12000, seamChooser: (far, k) => [11, 13]);
      final summaries = plan.segments.where((s) => s.summary).toList();
      // ignore: avoid_print
      print('  [OBS] size-guard summaries=${summaries.length} '
          'firstLen=${summaries.isEmpty ? -1 : summaries.first.messages.length} '
          'firstRaw=${summaries.isEmpty ? 0 : CompactionEngine.rawTokens(summaries.first.messages)}');
      // The tiny-batch seam is rejected → the arithmetic boundary at index 8 is used.
      expect(summaries.first.messages.length, 8,
          reason: 'a seam carving a tiny batch (< the size floor) is rejected → the '
              'arithmetic boundary at index 8, not the seam at index 11');
      expect(CompactionEngine.rawTokens(summaries.first.messages), greaterThan(1024),
          reason: 'the key-bearing first batch stays > 1024 raw (compressible) — the '
              'tiny-seam split-if-invalid would otherwise have bloat-omitted it');
    });

    test('anchor guard rejects a seam that wholesale-reorders the batches → arithmetic skeleton', () {
      // Same far (23 msgs, k=3, arithmetic [8,16]). A seam [4,12] creates NO tiny
      // batch (segments 4/8/11 msgs, all ≥ the 3000 floor — so the size guard would
      // PASS), but it leaps ≥ 4 indices from the arithmetic boundaries (|4-8|=4,
      // |12-16|=4 > the anchor window 3) → a wholesale re-pack of the batch structure
      // (each seam-cut segment compressed separately again). The ANCHOR guard rejects
      // it → arithmetic skeleton → first batch far[0..8).
      final history = [
        for (var i = 0; i < 30; i++) _bigMsg(i.isEven ? 'user' : 'assistant', i),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 12000, seamChooser: (far, k) => [4, 12]);
      final summaries = plan.segments.where((s) => s.summary).toList();
      // ignore: avoid_print
      print('  [OBS] anchor-guard summaries=${summaries.length} '
          'firstLen=${summaries.isEmpty ? -1 : summaries.first.messages.length}');
      expect(summaries.first.messages.length, 8,
          reason: 'a seam that wholesale-reorders the batches (≥4 indices from the '
              'arithmetic boundary, no tiny batch) is rejected by the anchor guard → '
              'arithmetic boundary at index 8, not the seam at index 4');
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
        for (var i = 0; i < 30; i++) _bigMsg(i.isEven ? 'user' : 'assistant', i),
      ];
      // A genuine micro-adjust seam that PASSES the dual guard — so this asserts the
      // guarded seam is applied deterministically (not vacuous: the seam is actually
      // kept, exercising the seam path, not just the arithmetic fallback).
      final chooser = (List<Message> far, int k) => [9, 15];
      final a = CompactionEngine.buildTree(history: history, maxContextTokens: 12000, seamChooser: chooser);
      final b = CompactionEngine.buildTree(history: history, maxContextTokens: 12000, seamChooser: chooser);
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
