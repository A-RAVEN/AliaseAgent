import 'dart:convert';

import '../context_estimator.dart';
import '../provider_resolver.dart';
import '../sidecar_bridge.dart';
import '../../models/agent_type_config.dart';
import '../../models/message.dart';
import 'summary_provider.dart';

/// Summary instruction appended as the final user message of a summarization
/// request. Ask for a structured, lossless-enough summary: keep the decision
/// chain, tool inputs (re-execution keys / absolute paths), and outcomes; no
/// fabricated thinking/tool_use blocks (the model only writes text).
const String kSummarizeInstruction =
    'Summarize the above conversation for a future model turn. Preserve: (1) the '
    'user\'s goals and constraints, (2) each decision and its reasoning, (3) every '
    'tool call\'s name + input (including absolute file paths — these are '
    're-execution keys), (4) each tool result\'s outcome, (5) workspaces/files created or '
    'modified, and (6) any explicit "do not touch X" invariants. Output plain text — '
    'no thinking blocks, no tool_use blocks, no tool_result blocks. Be dense but complete.';

/// The production [SummaryProvider]: routes a summarization request through the
/// model gateway on the summary profile (thinking disabled, max_tokens 1024 —
/// the "summary" mode handled in model_gateway.cpp), collecting the output text.
class ModelSummaryProvider implements SummaryProvider {
  final ISidecar _sidecar;
  final ProviderResolver _resolver;

  ModelSummaryProvider({
    required ISidecar sidecar,
    required ProviderResolver resolver,
  })  : _sidecar = sidecar,
        _resolver = resolver;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    final provider = _resolver.resolve(config.provider);
    if (provider == null) {
      // No provider → cannot summarize; return a deterministic placeholding
      // summary so the pipeline still runs (callers can detect the low info).
      return SummaryResult(text: '(could not summarize: provider "${config.provider}" not found)', tokens: 20);
    }

    final apiKey = provider.apiKey;
    final baseUrl = provider.baseUrl;

    // Build the conversation to summarize: folded messages (oldest → newest) as
    // plain role-qualified transcript + the summarize instruction. Tool rounds
    // are represented inline (assistant tool_use + derived user tool_result) so
    // the model sees a coherent alternation and the re-execution keys.
    final summaryMessages = <Map<String, dynamic>>[];
    for (final m in folded) {
      summaryMessages.add({'role': m.role, 'content': _messageText(m)});
      if (m.role == 'assistant' && m.toolCallsJson != null && m.toolCallsJson!.isNotEmpty) {
        // Synthetic user(tool_result) round, inlined: tool name + input + result.
        summaryMessages.add({'role': 'user', 'content': _toolRoundText(m)});
      }
    }
    summaryMessages.add({'role': 'user', 'content': kSummarizeInstruction});

    var text = StringBuffer();
    int doneCode = 0;
    String doneErr = '';
    // Real measured usage from the summary call (Anthropic-format /v1/messages
    // input_tokens/output_tokens). The summary's SIZE is the provider's actual
    // output_tokens — NOT an estimate (no compression-ratio assumption, D3/D4).
    int outTokens = 0;
    await _sidecar.sendMessage(
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: config.model,
      systemPrompt:
          'You are a conversation summarizer for AliasAgent. Produce a faithful, '
          'dense plain-text summary of the earlier conversation.',
      messagesJson: jsonEncode(summaryMessages),
      toolsJson: '[]',
      thinkingMode: 'summary', // summary profile: thinking disabled, max_tokens 1024
      thinkingEffort: '',
      onChunk: (t) => text.write(t),
      onToolCall: (_) {}, // never expected on a summary profile
      onDone: (code, err, stop, inTok, outTok) {
        doneCode = code;
        doneErr = err ?? '';
        outTokens = outTok ?? 0;
      },
    );

    // A failed summarization must NOT silently replace the folded context with a
    // placeholder. Surface the failure so the caller falls back to sending the
    // full conversation verbatim (no worse than pre-compaction).
    if (doneCode != 0) {
      throw StateError('Summarization failed (code=$doneCode): ${doneErr.isEmpty ? 'unknown' : doneErr}');
    }
    final content = text.toString().trim();
    return SummaryResult(
      text: content.isEmpty ? '(empty summary)' : content,
      // Real measured size; if the provider didn't report usage (0), fall back to
      // a deterministic tokenizer estimate so the budget check still has a size.
      tokens: outTokens > 0 ? outTokens : ContextEstimator.estimateTokens(content),
    );
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    final provider = _resolver.resolve(config.provider);
    if (provider == null) {
      return SummaryResult(
          text: '(could not summarize: provider "${config.provider}" not found)',
          tokens: 20);
    }

    // 2-pass "summary of summaries": the input is the joined level-1 summary
    // texts. Send it as a single user message + the summarize instruction on the
    // summary profile (thinking disabled, max_tokens 1024).
    final summaryMessages = <Map<String, dynamic>>[
      {'role': 'user', 'content': '$text\n\n$kSummarizeInstruction'},
    ];

    var out = StringBuffer();
    int doneCode = 0;
    String doneErr = '';
    int outTokens = 0;
    await _sidecar.sendMessage(
      apiKey: provider.apiKey,
      baseUrl: provider.baseUrl,
      model: config.model,
      systemPrompt:
          'You are a conversation summarizer for AliasAgent. Produce a faithful, '
          'dense plain-text summary of the provided summaries.',
      messagesJson: jsonEncode(summaryMessages),
      toolsJson: '[]',
      thinkingMode: 'summary',
      thinkingEffort: '',
      onChunk: (t) => out.write(t),
      onToolCall: (_) {},
      onDone: (code, err, stop, inTok, outTok) {
        doneCode = code;
        doneErr = err ?? '';
        outTokens = outTok ?? 0;
      },
    );
    if (doneCode != 0) {
      throw StateError(
          'level-2 summarization failed (code=$doneCode): ${doneErr.isEmpty ? 'unknown' : doneErr}');
    }
    final content = out.toString().trim();
    return SummaryResult(
      text: content.isEmpty ? '(empty summary)' : content,
      // Real measured size (no compression-ratio estimate).
      tokens: outTokens > 0 ? outTokens : ContextEstimator.estimateTokens(content),
    );
  }

  /// Render a message's content for the summarizer (plain text transcript).
  static String _messageText(Message m) {
    final buf = StringBuffer();
    buf.write('${m.role.toUpperCase()}: ${m.content}');
    if (m.thinkingJson != null && m.thinkingJson!.isNotEmpty) {
      buf.write('\n[thinking]\n${m.thinkingJson}');
    }
    return buf.toString();
  }

  /// Render an assistant tool round (its tool_use + result payload) inline.
  static String _toolRoundText(Message m) {
    final buf = StringBuffer();
    buf.write('[tool round]\n');
    try {
      final calls = jsonDecode(m.toolCallsJson!) as List<dynamic>;
      for (final c in calls) {
        final tc = c as Map<String, dynamic>;
        final name = tc['toolName'] ?? tc['name'] ?? '?';
        final input = tc['input'] ?? {};
        final result = tc['result'] ?? tc['resultPreview'] ?? '';
        buf.write('- $name<input=${jsonEncode(input)}> -> $result\n');
      }
    } catch (e) {
      buf.write('[unparseable tool_calls json]\n');
    }
    return buf.toString();
  }
}

/// A deterministic fake for tests: returns a fixed summary without any I/O so
/// the fold plan/projection can be asserted without a live model.
class FakeSummaryProvider implements SummaryProvider {
  String text;

  /// Records the folded span passed in (for assertions).
  List<Message>? lastFolded;

  /// Records the joined level-1 texts passed into the 2-pass summarizeText.
  String? lastSummarizeText;

  /// Count of summarizeText (2-pass) calls made.
  int summarizeTextCalls = 0;

  FakeSummaryProvider({this.text = '前文摘要:用户要求读取文件并完成分析。'});

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    lastFolded = List.of(folded);
    return SummaryResult(text: text, tokens: ContextEstimator.estimateTokens(text));
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    summarizeTextCalls++;
    lastSummarizeText = text;
    return SummaryResult(text: text, tokens: ContextEstimator.estimateTokens(text));
  }
}
