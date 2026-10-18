import 'package:alias_agent/models/context_breakdown.dart';

/// A frozen, deep-copied snapshot of the exact context handed to the model
/// gateway on one main-conversation request.
///
/// Captured right before `_sidecar.sendMessage(...)` in `_callModel`, at the
/// point where `systemPrompt` / `messages` / `toolsJson` and the request
/// parameters (`model` / `thinkingMode` / `thinkingEffort`) are all in scope.
/// `messages` is a deep copy (re-decoded from the `messagesJson` string that is
/// actually transmitted), so later in-place `.add` growth of the live
/// `apiMessages` in the tool loop never mutates an existing snapshot.
///
/// Pure data — no side effects, no live references.
class ContextSnapshot {
  final String sessionId;
  final String systemPrompt;
  final List<Map<String, dynamic>> messages;
  final String toolsJson;
  final String model;
  final String thinkingMode;
  final String thinkingEffort;
  final DateTime capturedAt;

  /// 这一份请求的占用拆分（二级摘要 / 一级摘要 / 原文 + 固定开销）。
  ///
  /// 与快照在**同一次** `setState` 里写入，所以它和上面那几个字段描述的是同一份请求；
  /// 为 `null` 时环不渲染（没有拆分就没有环）。**它不是请求的一部分**，因此
  /// [toRawJson] 里没有它 —— 「真实上下文」那一屏的原始 JSON 保持原样。
  final ContextBreakdown? breakdown;

  const ContextSnapshot({
    required this.sessionId,
    required this.systemPrompt,
    required this.messages,
    required this.toolsJson,
    required this.model,
    required this.thinkingMode,
    required this.thinkingEffort,
    required this.capturedAt,
    this.breakdown,
  });

  /// Header label shown in the context view so the user can tell which session
  /// a retained snapshot belongs to (see design D6 / task 1.4 — a session switch
  /// retains the last snapshot and labels it, rather than clearing it).
  String get sessionLabel => 'snapshot for session=$sessionId';

  /// The full raw-JSON form (system + messages + tools) offered as copyable text
  /// in the view (task 2.7).
  Map<String, dynamic> toRawJson() => {
        'system': systemPrompt,
        'messages': messages,
        'tools': toolsJson,
      };
}
