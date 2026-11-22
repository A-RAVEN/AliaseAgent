// 逐成员视图投影（change `agent-group-chat` 任务 3.1~3.6 / design D2）。
//
// 这是成员模型拿到上下文的**唯一出口**：对同一份原文序列做「可见性过滤 + 主客体
// 映射」，产出该成员的视图序列（`List<Message>`，**保留原始 seq**）。视图再交给
// `api_message_builder.dart` 装配成请求体（与单会话共用同一份 replay 实现）。
//
// 映射规则（spec「逐成员视图投影是唯一出口」）：
//   用户消息（author 空、public）      → user 轮，原样
//   自己的公开回复（author = X）       → assistant 轮，第一人称，不带「X 说：」
//   自己的私有活动（private-to-author）→ 原样保留（replay 时变成 assistant(thinking+
//                                       tool_use) + 合成 user(tool_result)）
//   其他成员 Y 的公开回复              → user 轮 + 正文前缀「Y 说：」
//   其他成员的私有活动                 → **整体剔除**，不以任何形式出现
//
// 「归属只能进文本」：Anthropic 的 MessageParam 只有 role/content；本文件产出的
// 合成行也只有 role/content（`buildApiMessages` 不会给任何消息加 `name`）。
//
// 连续同角色轮**不修补**：两个他人公开回复相邻就是两条 user 轮，不插填充、不改 role、
// 不造空 text 块（spec「连续同角色直接交给接口」）。
import '../models/message.dart';
import 'api_message_builder.dart';
import 'logging.dart';

/// 一个成员的投影视图。
class GroupMemberView {
  const GroupMemberView._(this.messages, this.memberId);

  /// 视图序列（按 seq 升序；他人公开回复是合成 user 行）。
  final List<Message> messages;

  final String memberId;

  /// 视图里出现的 seq 集合（驻留视图；派生缓存的生命周期按它淘汰）。
  Set<int> get residentSeqs => {
        for (final message in messages)
          if (message.seq != null) message.seq!,
      };

  /// 装配成实际请求体（与单会话共用 `buildApiMessages`）。
  List<Map<String, dynamic>> apiMessages({
    required bool acceptsImages,
    required String model,
  }) =>
      buildApiMessages(messages, acceptsImages: acceptsImages, model: model);

  /// 视图里的全部正文（隐私断言用：搜标记，不解析结构）。
  String get textContent => messages.map((m) => m.content).join('\n');
}

class GroupViewProjection {
  /// 结构探针：投影函数被调用的次数。
  ///
  /// 唯一出口守卫（3.6）用它证明"成员请求的 messages 由投影产出"：装配一次成员视图
  /// 必须恰好让它 +1，且产出与本函数的结果逐项相同。
  static int buildCount = 0;

  /// 测试用：清零探针。
  static void resetProbe() => buildCount = 0;

  /// 他人公开回复的归属前缀（**唯一格式来源**：测试与文档都读这一处）。
  static String attributionPrefix(String displayName) => '$displayName 说：';

  /// 把原文投影成成员 X 的视图。
  ///
  /// [displayNames] 是成员 id → 显示名的解析结果（**含已移除成员**：历史行必须一直
  /// 有归属）。查不到的 id 用 id 本身兜底并打一行日志（不静默丢掉整条发言）。
  static GroupMemberView project({
    required List<Message> raw,
    required String memberId,
    required Map<String, String> displayNames,
  }) {
    buildCount++;
    final view = <Message>[];
    for (final row in raw) {
      final mapped = mapParsedRow(
        row,
        memberId: memberId,
        displayNames: displayNames,
      );
      if (mapped != null) view.add(mapped);
    }
    return GroupMemberView._(List<Message>.unmodifiable(view), memberId);
  }

  /// 单条已解析行的映射（整段投影与增量装配共用同一条规则）。
  ///
  /// 返回 null = 这一行不进该成员的视图。
  static Message? mapParsedRow(
    Message row, {
    required String memberId,
    required Map<String, String> displayNames,
  }) {
    if (row.isPrivate) {
      // 私有活动只有作者本人能看见；别人的私有行整体剔除（连 id 都不留）。
      return row.author == memberId ? row : null;
    }
    if (row.author == null) {
      // 用户消息：原样（role 已经是 user）。
      return row;
    }
    if (row.author == memberId) {
      // 自己的公开回复：assistant 轮、第一人称、无前缀。
      return row.content.isEmpty ? null : row;
    }
    // 其他成员的公开回复：user 轮 + 「Y 说：」前缀。
    if (row.content.isEmpty) return null;
    final name = displayNames[row.author];
    if (name == null || name.isEmpty) {
      debugPrint('[AliasAgent] 视图投影：消息 seq=${row.seq} 的作者 '
          '"${row.author}" 不在成员表里 — 归属前缀用作者 id 兜底');
    }
    final display = (name == null || name.isEmpty) ? row.author! : name;
    return Message(
      id: 'view-${row.seq ?? row.id}-from-${row.author}',
      seq: row.seq,
      sessionId: row.sessionId,
      role: 'user',
      content: '${attributionPrefix(display)}${row.content}',
      createdAt: row.createdAt,
      visibility: Message.visibilityPublic,
      // author 留空：这是"X 的视图里出现的一段他者话语"，不是成员原生行。
    );
  }

  /// 单条**原始行**的映射（增量装配用；公开行的解析走调用方给的缓存）。
  static Message? mapRowCached(
    Map<String, dynamic> row, {
    required String memberId,
    required Map<String, String> displayNames,
    required Message Function(Map<String, dynamic>) parseOrGet,
  }) {
    final visibility =
        row['visibility'] as String? ?? Message.visibilityPublic;
    if (visibility == Message.visibilityPrivateToAuthor) {
      if ((row['author'] as String?) != memberId) return null;
      // 私有行各成员各一份：不放进跨成员复用的公共缓存。
      return Message.fromRow(row);
    }
    final parsed = parseOrGet(row);
    return mapParsedRow(
      parsed,
      memberId: memberId,
      displayNames: displayNames,
    );
  }
}