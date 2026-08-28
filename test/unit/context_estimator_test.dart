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
  });
}
