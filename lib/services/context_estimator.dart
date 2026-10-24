import 'dart:convert';

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
  /// 每 token 多少字符。
  ///
  /// **2026-10-18 试过改成 3.4，撤回了**：校准用例第一次测出服务端 2083 / 估算 1769
  /// （比值 1.1775），但同一条用例再跑就变成 35（系统提示词本身就 1676 token，35 不可能
  /// 是这次对话请求的用量）—— 说明"读助手消息的 token_count"这个观测通道不可信，
  /// 一条不可信的读数不能拿来做全局常量。等通道可靠、样本够多再谈。详见 tasks 13.3。
  static const int _charsPerToken = 4;
  // Structural overhead per message / block, conservative.
  static const int _messageOverhead = 4;
  static const int _toolRoundOverhead = 8;
  static const int _thinkingOverhead = 4;

  /// 每张图片按多少 token 计入预算。
  ///
  /// 出处：`Docs/DeepSeekAPIDoc.md` §6.4.6「每张图片消耗的 token 数存在上限（1024 个）」。
  /// 取**上限**而不是按像素估算，是因为预算宁可高估也不能低估：低估会让压缩阈值在真的
  /// 超限之后才触发。`Docs/DeepSeekAPIDoc.md` §6.2 末尾另有一段"像素÷1650"的估算式
  /// （本项目反推 + 实测校准），那是给界面显示估算值用的，不用于预算。
  static const int kImageTokens = 1024;

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
      t += estimateTokens(_withoutEditHunks(m.toolCallsJson!)) +
          _toolRoundOverhead;
      // 工具轮里带回来的图片（`read_image`）：库里只存路径，正文一个字节都没进
      // 这个 JSON，所以按张数补计；一张图会真的以 base64 进请求。
      t += _countToolImages(m.toolCallsJson!) * kImageTokens;
    }
    if (m.thinkingJson != null && m.thinkingJson!.isNotEmpty) {
      t += estimateTokens(m.thinkingJson!) + _thinkingOverhead;
    }
    // 用户消息带的图（贴进来的）：同理，库里只有路径。
    t += m.attachments.length * kImageTokens;
    return t;
  }

  /// 数一条消息的 `tool_calls` JSON 里有多少个工具调用带了 `image`。
  ///
  /// 先看字符串里有没有 `"image"` 再解码 —— 绝大多数工具轮没有图，不该为它们
  /// 付一次 JSON 解析的开销。解不动就返回 0（少算图片比抛异常好，且下面是估算）。
  static int _countToolImages(String toolCallsJson) {
    if (!toolCallsJson.contains('"image"')) return 0;
    try {
      final decoded = jsonDecode(toolCallsJson);
      if (decoded is! List) return 0;
      var count = 0;
      for (final entry in decoded) {
        if (entry is Map && entry['image'] != null) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 估一份 **API 格式**的消息数组（`apiMessages` 那种，已经是可以直接发出去的形状）。
  ///
  /// 图片块里的 base64 正文**不计入**：它不是文本，模型那边也不是按字符数算钱。
  /// 每张图统一按 [kImageTokens] 计。不这么处理的话，一张 1MB 的截图光 base64 就
  /// 会被估成 25 万 token，占用环直接爆表。
  static int estimateApiMessages(List<Map<String, dynamic>> messages) {
    var images = 0;
    final stripped = <Map<String, dynamic>>[];
    for (final message in messages) {
      final content = message['content'];
      if (content is! List) {
        stripped.add(message);
        continue;
      }
      final blocks = <Object?>[];
      for (final block in content) {
        if (block is Map && block['type'] == 'image') {
          images++;
          blocks.add(<String, dynamic>{'type': 'image'});
        } else {
          // `hunks` / `hunksOmitted` 只给界面画 diff，从不进入请求体。这条路径上
          // 出现的它们多半来自持久化残留，算进预算会把"没发出去的东西"计入占用率。
          blocks.add(block is Map ? _withoutEditHunksDeep(block) : block);
        }
      }
      stripped.add({...message, 'content': blocks});
    }
    return estimateTokens(jsonEncode(stripped)) + images * kImageTokens;
  }

  /// 递归去掉 `hunks` / `hunksOmitted`（值类型不确定，所以要下钻）。
  static Object? _withoutEditHunksDeep(Object? node) {
    if (node is List) return node.map(_withoutEditHunksDeep).toList();
    if (node is Map) {
      final copy = <String, dynamic>{};
      for (final entry in node.entries) {
        final key = entry.key.toString();
        if (key == 'hunks' || key == 'hunksOmitted') continue;
        copy[key] = _withoutEditHunksDeep(entry.value);
      }
      return copy;
    }
    return node;
  }

  /// 去掉工具活动里的 `hunks` / `hunksOmitted` 再估。
  ///
  /// 这两个字段只给界面画 diff 用，从不进入任何一次请求体（`_buildApiMessages`
  /// 只取 type/id/name/input），按它们计数就是把"没发出去的东西"算进预算，
  /// 会让一次大编辑凭空抬高占用率、提前触发压缩。
  ///
  /// 解析失败时按原样返回：宁可多算一点，也不把真实的工具活动漏掉。
  static String _withoutEditHunks(String toolCallsJson) {
    if (!toolCallsJson.contains('"hunks')) return toolCallsJson;
    try {
      final decoded = jsonDecode(toolCallsJson);
      if (decoded is! List) return toolCallsJson;
      var stripped = false;
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          if (entry.remove('hunks') != null) stripped = true;
          if (entry.remove('hunksOmitted') != null) stripped = true;
        }
      }
      return stripped ? jsonEncode(decoded) : toolCallsJson;
    } catch (_) {
      return toolCallsJson;
    }
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
