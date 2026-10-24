import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../context_estimator.dart';
import '../provider_resolver.dart';
import '../sidecar_bridge.dart';
import '../../models/agent_type_config.dart';
import '../../models/message.dart';
import 'summary_provider.dart';
import 'summary_reference.dart';

/// Summary instruction appended as the final user message of a summarization
/// request. Ask for a structured, lossless-enough summary: keep the decision
/// chain, tool inputs (re-execution keys / absolute paths), and outcomes; no
/// fabricated thinking/tool_use blocks (the model only writes text).
const String kSummarizeInstruction =
    '请把上面的对话总结成一段供未来模型轮次使用的摘要。必须保留：'
    '(1) 用户的总体目标与约束；(2) 每个决定及其推理；(3) 每次工具调用的名称与输入'
    '（包括绝对文件路径——这些是再执行钥匙）；(4) 每个工具结果的成功/失败结论；'
    '(5) 创建或修改过的工作区/文件；(6) 任何「不要动 X」类的硬性不变量。'
    '务必一字不差地保留每一个绝对路径/再执行钥匙——无论它出现在工具调用的 input 里，'
    '还是对话正文里，都要原样写下，绝不改写、概括或丢弃路径。'
    '请用与对话正文相同的语言输出摘要（对话主要是中文就用中文，主要是英文就用英文）。'
    '只输出纯文本：不要 thinking 块、不要 tool_use 块、不要 tool_result 块。精简但完整。';

/// 参考上下文的抬头：这一段只用来解析指代与判断"什么已经说过了"，不许被总结。
const String kReferenceContextHeader = '【参考上下文 · 不要总结】';

/// 待压缩原文的抬头（只在这次带了参考上下文时才出现）。
const String kSummarizeTextHeader = '【待压缩原文 · 只总结这一段】';

/// 没有参考上下文时用的 system —— **与过去逐字相同**。
const String kSummarySystemPrompt =
    '你是 AliasAgent 的对话摘要器。请忠实、精简地用纯文本总结此前的对话。'
    '请用与对话正文相同的语言输出摘要。';

/// 带了参考上下文时追加到 system 后面的禁令句（追加，不替换 —— 上面那两句必须留着）。
const String kReferenceOnlyProhibition =
    '用户消息里会给你一段【参考上下文】和一段【待压缩原文】：参考上下文只用来解析指代、'
    '判断什么已经说过了，严禁把它的内容写进摘要；摘要只写【待压缩原文】里的信息。';

/// 摘要正文偶尔会把渲染用的角色前缀抄进开头（2026-10-03 实测：5 条一级摘要里 3 条以
/// `ASSISTANT` / `ASSISTANT:` 开头）。这里只削掉这一种形态，不动正文本身：
///   `ASSISTANT: 用户目标…` → `用户目标…`；`ASSISTANT本次…` → `本次…`
/// 两种会被保留的情形：英文正文以 `ASSISTANT ` 开头（后面是空格 + 英文，属于正常措辞）、
/// 以及标签出现在正文中间（只削开头）。
String stripLeadingRoleLabel(String text) {
  final withColon = RegExp(r'^\s*(?:USER|ASSISTANT|SYSTEM)\s*[:：]\s*').firstMatch(text);
  if (withColon != null) return text.substring(withColon.end);
  final glued = RegExp(r'^\s*(?:USER|ASSISTANT|SYSTEM)(?=[\u4e00-\u9fff])').firstMatch(text);
  if (glued != null) return text.substring(glued.end);
  return text;
}

/// The production [SummaryProvider]: routes a summarization request through the
/// model gateway on the summary profile (thinking disabled; the request carries NO
/// max_tokens — the output length is the model/endpoint default; see the "summary"
/// mode in model_gateway.cpp), collecting the output text.
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
    List<SummaryReference> reference = const [],
  }) async {
    final provider = _resolver.resolve(config.provider);
    if (provider == null) {
      // R1-5: never silently replace the folded context with a placeholder. A
      // missing provider is a hard error → the caller's _callModel provider guard
      // (main.dart) short-circuits before the fold, but belt-and-suspenders: throw
      // so it falls back to sending the conversation verbatim, never a placeholder.
      throw StateError('provider "${config.provider}" not found — cannot summarize');
    }

    final apiKey = provider.apiKey;
    final baseUrl = provider.baseUrl;

    // Build the conversation to summarize: folded messages (oldest → newest) as
    // plain role-qualified transcript + the summarize instruction. Tool rounds
    // are represented inline (assistant tool_use + derived user tool_result) so
    // the model sees a coherent alternation and the re-execution keys.
    //
    // With a reference context (design D2) the request gets TWO extra pieces, and
    // both are load-bearing: the reference travels as its own message with its own
    // header (so the model can tell "background" from "what to summarize"), and the
    // text-to-summarize gets a header too. Without a reference the request is
    // exactly what it always was — same system, same messages, no headers.
    final summaryMessages = <Map<String, dynamic>>[];
    if (reference.isEmpty) {
      for (final m in folded) {
        summaryMessages.add({'role': m.role, 'content': _messageText(m)});
        if (m.role == 'assistant' && m.toolCallsJson != null && m.toolCallsJson!.isNotEmpty) {
          // Synthetic user(tool_result) round, inlined: tool name + input + result.
          summaryMessages.add({'role': 'user', 'content': _toolRoundText(m)});
        }
      }
    } else {
      summaryMessages.add({'role': 'user', 'content': _referenceBlock(reference)});
      final buf = StringBuffer()..writeln(kSummarizeTextHeader);
      for (final m in folded) {
        buf.writeln(_messageText(m));
        if (m.role == 'assistant' && m.toolCallsJson != null && m.toolCallsJson!.isNotEmpty) {
          buf.writeln(_toolRoundText(m));
        }
      }
      summaryMessages.add({'role': 'user', 'content': buf.toString().trimRight()});
    }
    summaryMessages.add({'role': 'user', 'content': kSummarizeInstruction});

    var text = StringBuffer();
    int doneCode = 0;
    String doneErr = '';
    // Real measured usage from the summary call (Anthropic-format /v1/messages
    // input_tokens/output_tokens). The summary's SIZE is the provider's actual
    // output_tokens — NOT an estimate (no compression-ratio assumption, D3/D4);
    // the INPUT count is observation only (what this call cost to send), never a
    // validity criterion.
    int outTokens = 0;
    int inTokens = 0;
    await _sidecar.sendMessage(
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: config.model,
      systemPrompt: reference.isEmpty
          ? kSummarySystemPrompt
          : kSummarySystemPrompt + kReferenceOnlyProhibition,
      messagesJson: jsonEncode(summaryMessages),
      toolsJson: '[]',
      thinkingMode: 'summary', // summary profile: thinking disabled, no max_tokens sent
      thinkingEffort: '',
      onChunk: (t) => text.write(t),
      onToolCall: (_) {}, // never expected on a summary profile
      onDone: (code, err, stop, inTok, outTok) {
        doneCode = code;
        doneErr = err ?? '';
        outTokens = outTok ?? 0;
        inTokens = inTok ?? 0;
      },
    );
    // Per-call observability (never model-visible): what this summarization call
    // cost to SEND, next to what it produced. Printed even when the call failed,
    // so a failing call's spend stays attributable.
    debugPrint('[OBS] summary in=$inTokens/out=$outTokens (level-1 fold)');

    // A failed summarization must NOT silently replace the folded context with a
    // placeholder. Surface the failure so the caller falls back to sending the
    // full conversation verbatim (no worse than pre-compaction).
    if (doneCode != 0) {
      throw StateError('Summarization failed (code=$doneCode): ${doneErr.isEmpty ? 'unknown' : doneErr}');
    }
    final content = stripLeadingRoleLabel(text.toString().trim());
    if (content.isEmpty) {
      // R1-5: a SUCCESSFUL (code==0) but EMPTY summary must NOT silently become the
      // "(empty summary)" placeholder — that would replace the folded context with
      // garbage. Throw so the caller's _callModel catch falls back to sending the
      // conversation verbatim (never a silent placeholder). This closes the
      // done==0 + empty-content gap in the R1-5 fix, which only handled done!=0.
      throw StateError('Summarization returned empty content (code=0, no text)');
    }
    // 图片被压掉时要说出来（add-image-input 10.3）：摘要只发纯文本，原来那几张图
    // 一个都没进摘要。不点名就是静默降级；点名并给出恢复路径（本地数据库 +
    // 「真实上下文」那一屏）才算"砍内容可见、可见之后可恢复"。
    final foldedImages = _countImages(folded);
    final withImageNote = foldedImages == 0
        ? content
        : '$content\n\n（本段另有 $foldedImages 张图片，已随原文压缩省略；'
            '原始记录仍在本地数据库，可用「真实上下文」查看）';
    return SummaryResult(
      text: withImageNote,
      // Real measured size; if the provider didn't report usage (0), fall back to
      // a deterministic tokenizer estimate so the budget check still has a size.
      // 注意：`outTokens` 是模型实测的输出量，**不含**上面追加的这句图片说明
      // （它是本地拼的）。这几百字节的量级与"实测 vs 估算"的口径差异不能混，
      // 所以只在没有实测值时用估算。
      tokens: outTokens > 0 ? outTokens : ContextEstimator.estimateTokens(withImageNote),
      inputTokens: inTokens,
    );
  }

  /// 数一批被折叠消息里有多少张图：用户消息的 `attachments` 加上工具轮里的 `image`。
  static int _countImages(List<Message> folded) {
    var count = 0;
    for (final m in folded) {
      count += m.attachments.length;
      final toolCalls = m.toolCallsJson;
      if (toolCalls != null && toolCalls.contains('"image"')) {
        try {
          final decoded = jsonDecode(toolCalls);
          if (decoded is List) {
            for (final entry in decoded) {
              if (entry is Map && entry['image'] != null) count++;
            }
          }
        } catch (_) {
          // 解不动就当没有图：这里只影响一句提示文字，不该让摘要失败
        }
      }
    }
    return count;
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    final provider = _resolver.resolve(config.provider);
    if (provider == null) {
      // R1-5: never a silent placeholder (see summarize).
      throw StateError('provider "${config.provider}" not found — cannot summarize');
    }

    // 2-pass "summary of summaries": the input is the joined level-1 summary
    // texts. Send it as a single user message + the summarize instruction on the
    // summary profile (thinking disabled; no max_tokens sent).
    final summaryMessages = <Map<String, dynamic>>[
      {'role': 'user', 'content': '$text\n\n$kSummarizeInstruction'},
    ];

    var out = StringBuffer();
    int doneCode = 0;
    String doneErr = '';
    int outTokens = 0;
    int inTokens = 0;
    await _sidecar.sendMessage(
      apiKey: provider.apiKey,
      baseUrl: provider.baseUrl,
      model: config.model,
      systemPrompt:
          '你是 AliasAgent 的对话摘要器。请忠实、精简地用纯文本总结提供的这些摘要。'
          '请用与对话正文相同的语言输出摘要。',
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
        inTokens = inTok ?? 0;
      },
    );
    debugPrint('[OBS] summary in=$inTokens/out=$outTokens (level-2 roll-up)');
    if (doneCode != 0) {
      throw StateError(
          'level-2 summarization failed (code=$doneCode): ${doneErr.isEmpty ? 'unknown' : doneErr}');
    }
    final content = stripLeadingRoleLabel(out.toString().trim());
    if (content.isEmpty) {
      // R1-5: never a silent "(empty summary)" placeholder (see summarize).
      throw StateError('level-2 summarization returned empty content (code=0, no text)');
    }
    return SummaryResult(
      text: content,
      // Real measured size (no compression-ratio estimate).
      tokens: outTokens > 0 ? outTokens : ContextEstimator.estimateTokens(content),
      inputTokens: inTokens,
    );
  }

  /// Render the reference context as its own message body: header + one block per
  /// carried summary, each block labelled with the sequence range it covers (so the
  /// model can judge whether that reference is really "before" the batch).
  static String _referenceBlock(List<SummaryReference> reference) {
    final buf = StringBuffer()..writeln(kReferenceContextHeader);
    for (final r in reference) {
      buf.writeln('[第 ${r.coveredMinSeq}..${r.coveredMaxSeq} 段摘要（层级 ${r.level}）]');
      buf.writeln(r.text);
    }
    return buf.toString().trimRight();
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

  /// 记录**每一次** summarize 收到的参考上下文（按调用顺序），用来断言"参考真的
  /// 从 main.dart 一路传到了 provider"—— 只测挑选函数是测不到接线的。
  final List<List<SummaryReference>> referencesPerCall = [];

  /// 最近一次 summarize 收到的参考。
  List<SummaryReference> get lastReference =>
      referencesPerCall.isEmpty ? const [] : referencesPerCall.last;

  /// Records the joined level-1 texts passed into the 2-pass summarizeText.
  String? lastSummarizeText;

  /// Count of summarizeText (2-pass) calls made.
  int summarizeTextCalls = 0;

  FakeSummaryProvider({this.text = '前文摘要:用户要求读取文件并完成分析。'});

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
  }) async {
    lastFolded = List.of(folded);
    referencesPerCall.add(List.of(reference));
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
