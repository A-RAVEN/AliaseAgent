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

/// A message whose estimated raw size is exactly [rawPerMsg]:
/// `estimateMessage` = ceil(len/4) + 4, so len = (rawPerMsg - 4) * 4 - 3.
/// Batch geometry depends on the per-message raw size, so tests that assert
/// "which span got folded" pin it here instead of using a magic length.
Message _msgOfRaw(String role, int rawPerMsg) =>
    _msg(role, 'A' * ((rawPerMsg - 4) * 4 - 3));

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
          history: history, maxContextTokens: 24000, seamChooser: (far, k) => [9, 15]);
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
          history: history, maxContextTokens: 24000, seamChooser: (far, k) => [11, 13]);
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
      // 2026-09-20 重新取参数：阈值改成"容量的 25%"之后，原来那组参数（容量 12000）
      // 算出的远端是 28 条、每批 4 条，锚点窗口 = 28 ~/ (2×7) = 2，而尺寸守卫又要求
      // 每段 ≥ 阈值一半 —— 两者在这组几何下互相覆盖，锚点守卫没有单独咬合的余地
      // （位移超过半批，就必然有一段小于半批）。这里换一组能让它**单独**咬合的参数：
      //   每条 755 raw；容量 24160 ⇒ 阈值 = 6040 ⇒ 每批 9 条（8 条 = 6040 并未超过阈值，
      //   第 9 条才超过）⇒ 远端 18 条 = 两批，算术分界在 [9]；尺寸下限 = 3020 = 4 条。
      //   锚点窗口 = 18 ~/ (2×2) = 4。
      // 接缝给在第 14 条：距算术分界 |14 − 9| = 5 > 4 ⇒ 锚点守卫拒；而两段分别是
      // 14 条（10570 raw）与 4 条（3020 raw），都 ≥ 尺寸下限 3020 ⇒ **尺寸守卫放行**。
      // 也就是说这一条确实是靠锚点守卫拦下来的，不是被尺寸守卫顺带拦掉。
      final history = [
        for (var i = 0; i < 24; i++) _bigMsg(i.isEven ? 'user' : 'assistant', i),
      ];
      // 先把前提验掉：接缝切出来的两段都不小于尺寸下限 ⇒ 尺寸守卫本来会放行，
      // 所以这一条只能是被锚点守卫拦下的。（不然"锚点守卫拦住了"就只是我的声称。）
      final inputs = CompactionEngine.resolveFoldSeamInputs(
          history: history, maxContextTokens: 24160);
      final floor = CompactionEngine.thresholdTokens(24160, 25) ~/ 2;
      expect(inputs, isNotNull);
      expect(inputs!.far.length, 18, reason: '前提：远端是 18 条');
      final seamFirst = CompactionEngine.rawTokens(inputs.far.sublist(0, 14));
      final seamSecond = CompactionEngine.rawTokens(inputs.far.sublist(14));
      // ignore: avoid_print
      print('  [OBS] anchor-guard 前提: 尺寸下限=$floor '
          '接缝第一段=$seamFirst 接缝第二段=$seamSecond '
          '（两段都 ≥ 下限 ⇒ 尺寸守卫放行，只剩锚点守卫能拦）');
      expect(seamFirst, greaterThanOrEqualTo(floor),
          reason: '前提：接缝第一段不小于尺寸下限 ⇒ 尺寸守卫会放行');
      expect(seamSecond, greaterThanOrEqualTo(floor),
          reason: '前提：接缝第二段不小于尺寸下限 ⇒ 尺寸守卫会放行');
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 24160, seamChooser: (far, k) => [14]);
      final summaries = plan.segments.where((s) => s.summary).toList();
      final firstRaw =
          summaries.isEmpty ? 0 : CompactionEngine.rawTokens(summaries.first.messages);
      // ignore: avoid_print
      print('  [OBS] anchor-guard 批数=${summaries.length} '
          'firstLen=${summaries.isEmpty ? -1 : summaries.first.messages.length} '
          'firstRaw=$firstRaw '
          '(阈值=${CompactionEngine.thresholdTokens(24160, 25)}；接缝 14 条 = 10570 raw、'
          '余下 4 条 = 3020 raw，两者都 ≥ 尺寸下限 3020；锚点窗口 4 < 位移 5)');
      expect(summaries.length, 2, reason: '远端 18 条切成两批');
      expect(summaries.first.messages.length, 9,
          reason: '被锚点守卫拒 ⇒ 回退到算术骨架的第 9 条；若被接受则是接缝的第 14 条');
      expect(firstRaw, 9 * 755,
          reason: '回退到算术骨架后首批是 9 条 6795 raw（接缝那条是 14 条 10570 raw）');
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
      final a = CompactionEngine.buildTree(history: history, maxContextTokens: 24000, seamChooser: chooser);
      final b = CompactionEngine.buildTree(history: history, maxContextTokens: 24000, seamChooser: chooser);
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

  // 阈值只认 token 的规则要落到"到底压哪一段"上。规则是：**从最旧开始累加，
  // 每累计超过阈值就切出一批，一直切到剩下不足一个阈值为止**；切出来的批压成
  // 摘要，剩下那一截原样发送。而旧写法是"从最新往回保留到不超过阈值、其余全压"，
  // 方向正好相反：总量刚过阈值时它只压最旧的一小截（不到阈值），那一小截小到
  // 压不动，合成出来的摘要不会更小、于是被整体丢掉。
  // 批次不能被切得小到压不动。这个"多大才算压得动"的下限也必须是**算出来的**，
  // 不许写死：它就是阈值的一半。写死一个绝对数（1025）的后果是——窗口小一点
  // （阈值小于 2050）时，下限就顶到 1025，凡是"半批"落在阈值一半到 1025 之间的
  // 接缝一律被拒，挑分界那套机制在小窗口下彻底失效。
  group('可压缩下限由阈值派生（不写死绝对数）', () {
    test('阈值一半落在 600～1025 之间的接缝仍被接受', () {
      // 每条 100 raw；容量 4800 ⇒ 阈值 = 1200 ⇒ 下限 = 600（写死的旧下限是 1025）。
      // 从最旧按阈值切：13 条 = 1300 > 1200 ⇒ 第一、二批；剩 10 条 = 1000 < 1200
      // ⇒ 远端 26 条、末段原文 10 条。算术骨架只在第 13 条处有一个分界。
      final history = [
        for (var i = 0; i < 36; i++) _msgOfRaw(i.isEven ? 'user' : 'assistant', 100),
      ];
      // 接缝给在第 9 条：切成 9 条（900 raw）+ 17 条（1700 raw）。
      // 900 落在「阈值一半 600」到「写死的 1025」之间 —— 这正是被旧下限一刀切掉的
      // 那一段。锚点窗口 = 26 ~/ (2×2) = 6，|9 − 13| = 4 ≤ 6，锚点守卫放行，
      // 所以能拦住它的只有尺寸守卫。
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 4800, seamChooser: (far, k) => [9]);
      final summaries = plan.segments.where((s) => s.summary).toList();
      final firstLen = summaries.isEmpty ? -1 : summaries.first.messages.length;
      final firstRaw =
          summaries.isEmpty ? 0 : CompactionEngine.rawTokens(summaries.first.messages);
      // ignore: avoid_print
      print('  [OBS] 小窗口接缝: 阈值=${CompactionEngine.thresholdTokens(4800, 25)} '
          '批数=${summaries.length} 首批条数=$firstLen 首批raw=$firstRaw '
          '（接缝落在第 9 条 ⇒ 首批应 9 条 900 raw；被旧下限拒则回退到第 13 条 1300 raw）');
      expect(summaries.length, 2, reason: '远端切成两批');
      expect(firstLen, 9,
          reason: '接缝被尺寸守卫接受 ⇒ 首批就是接缝切出来的 9 条；'
              '若那个写死的 1025 下限还在，这里会回退成算术骨架的 13 条');
      expect(firstRaw, 900);
    });
  });

  // 已经压过的段落，"压过的原文不再重压"这条不变；变的是：一条层级 1 的摘要
  // **仍然可以被拿去合成更粗的摘要**（不再一落盘就冻结），而层级 2 的永远不参与。
  group('可参与合成的是层级 1（不改变"已覆盖"的语义）', () {
    test('可参与合成的层级 1 摘要仍然算已覆盖：不会因此多压一遍原文', () {
      final old = [
        for (var i = 1; i <= 40; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'old$i ' * 20, seq: i),
      ];
      final recent = [
        for (var i = 41; i <= 46; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'recent$i ' * 20, seq: i),
      ];
      final history = [...old, ...recent];
      final closed = [
        const ClosedSummary(level: 1, coveredMinSeq: 1, coveredMaxSeq: 40, tokenCost: 30),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 200, closed: closed);
      final fresh = plan.segments.where((s) => !s.isClosed).toList();
      // ignore: avoid_print
      print('  [OBS] 可参与合成: 已载入条目=${plan.segments.where((s) => s.isClosed).length} '
          '其中可参与合成=${plan.segments.where((s) => s.isClosed && s.rollable).length} '
          '新压批次=${fresh.where((s) => s.summary).length} '
          '新压批次覆盖的最大 seq=${fresh.where((s) => s.summary).expand((s) => s.messages).fold<int>(0, (m, x) => (x.seq ?? 0) > m ? (x.seq ?? 0) : m)}');
      expect(plan.segments.where((s) => s.isClosed && s.rollable).length, 1,
          reason: '层级 1 的已落盘摘要标记为可参与合成');
      for (final seg in fresh) {
        expect(seg.messages.every((m) => (m.seq ?? 0) > 40), isTrue,
            reason: '已被覆盖的原文（seq ≤ 40）绝不再压一遍 —— 可参与合成不等于重新压原文');
      }
      expect(
          plan.segments.where((s) =>
              !s.isClosed &&
              s.summary &&
              s.messages.any((m) => (m.seq ?? 0) <= 40)),
          isEmpty,
          reason: '新压的批次里没有任何一条包含已被覆盖的原文（已落盘那条摘要本身不算）');
      expect(fresh.where((s) => s.summary), isNotEmpty,
          reason: '尾部自己就超过了阈值（容量 200 ⇒ 阈值 50），所以照常压');
    });

    test('层级 2 的已落盘摘要不可参与合成（只做两级）', () {
      final history = [
        for (var i = 1; i <= 20; i++)
          _msg(i.isEven ? 'assistant' : 'user', 'old$i ' * 20, seq: i),
      ];
      final closed = [
        const ClosedSummary(level: 2, coveredMinSeq: 1, coveredMaxSeq: 20, tokenCost: 40),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 200, closed: closed);
      expect(plan.segments.where((s) => s.isClosed && s.rollable), isEmpty,
          reason: '层级 2 永远不再作为合成的输入');
    });
  });

  group('切分方向：压掉的是一整批阈值，留下的一截不足阈值', () {    test('总量略大于阈值 ⇒ 被压的那批 ≈ 阈值，留下的原文 < 阈值', () {
      // 每条 100 raw；13 条 = 1300 raw；容量 4000 ⇒ 阈值 = 1000。
      final history = [
        for (var i = 0; i < 13; i++) _msgOfRaw(i.isEven ? 'user' : 'assistant', 100),
      ];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 4000);
      final foldedRaw = CompactionEngine.rawTokens(plan.folded);
      final verbatimRaw = CompactionEngine.rawTokens(plan.verbatim);
      // ignore: avoid_print
      print('  [OBS] 略超阈值: foldedRaw=$foldedRaw verbatimRaw=$verbatimRaw '
          '(阈值 1000，总量 1300)');
      expect(plan.shouldCompact, isTrue);
      // 压掉的是最旧的一整批（约一个阈值），不是"总量 − 阈值"（那是旧写法：
      // 只压最旧的 300 raw）。
      expect(foldedRaw, greaterThanOrEqualTo(1000),
          reason: '被压的那批要达到一个阈值（约 1000），不是"总量 − 阈值 = 300"');
      expect(foldedRaw, lessThanOrEqualTo(1100),
          reason: '被压的那批不超过阈值加一条消息（切在首次超过阈值处）');
      expect(verbatimRaw, lessThan(1000),
          reason: '留下的原文不足一个阈值');
    });

    test('总量是阈值的 3.5 倍 ⇒ 切出 3 批 ≈ 3 个阈值，留下的原文 < 阈值', () {
      // 每条 100 raw；35 条 = 3500 raw；容量 4000 ⇒ 阈值 = 1000。
      final history = [
        for (var i = 0; i < 35; i++) _msgOfRaw(i.isEven ? 'user' : 'assistant', 100),
      ];
      final plan = CompactionEngine.buildTree(history: history, maxContextTokens: 4000);
      final summaries = plan.segments.where((s) => s.summary).toList();
      final foldedRaw = CompactionEngine.rawTokens(plan.folded);
      final verbatimRaw = CompactionEngine.rawTokens(plan.verbatim);
      // ignore: avoid_print
      print('  [OBS] 3.5 倍阈值: 批数=${summaries.length} foldedRaw=$foldedRaw '
          'verbatimRaw=$verbatimRaw (阈值 1000，总量 3500)');
      // 多批必须还在：远端"只有一批"就意味着"按阈值切批"这条规则被做成了
      // "只切一次"，那套"由 AI 挑选批次分界"的机制会因此永远不执行。
      expect(summaries.length, 3,
          reason: '3.5 个阈值 ⇒ 切出 3 批（每批约一个阈值），剩下半个阈值原样发送');
      expect(foldedRaw, greaterThanOrEqualTo(3000),
          reason: '被压的是 3 个阈值的量（旧写法只压 2500）');
      expect(verbatimRaw, lessThan(1000),
          reason: '留下的原文不足一个阈值');
      expect(verbatimRaw, greaterThan(0),
          reason: '还有半截没到阈值，必须原样发送（不是全压掉）');
    });
  });

  group('runtime measure→adjust helper (⑪.3 coarsen-by-measured)', () {
    test('l2GroupCount groups the OLDEST measured summaries exceeding T', () {
      // Cumulative measured tokens: 100,200 (== T),400 (> T) → 3 entries grouped.
      expect(CompactionEngine.l2GroupCount([100, 100, 100], 200), 3,
          reason: '3 L1s with measured tot=300 > T=200 roll into one L2');
      expect(CompactionEngine.l2GroupCount([250, 10], 200), 1,
          reason: 'the oldest entry alone exceeds T → group of 1 (already coarse)');
      expect(CompactionEngine.l2GroupCount([], 200), 0,
          reason: 'empty input yields no group');
    });

    test('l2GroupCount returns 0 when the accumulated total never exceeds T', () {
      // 阈值是唯一判据：累加没超过阈值就是"不成组"，返回 0 —— 不再拿"有几条"
      // 当替代判据（改之前这里返回的是条数本身）。
      // ignore: avoid_print
      print('  [OBS] l2GroupCount([10,10], 50)='
          '${CompactionEngine.l2GroupCount([10, 10], 50)} '
          'l2GroupCount([30,30], 50)=${CompactionEngine.l2GroupCount([30, 30], 50)} '
          'l2GroupCount([50], 200)=${CompactionEngine.l2GroupCount([50], 200)}');
      expect(CompactionEngine.l2GroupCount([10, 10], 50), 0,
          reason: '两条各 10、阈值 50 ⇒ 累加 20 始终没超过 50 ⇒ 不成组（0）');
      expect(CompactionEngine.l2GroupCount([50], 200), 0,
          reason: '一条 50、阈值 200 ⇒ 没超过 ⇒ 不成组（0）；改之前返回 1，'
              '与"真的超过阈值才成组"无法区分');
      expect(CompactionEngine.l2GroupCount([30, 30], 50), 2,
          reason: '两条各 30、阈值 50 ⇒ 累加到第二条首次超过 50 ⇒ 这一组 2 条');
    });

    test('rawTokens is the deterministic verbatim proxy cost', () {
      final msgs = [_msg('user', 'hello'), _msg('assistant', 'world')];
      expect(CompactionEngine.rawTokens(msgs), greaterThan(0));
    });
  });

  // 阈值就是「模型能装下的上下文总量 × 配置里的百分比 ÷ 100」。它必须**算出来**，
  // 不许写死；换一个大窗口的模型，阈值要跟着变大。
  group('thresholdTokens (阈值只由一个百分比派生)', () {
    test('threshold follows the configured percentage (default 25, explicit 50)', () {
      // 100 万 token 的窗口：按缺省 25% 算 = 25 万；显式写 50% 算 = 50 万。
      expect(CompactionEngine.thresholdTokens(1000000, null), 250000,
          reason: '缺省百分比 25 ⇒ 阈值 = 100万 × 25 ÷ 100');
      expect(CompactionEngine.thresholdTokens(1000000, 50), 500000,
          reason: '显式 50% ⇒ 阈值 = 100万 × 50 ÷ 100');
      expect(CompactionEngine.thresholdTokens(200000, 10), 20000,
          reason: '小窗口同样按比例算：20万 × 10 ÷ 100');
    });

    test('doubling the model window doubles the threshold, and L1 batch count does not grow', () {
      // 同一份历史，只把模型容量翻倍：阈值必须跟着翻倍。
      // ignore: avoid_print
      print('  [OBS] threshold 20000*25%=${CompactionEngine.thresholdTokens(20000, 25)} '
          '40000*25%=${CompactionEngine.thresholdTokens(40000, 25)}');
      expect(CompactionEngine.thresholdTokens(40000, 25),
          2 * CompactionEngine.thresholdTokens(20000, 25),
          reason: '容量翻倍 ⇒ 阈值翻倍');

      // 同一份长历史：容量翻倍后，远端被切成的 L1 批数不得变多（阈值与远端同步变大）。
      final history = [
        for (var i = 0; i < 80; i++) _bigMsg(i.isEven ? 'user' : 'assistant', i),
      ];
      final small = CompactionEngine.buildTree(history: history, maxContextTokens: 20000);
      final large = CompactionEngine.buildTree(history: history, maxContextTokens: 40000);
      final smallSegs = small.segments.where((s) => s.summary).toList();
      final largeSegs = large.segments.where((s) => s.summary).toList();
      // 每条大消息约 755 raw。批次是在「累计首次超过阈值」处切开的，所以第一批的
      // raw 必然落在「阈值」到「阈值 + 一条消息」之间 —— 拿它直接量阈值有没有翻倍。
      const msgRaw = 755;
      const slack = msgRaw + 1;
      final smallFirst = CompactionEngine.rawTokens(smallSegs.first.messages);
      final largeFirst = CompactionEngine.rawTokens(largeSegs.first.messages);
      // ignore: avoid_print
      print('  [OBS] batchCount capacity20000=${smallSegs.length} capacity40000=${largeSegs.length} '
          'firstBatchRaw small=$smallFirst large=$largeFirst '
          '(阈值 5000 / 10000)');
      expect(smallSegs.length, greaterThanOrEqualTo(2),
          reason: '前提：小容量下远端确实被切成多条 L1 批次（否则下面两条是空转）');
      expect(smallFirst, greaterThan(CompactionEngine.thresholdTokens(20000, 25)),
          reason: '第一批 raw 超过 25%×20000=5000 才切开');
      expect(smallFirst,
          lessThanOrEqualTo(CompactionEngine.thresholdTokens(20000, 25) + slack),
          reason: '第一批 raw 不超过阈值加一条消息');
      expect(largeFirst, greaterThan(CompactionEngine.thresholdTokens(40000, 25)),
          reason: '容量翻倍后第一批 raw 超过 25%×40000=10000 —— 阈值真的跟着容量走了');
      expect(largeFirst,
          lessThanOrEqualTo(CompactionEngine.thresholdTokens(40000, 25) + slack),
          reason: '第一批 raw 不超过阈值加一条消息');
      expect(largeSegs.length, lessThanOrEqualTo(smallSegs.length),
          reason: '容量翻倍、阈值同步翻倍 ⇒ L1 批数不变多');
    });
  });
}
