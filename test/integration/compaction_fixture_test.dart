import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';

import 'helpers/real_context_fixture.dart';

/// A-1 fixture offline verification (default-run, pure/deterministic — no live
/// model): proves the fixture actually satisfies its own constraints so A-2 (the
/// live quality test) is measuring a real fold, not a luck-of-the-draw one.
///
/// Constraints verified:
/// ① the load-bearing re-execution keys live in the foldable far band (not the
///    newest verbatim chunk, not omit-oldest);
/// ② the conversation produces ≥1 foldable segment (over budget);
/// ③ it contains ≥1 real tool round (`read_file` with the absolute path input).
void main() {
  const budget = 200; // mirrors A-2's chosen budget

  test('A-1 fixture: keys in foldable far band + ≥1 L1 segment + ≥1 tool round', () {
    final fixture = buildConfigRefactorConversation();
    final curSeq = (fixture.last.seq ?? 0) + 1;
    final history = [
      ...fixture,
      Message(
        id: 'm_current',
        seq: curSeq,
        sessionId: 's1',
        role: 'user',
        content: '请继续。',
        createdAt: curSeq,
      ),
    ];

    final plan = CompactionEngine.buildTree(history: history, maxContextTokens: budget);
    final foldedText = plan.folded.map((m) => m.content).join('\n');
    final verbatimText = plan.verbatim.map((m) => m.content).join('\n');
    // ignore: avoid_print
    print('  [OBS] fixture: totalMsgs=${history.length} '
        'shouldCompact=${plan.shouldCompact} '
        'farMsgs=${plan.folded.length} nearMsgs=${plan.verbatim.length} '
        'farHasPath=${foldedText.contains(kConfigPath)} '
        'nearHasPath=${verbatimText.contains(kConfigPath)}');
    expect(plan.shouldCompact, isTrue,
        reason: 'A-1 ② the fixture must be over budget → ≥1 foldable L1 segment');
    expect(plan.folded, isNotEmpty, reason: 'A-1 ② a non-empty far span to fold');
    expect(foldedText, contains(kConfigPath),
        reason: 'A-1 ① the absolute-path key must be in the foldable far band');
    expect(foldedText, contains(kDecisionNew),
        reason: 'A-1 ① the decision value must be in the foldable far band');
    expect(verbatimText, isNot(contains(kConfigPath)),
        reason: 'A-1 ① the path must NOT be in the newest verbatim chunk (else no summary touches it)');

    // A-1 ③ ≥1 real tool round in the folded span: an assistant message carrying
    // tool_calls whose input carries the absolute path (a re-execution key).
    final toolRounds = plan.folded
        .where((m) => m.role == 'assistant' && (m.toolCallsJson ?? '').isNotEmpty)
        .toList();
    expect(toolRounds, isNotEmpty, reason: 'A-1 ③ the fixture must contain ≥1 real tool round');
    final readCalls = toolRounds.where((m) => (m.toolCallsJson ?? '').contains('read_file'));
    // ignore: avoid_print
    print('  [OBS] fixture tool-rounds in far=${toolRounds.length} '
        'read_fileCalls=${readCalls.length}');
    expect(readCalls, isNotEmpty,
        reason: 'A-1 ③ the tool round must be read_file (the re-execution key tool)');
    final inputHasPath = readCalls.any((m) {
      try {
        final calls = jsonDecode(m.toolCallsJson!) as List<dynamic>;
        return calls.any((c) =>
            ((c as Map<String, dynamic>)['input'] as Map<String, dynamic>?)?['path'] ==
            kConfigPath);
      } catch (_) {
        return false;
      }
    });
    expect(inputHasPath, isTrue,
        reason: 'A-1 ③ the read_file tool round must carry the absolute path in its input');
  });
}
