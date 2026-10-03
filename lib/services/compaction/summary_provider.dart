import '../../models/agent_type_config.dart';
import '../../models/message.dart';
import 'summary_reference.dart';

/// Result of a summarization request.
class SummaryResult {
  /// The compressed summary content. Plain text only — no synthesized
  /// thinking/tool_use/tool_result content blocks (spec: compressed output is
  /// plain text). A leading marker is prepended by the caller so the provider
  /// stays free of presentation concerns.
  final String text;

  /// Proxy token cost the provider reports (for budget accounting).
  final int tokens;

  /// The summarization call's measured INPUT token count (from the same
  /// `/v1/messages` usage block that supplies [tokens]). Observation only: it
  /// never decides whether a summary is valid — that is still [tokens] (the
  /// measured output size).
  final int inputTokens;

  const SummaryResult({required this.text, required this.tokens, this.inputTokens = 0});
}

/// The execution side of the decision/execution split: buildTree decides WHICH
/// messages fold; a SummaryProvider fills the content of the chosen leaf.
///
/// The real implementation ([ModelSummaryProvider]) routes through the model
/// gateway on the summary profile (thinking disabled; the request carries NO
/// max_tokens, so the output length is the model/endpoint default).
/// Tests inject a [FakeSummaryProvider] so the fold plan (which is already
/// deterministic) can be asserted without a live model.
abstract class SummaryProvider {
  /// Produce a summary over [folded] (oldest → newest). The summary is plain
  /// role:user text; the caller prepends the "earlier context" marker.
  ///
  /// [reference] is the optional reference context (at most two already-persisted
  /// summaries that end before this batch). When it is empty the request is exactly
  /// what it has always been; when it is non-empty the reference and the text to be
  /// summarized travel as separate messages with their own headers.
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
  });

  /// Produce a 2-pass "summary of summaries": summarize the already-produced
  /// [text] (the joined level-1 summary texts) into a coarser level-2 summary.
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  });
}

/// Marker prepended to a level-1 summary message so it is clearly non-user
/// speech.
const String kSummaryMarker = '## 更早上下文(压缩xN,非用户发言)';

/// Marker prepended to a level-2 "summary of summaries" message.
const String kLevel2SummaryMarker = '## 更早上下文(压缩xN,层级2,非用户发言)';

/// Build the role:user plain-text summary message content from a provider
/// result + the number of folded messages. [level] (1 or 2) selects the marker.
String buildSummaryContent({
  required SummaryResult result,
  required int foldedCount,
  int level = 1,
}) {
  final marker = level >= 2 ? kLevel2SummaryMarker : kSummaryMarker;
  return '$marker\n\n${result.text}';
}
