import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/context_estimator.dart';

/// Determinism contract of the proxy estimator: the same conversation always
/// yields the same projection (pure function of its input). This is what the
/// compaction design requires of the budget projection.
void main() {
  group('ContextEstimator.estimateTokens', () {
    test('empty text yields at least 1 token', () {
      expect(ContextEstimator.estimateTokens(''), 1);
    });

    test('same input always yields same output (pure function)', () {
      const text = 'The quick brown fox jumps over the lazy dog. @#\$% 中文文本';
      final a = ContextEstimator.estimateTokens(text);
      final b = ContextEstimator.estimateTokens(text);
      expect(a, b);
    });

    test('longer text yields >= as many tokens (monotonic)', () {
      final short = ContextEstimator.estimateTokens('hello');
      final long = ContextEstimator.estimateTokens(
          'hello world, this is a much longer string that should cost more tokens than a short one.');
      expect(long, greaterThan(short));
    });
  });

  group('ContextEstimator.estimateConversation determinism', () {
    test('same message list -> same total', () {
      final msgs = [
        Message(id: '1', sessionId: 's', role: 'user', content: 'Hello there', createdAt: 1),
        Message(id: '2', sessionId: 's', role: 'assistant', content: 'Hi! How can I help?', createdAt: 2),
        Message(
            id: '3',
            sessionId: 's',
            role: 'assistant',
            content: '',
            toolCallsJson:
                '[{"id":"tc1","toolName":"read_file","input":{"path":"/x"},"result":"body"}]',
            createdAt: 3),
      ];
      expect(ContextEstimator.estimateConversation([...msgs]),
          ContextEstimator.estimateConversation([...msgs]));
    });

    test('repeated runs over differently-ordered list still deterministic per list', () {
      final msgs = [
        Message(id: '1', sessionId: 's', role: 'user', content: 'A', createdAt: 1),
        Message(id: '2', sessionId: 's', role: 'user', content: 'B', createdAt: 2),
      ];
      for (var i = 0; i < 3; i++) {
        expect(
          ContextEstimator.estimateConversation(msgs),
          ContextEstimator.estimateConversation(msgs),
        );
      }
    });

    test('tool round adds overhead above a plain text message', () {
      final plain = Message(id: '1', sessionId: 's', role: 'assistant', content: 'x' * 20, createdAt: 1);
      final tool = Message(
          id: '2',
          sessionId: 's',
          role: 'assistant',
          content: 'x' * 20,
          toolCallsJson: '[{"id":"tc1","toolName":"read_file","input":{"path":"/x"}}]',
          createdAt: 2);
      expect(ContextEstimator.estimateMessage(tool),
          greaterThan(ContextEstimator.estimateMessage(plain)));
    });

    // hunks 只给界面画 diff，从不进入请求体；算进预算会让一次大编辑
    // 凭空抬高占用率、提前触发压缩。
    test('stored edit hunks do not change the estimate', () {
      final hunks = List.generate(
        200,
        (i) => '{"start_line":${i + 1},"old_text":"old line $i","new_text":"new line $i"}',
      ).join(',');
      final without = Message(
          id: '1',
          sessionId: 's',
          role: 'assistant',
          content: '',
          toolCallsJson:
              '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (1 replacement)"}]',
          createdAt: 1);
      final withHunks = Message(
          id: '2',
          sessionId: 's',
          role: 'assistant',
          content: '',
          toolCallsJson:
              '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (1 replacement)","hunks":[$hunks]}]',
          createdAt: 2);
      expect(ContextEstimator.estimateMessage(withHunks),
          ContextEstimator.estimateMessage(without));
    });

    test('the omission marker does not change the estimate either', () {
      final base =
          '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (3 replacements)"}]';
      final omitted =
          '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (3 replacements)","hunksOmitted":"too large"}]';
      expect(
        ContextEstimator.estimateMessage(
            Message(id: '1', sessionId: 's', role: 'assistant', content: '', toolCallsJson: omitted, createdAt: 1)),
        ContextEstimator.estimateMessage(
            Message(id: '2', sessionId: 's', role: 'assistant', content: '', toolCallsJson: base, createdAt: 2)),
      );
    });
  });
}
