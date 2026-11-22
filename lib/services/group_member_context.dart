// 成员实例的上下文（change `agent-group-chat` / design D3）。
//
// 一个 `Agent` 用 `sessionId` 做 **DB 作用域**、用 `handle` 做**实例句柄**。成员
// 实例两者不同：`sessionId` 是组会话 id（消息写进组会话、摘要按它存），`handle` 是
// 成员专属句柄（sidecar 上下文键 + 注册表键 + 取消目标）。这里只装"成员是谁"的
// 只读身份，不含任何运行态。
import '../models/group_member.dart';
import '../models/instance_overrides.dart';

class GroupMemberContext {
  const GroupMemberContext({
    required this.groupId,
    required this.memberId,
    required this.displayName,
    required this.templateName,
    this.overrides,
    this.removed = false,
  });

  final String groupId;

  /// 稳定成员 id（`messages.author` 存它）。
  final String memberId;

  /// 渲染归属用的显示名（改名不改归属：这里每次装配从成员行解析）。
  final String displayName;

  final String templateName;

  /// 成员覆盖层；null = 没有覆盖。
  final AgentInstanceOverrides? overrides;

  /// 已移除成员仍可能被装配视图（历史行要有归属），但不能再发言。
  final bool removed;

  String get handle => GroupMember.memberHandle(groupId, memberId);

  GroupMemberContext copyWith({
    String? displayName,
    String? templateName,
    AgentInstanceOverrides? overrides,
    bool clearOverrides = false,
    bool? removed,
  }) =>
      GroupMemberContext(
        groupId: groupId,
        memberId: memberId,
        displayName: displayName ?? this.displayName,
        templateName: templateName ?? this.templateName,
        overrides: clearOverrides ? null : (overrides ?? this.overrides),
        removed: removed ?? this.removed,
      );

  static GroupMemberContext fromMember(GroupMember member) => GroupMemberContext(
        groupId: member.groupSessionId,
        memberId: member.id,
        displayName: member.name,
        templateName: member.templateName,
        overrides: member.overrides,
        removed: member.isRemoved,
      );
}
