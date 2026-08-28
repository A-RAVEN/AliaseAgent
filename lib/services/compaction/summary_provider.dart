import '../../models/agent_type_config.dart';
import '../../models/message.dart';

/// Result of a summarization request.
class SummaryResult {
  /// The compressed summary content. Plain text only — no synthesized
  /// thinking/tool_use/tool_result content blocks (spec: compressed output is
  /// plain text). A leading marker is prepended by the caller so the provider
  /// stays free of presentation concerns.
  final String text;

  /// Proxy token cost the provider reports (for budget accounting).
  final int tokens;

  const SummaryResult({required this.text, required this.tokens});
}

/// The execution side of the decision/execution split: buildTree decides WHICH
/// messages fold; a SummaryProvider fills the content of the chosen leaf.
///
/// The real implementation ([ModelSummaryProvider]) routes through the model
/// gateway on the summary profile (thinking disabled, max_tokens 512-1024).
/// Tests inject a [FakeSummaryProvider] so the fold plan (which is already
/// deterministic) can be asserted without a live model.
abstract class SummaryProvider {
  /// Produce a summary over [folded] (oldest → newest). The summary is plain
  /// role:user text; the caller prepends the "earlier context" marker.
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  });
}

/// Marker prepended to a summary message so it is clearly non-user speech.
const String kSummaryMarker = '## 更早上下文(压缩xN,非用户发言)';

/// Build the role:user plain-text summary message content from a provider
/// result + the number of folded messages.
String buildSummaryContent({required SummaryResult result, required int foldedCount}) {
  return '$kSummaryMarker\n\n${result.text}';
}
