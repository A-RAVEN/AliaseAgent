import 'instance_overrides.dart';

/// 组会话的一个成员（change `agent-group-chat` / design D17）。
///
/// `id` 是**稳定成员身份**：`messages.author` 存它，显示名只在渲染归属时解析 ——
/// 改名不改变历史消息的归属。移除是**软删**（[removedAt] 非空、行保留），
/// 移除后同名重建是新 id。
class GroupMember {
  final String id;
  final String groupSessionId;

  /// 组内唯一的显示名（唯一性只在未移除成员之间成立）。
  final String name;

  /// 该成员使用的 Agent 模板名（模板是预设，成员覆盖层叠在它上面）。
  final String templateName;

  /// 成员覆盖层原文（`overrides_json`，可空）。
  final String? overridesJson;

  /// 软删标记（毫秒时间戳）；null = 仍在组里。
  final int? removedAt;

  final int createdAt;

  const GroupMember({
    required this.id,
    required this.groupSessionId,
    required this.name,
    required this.templateName,
    this.overridesJson,
    this.removedAt,
    required this.createdAt,
  });

  bool get isRemoved => removedAt != null;

  /// 成员覆盖层（与单会话覆盖层同一个解析器）。
  AgentInstanceOverrides? get overrides =>
      AgentInstanceOverrides.parse(overridesJson);

  factory GroupMember.fromRow(Map<String, dynamic> row) => GroupMember(
        id: row['id'] as String,
        groupSessionId: row['group_session_id'] as String,
        name: row['name'] as String,
        templateName: row['template_name'] as String,
        overridesJson: row['overrides_json'] as String?,
        removedAt: row['removed_at'] as int?,
        createdAt: row['created_at'] as int,
      );

  Map<String, dynamic> toRow() => {
        'id': id,
        'group_session_id': groupSessionId,
        'name': name,
        'template_name': templateName,
        'overrides_json': overridesJson,
        'removed_at': removedAt,
        'created_at': createdAt,
      };

  GroupMember copyWith({
    String? name,
    String? templateName,
    String? overridesJson,
    bool clearOverrides = false,
    int? removedAt,
  }) =>
      GroupMember(
        id: id,
        groupSessionId: groupSessionId,
        name: name ?? this.name,
        templateName: templateName ?? this.templateName,
        overridesJson:
            clearOverrides ? null : (overridesJson ?? this.overridesJson),
        removedAt: removedAt ?? this.removedAt,
        createdAt: createdAt,
      );

  /// 成员实例的**专属句柄**（sidecar 上下文键 + 注册表键 + 取消目标）。
  ///
  /// 组会话 id 是 DB 作用域、成员句柄是实例作用域，两者不能兼任（design D3）：
  /// 拿组 id 当句柄会让 N 个成员共用一个 sidecar 上下文、互相 cancel / 互相
  /// disposeContext。
  String get handle => memberHandle(groupSessionId, id);

  static String memberHandle(String groupId, String memberId) =>
      '$groupId::$memberId';
}
