import '../models/message.dart';

/// Deterministic local proxy estimator used to project the next request's input
/// token count for the compaction budget. It is a *proxy* — its absolute value
/// is calibrated against measured provider usage (token_count) — but it is a
/// pure function of its input, so the same conversation always yields the same
/// projection (determinism contract required by the compaction design).
///
/// It is NOT a tokenizer; it is a heuristic: ~4 chars per token plus a small
/// structural overhead per message / content block. Only monotonicity and
/// determinism are guaranteed, not accuracy (accuracy is validated by the
/// break-even regression in Phase 4).
class ContextEstimator {
  static const int _charsPerToken = 4;
  // Structural overhead per message / block, conservative.
  static const int _messageOverhead = 4;
  static const int _toolRoundOverhead = 8;
  static const int _thinkingOverhead = 4;

  /// Estimate tokens for a single string of text.
  static int estimateTokens(String text) {
    if (text.isEmpty) return 1;
    return (text.length + _charsPerToken - 1) ~/ _charsPerToken;
  }

  /// Estimate the proxy token cost of one persisted Message.
  static int estimateMessage(Message m) {
    var t = estimateTokens(m.content) + _messageOverhead;
    if (m.toolCallsJson != null && m.toolCallsJson!.isNotEmpty) {
      // Tool round overhead: the round + its synthetic tool_result user message.
      t += estimateTokens(m.toolCallsJson!) + _toolRoundOverhead;
    }
    if (m.thinkingJson != null && m.thinkingJson!.isNotEmpty) {
      t += estimateTokens(m.thinkingJson!) + _thinkingOverhead;
    }
    return t;
  }

  /// Estimate the proxy token cost of a whole persisted conversation.
  static int estimateConversation(List<Message> messages) {
    var total = 0;
    for (final m in messages) {
      total += estimateMessage(m);
    }
    return total;
  }
}
