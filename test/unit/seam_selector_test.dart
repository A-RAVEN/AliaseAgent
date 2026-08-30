import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';
import 'package:alias_agent/services/compaction/seam_selector.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../integration/helpers/fake_sidecar.dart';

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

AgentTypeConfig _config() => AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '',
      maxContextTokens: 200,
    );

ProviderResolver _resolver() => ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
      },
    ));

void main() {
  group('ModelSeamSelector', () {
    test('memo: a rebuild uses the cache and does NOT re-call the LLM', () async {
      final sidecar = FakeSidecar()..queueChunk('{"seams":[2]}')..queueDone();
      final sel = ModelSeamSelector(sidecar: sidecar, resolver: _resolver());
      final far = [
        for (var i = 0; i < 8; i++) _msg(i.isEven ? 'user' : 'assistant', 'm$i', seq: i + 1),
      ];
      await sel.ensure(far: far, k: 2, config: _config());
      expect(sel.llmCallCount, 1, reason: 'cold memo runs the seam LLM once');
      expect(sel.memoizedSeams(far: far, k: 2), isNotNull,
          reason: 'ensure populates the memo');

      // Rebuild with the SAME (far, k): memo is warm, the LLM is NOT re-called.
      await sel.ensure(far: far, k: 2, config: _config());
      expect(sel.llmCallCount, 1,
          reason: 'warm memo must not re-call the LLM (reproducible)');
      expect(sel.memoizedSeams(far: far, k: 2), [2]);
    });

    test('memo: content-hash key distinguishes different far spans', () async {
      // Two different far spans → two memo keys → the LLM is called for each (no
      // false memo hit across different content).
      final sidecar = FakeSidecar()
        ..queueChunk('{"seams":[2]}')..queueDone()
        ..queueChunk('{"seams":[3]}')..queueDone();
      final sel = ModelSeamSelector(sidecar: sidecar, resolver: _resolver());
      final farA = [
        for (var i = 0; i < 8; i++) _msg(i.isEven ? 'user' : 'assistant', 'aaa$i', seq: i + 1),
      ];
      final farB = [
        for (var i = 0; i < 8; i++) _msg(i.isEven ? 'user' : 'assistant', 'bbb$i', seq: i + 1),
      ];
      await sel.ensure(far: farA, k: 2, config: _config());
      await sel.ensure(far: farB, k: 2, config: _config());
      expect(sel.llmCallCount, 2,
          reason: 'different content is a different memo key (not a false hit)');
      expect(sel.memoizedSeams(far: farA, k: 2), [2]);
      expect(sel.memoizedSeams(far: farB, k: 2), [3]);
    });

    test('unparseable / invalid LLM response → empty memo → arithmetic fallback', () async {
      // The LLM returns garbage; ensure must tolerate it and cache an empty list
      // so buildTree deterministically falls back to the arithmetic skeleton.
      final sidecar = FakeSidecar()..queueChunk('not json at all')..queueDone();
      final sel = ModelSeamSelector(sidecar: sidecar, resolver: _resolver());
      final far = [
        for (var i = 0; i < 8; i++) _msg(i.isEven ? 'user' : 'assistant', 'g$i', seq: i + 1),
      ];
      await sel.ensure(far: far, k: 2, config: _config());
      expect(sel.llmCallCount, 1);
      expect(sel.memoizedSeams(far: far, k: 2), isEmpty,
          reason: 'a failed seam resolves to the empty skeleton fallback');
      // buildTree with a memo-backed chooser still produces valid (arithmetic)
      // segments — never a tool-round split.
      final history = [
        for (var i = 0; i < 20; i++) _msg(i.isEven ? 'user' : 'assistant', 'h$i ' * 20),
      ];
      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 160,
          seamChooser: (far2, k) => sel.memoizedSeams(far: far2, k: k) ?? const []);
      expect(plan.shouldCompact, isTrue);
      for (final seg in plan.segments.where((s) => s.summary).skip(1)) {
        expect(seg.messages.isEmpty || seg.messages.first.toolCallsJson == null, isTrue);
      }
    });

    test('FakeSeamSelector: llmCallCount counts cache-miss builds only (memo contract)', () async {
      final sel = FakeSeamSelector(fixedSeams: const [2]);
      final far = [
        for (var i = 0; i < 8; i++) _msg(i.isEven ? 'user' : 'assistant', 'f$i', seq: i + 1),
      ];
      await sel.ensure(far: far, k: 2, config: _config());
      expect(sel.llmCallCount, 1);
      // Rebuild with the same (far, k): warm memo → NOT a cache-miss call.
      await sel.ensure(far: far, k: 2, config: _config());
      expect(sel.llmCallCount, 1,
          reason: 'a rebuild reusing the memo must not re-count as a model call');
      expect(sel.memoizedSeams(far: far, k: 2), [2]);
    });

    test('4.3 end-to-end: memo-backed chooser preserves the LLM seam through buildTree', () async {
      // k=4 (raw-token batching) → the memo must expose k-1=3 seams. Return 3
      // seams; if the memoized seams were NOT preserved, the arithmetic barchers
      // (5,10,15) would be used and the first segment would be 4 messages, not 1.
      final sidecar = FakeSidecar()..queueChunk('{"seams":[1,6,11]}')..queueDone();
      final sel = ModelSeamSelector(sidecar: sidecar, resolver: _resolver());
      final history = [
        for (var i = 0; i < 20; i++) _msg(i.isEven ? 'user' : 'assistant', 's$i ' * 20),
      ];
      final seamInputs =
          CompactionEngine.resolveFoldSeamInputs(history: history, maxContextTokens: 160);
      expect(seamInputs, isNotNull);
      await sel.ensure(far: seamInputs!.far, k: seamInputs.k, config: _config());
      // ignore: avoid_print
      print('  [OBS] seamInputs.k=${seamInputs.k} farLen=${seamInputs.far.length} '
          'memoized=${sel.memoizedSeams(far: seamInputs.far, k: seamInputs.k)}');

      final plan = CompactionEngine.buildTree(
          history: history, maxContextTokens: 160,
          seamChooser: (far, k) => sel.memoizedSeams(far: far, k: k) ?? const []);
      final summaries = plan.segments.where((s) => s.summary).toList();
      // k=4 (raw-token batching) → four L1 batches; the memoized seam [1,6,11]
      // repositions the interior boundaries (first segment = far[0..1)).
      expect(summaries.length, 4, reason: 'k=4 → four L1 batches');
      expect(summaries.first.messages.length, 1,
          reason: 'the memoized LLM seam at index 1 is preserved (not overwritten by arithmetic)');
    });
  });
}
