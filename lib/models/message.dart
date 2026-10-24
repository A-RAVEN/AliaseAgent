import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

class Message {
  final String id;
  final int? seq; // stable per-session ordering key (monotonic; set at insert)
  final String sessionId;
  final String role; // 'user' or 'assistant'
  final String content;
  final String? toolCallsJson;
  final String? thinkingJson;
  final int? tokenCount;
  final int? outputTokenCount;
  final int createdAt;

  /// 这条消息带的图片附件，**只装绝对路径**（add-image-input）。
  ///
  /// 用户明确要求"历史先只存路径"，所以宽高 / 媒体类型 / 字节数一概不落库：
  /// 源文件被改名、移动或覆盖之后，那些数字只会撒谎。发请求与渲染时现读文件。
  /// 代价写在 `Docs/user-guide/chat.md` 的"限制"里。
  final List<String> attachments;

  const Message({
    required this.id,
    this.seq,
    required this.sessionId,
    required this.role,
    required this.content,
    this.toolCallsJson,
    this.thinkingJson,
    this.tokenCount,
    this.outputTokenCount,
    required this.createdAt,
    this.attachments = const [],
  });

  factory Message.fromRow(Map<String, dynamic> row) {
    return Message(
      id: row['id'] as String,
      seq: row['seq'] as int?,
      sessionId: row['session_id'] as String,
      role: row['role'] as String,
      content: row['content'] as String,
      toolCallsJson: row['tool_calls'] as String?,
      thinkingJson: row['thinking_json'] as String?,
      tokenCount: row['token_count'] as int?,
      outputTokenCount: row['output_token_count'] as int?,
      createdAt: row['created_at'] as int,
      attachments: _parseAttachments(row['attachments'], messageId: row['id'] as String?),
    );
  }

  /// 解析 `attachments` 列。
  ///
  /// NULL 或空串 → 空列表（正常情况：这条消息没有图）。坏 JSON、"不是数组"、
  /// 元素缺 `path` 或 `path` 为空 → 空列表 **加一行日志**。坏元素不逐条跳过：
  /// 跳过等于悄悄少发一张图，那正是本项目禁止的静默降级。
  static List<String> _parseAttachments(Object? raw, {String? messageId}) {
    if (raw == null) return const [];
    final text = raw is String ? raw : raw.toString();
    if (text.trim().isEmpty) return const [];

    final where = 'message ${messageId ?? '?'} 的 attachments 列';
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      debugPrint('[AliasAgent] $where 不是合法 JSON（${e.runtimeType}）— 按空附件处理');
      return const [];
    }
    if (decoded is! List) {
      debugPrint('[AliasAgent] $where 不是数组 — 按空附件处理');
      return const [];
    }
    final paths = <String>[];
    for (final element in decoded) {
      if (element is! Map) {
        debugPrint('[AliasAgent] $where 里有不是对象的元素 — 按空附件处理');
        return const [];
      }
      final path = element['path'];
      if (path is! String || path.trim().isEmpty) {
        debugPrint('[AliasAgent] $where 里有元素缺少非空的 path — 按空附件处理');
        return const [];
      }
      paths.add(path);
    }
    return List<String>.unmodifiable(paths);
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        if (seq != null) 'seq': seq,
        'session_id': sessionId,
        'role': role,
        'content': content,
        'tool_calls': toolCallsJson,
        'thinking_json': thinkingJson,
        'token_count': tokenCount,
        if (outputTokenCount != null) 'output_token_count': outputTokenCount,
        'created_at': createdAt,
        // 只写路径：`[{"path":"…"}]`。没有附件时写 NULL。
        'attachments': attachments.isEmpty
            ? null
            : jsonEncode(attachments.map((path) => {'path': path}).toList()),
      };
}