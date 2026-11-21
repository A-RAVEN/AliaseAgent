// `AgentCallbacks` → `agent.event` 的序列化适配（change `web-ui-core-shim` 任务 2.3 /
// design D9）。
//
// 分类处理（不新造事件类型/语义，只把既有模型转成线上的 JSON 形状）：
//   - ToolCallActivity / AgentMetering 已有 `toJson()` → 直接用；
//   - Message 只有 `toRow()`（DB 行形状）→ 这里写显式适配，契约是驼峰；
//     `tool_calls` / `thinking_json` 里的字符串尽量解码成 JSON，解码不了就把原始
//     字符串一并带上（`toolCallsRaw` / `thinkingRaw`），不静默丢内容；
//   - ContextSnapshot 只有 `toRawJson()`（缺 windowTokens / agentType / breakdown /
//     capturedAt）→ 这里补全，**breakdown 一定带 key**（没有时显式 null），不静默丢；
//   - CompactionStatus 没有序列化 → 这里显式适配（含 label/note，界面不用自己拼文案）。
import 'dart:convert';

import '../models/compaction_status.dart';
import '../models/context_breakdown.dart';
import '../models/message.dart';
import '../services/context_snapshot.dart';

/// Message → 对外 JSON（驼峰契约，不是 DB 行）。
Map<String, dynamic> serializeMessage(Message message) {
  final toolCalls = _tryDecode(message.toolCallsJson);
  final thinking = _tryDecode(message.thinkingJson);
  return <String, dynamic>{
    'id': message.id,
    'seq': message.seq,
    'sessionId': message.sessionId,
    'role': message.role,
    'content': message.content,
    'toolCalls': toolCalls,
    if (message.toolCallsJson != null && toolCalls == null)
      'toolCallsRaw': message.toolCallsJson,
    'thinking': thinking,
    if (message.thinkingJson != null && thinking == null)
      'thinkingRaw': message.thinkingJson,
    'tokenCount': message.tokenCount,
    'outputTokenCount': message.outputTokenCount,
    'createdAt': message.createdAt,
    'attachments': List<String>.unmodifiable(message.attachments),
  };
}

/// ContextSnapshot → 对外 JSON：占用环需要的窗口/拆分字段全部在（D9 硬要求）。
Map<String, dynamic> serializeContextSnapshot(ContextSnapshot snapshot) {
  return <String, dynamic>{
    ...snapshot.toRawJson(),
    'sessionId': snapshot.sessionId,
    'model': snapshot.model,
    'thinkingMode': snapshot.thinkingMode,
    'thinkingEffort': snapshot.thinkingEffort,
    'capturedAt': snapshot.capturedAt.toIso8601String(),
    'windowTokens': snapshot.windowTokens,
    'agentType': snapshot.agentType,
    // 没有拆分时也写 null：让客户端能区分"这一份快照没有环数据"与"服务端忘了带"。
    'breakdown': serializeBreakdown(snapshot.breakdown),
  };
}

/// 占用拆分 → 对外 JSON（含派生量，客户端不用自己算）。
Map<String, dynamic>? serializeBreakdown(ContextBreakdown? breakdown) {
  if (breakdown == null) return null;
  return <String, dynamic>{
    'level2Tokens': breakdown.level2Tokens,
    'level1Tokens': breakdown.level1Tokens,
    'rawTokens': breakdown.rawTokens,
    'fixedOverheadTokens': breakdown.fixedOverheadTokens,
    'windowTokens': breakdown.windowTokens,
    'usedTokens': breakdown.usedTokens,
    'conversationTokens': breakdown.conversationTokens,
  };
}

/// CompactionStatus → 对外 JSON（label/note 由核心给出，客户端不复制文案）。
Map<String, dynamic> serializeCompactionStatus(CompactionStatus status) {
  return <String, dynamic>{
    'stage': status.stage?.name,
    'segment': status.segment,
    'total': status.total,
    'background': status.background,
    'isIdle': status.isIdle,
    'label': status.label,
    'note': status.note,
  };
}

Object? _tryDecode(String? raw) {
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}
