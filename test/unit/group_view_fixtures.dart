// 视图投影测试的共用夹具（change `agent-group-chat` §3）。
//
// 只造"产品流程会造出来的形状"：用户 public 行（author NULL）、成员 public 最终行
// （只有正文）、成员 private 行（thinking / tool_calls 证据）。不手工造字段缺失或
// 角色错乱的行 —— 那些状态产品不会产生（CLAUDE.md 的"谁会产生这个状态"）。
import 'dart:convert';

import 'package:alias_agent/models/message.dart';

const String kGroupId = 'group-1';

/// 用户公开消息。
Message userRow(int seq, String content) => Message(
      id: 'u-$seq',
      seq: seq,
      sessionId: kGroupId,
      role: 'user',
      content: content,
      createdAt: seq,
    );

/// 成员的**公开最终行**：按 D1 只存正文（tool_calls / thinking_json 都是 NULL）。
Message publicRow(int seq, String memberId, String content) => Message(
      id: 'pub-$seq-$memberId',
      seq: seq,
      sessionId: kGroupId,
      role: 'assistant',
      content: content,
      author: memberId,
      createdAt: seq,
    );

/// 成员的**私有工具轮行**：thinking + tool_calls（含结果）都在这一行的私有证据里。
Message privateToolRow(
  int seq,
  String memberId, {
  required String thinking,
  required String toolName,
  required Map<String, dynamic> input,
  required String result,
  String toolId = 'tool-1',
}) {
  final calls = [
    {
      'id': toolId,
      'type': 'tool_use',
      'name': toolName,
      'toolName': toolName,
      'input': input,
      'result': result,
    }
  ];
  return Message(
    id: 'priv-$seq-$memberId',
    seq: seq,
    sessionId: kGroupId,
    role: 'assistant',
    content: '',
    author: memberId,
    visibility: Message.visibilityPrivateToAuthor,
    thinkingJson: jsonEncode([
      {'type': 'thinking', 'thinking': thinking, 'signature': 'sig-$seq'}
    ]),
    toolCallsJson: jsonEncode(calls),
    createdAt: seq,
  );
}

/// 成员的私有行（只有 thinking，没有工具）。
Message privateThinkingRow(int seq, String memberId, String thinking) => Message(
      id: 'priv-think-$seq-$memberId',
      seq: seq,
      sessionId: kGroupId,
      role: 'assistant',
      content: '',
      author: memberId,
      visibility: Message.visibilityPrivateToAuthor,
      thinkingJson: jsonEncode([
        {'type': 'thinking', 'thinking': thinking, 'signature': 'sig-$seq'}
      ]),
      createdAt: seq,
    );

/// 成员 id → 显示名（含已移除成员：历史行一直要有归属）。
const Map<String, String> kNames = {
  'member-a': '甲',
  'member-b': '乙',
  'member-removed': '丙',
};
