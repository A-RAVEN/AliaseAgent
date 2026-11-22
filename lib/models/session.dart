import '../models/instance_overrides.dart';

class Session {
  /// 单 Agent 会话（缺省；变更前的所有会话都是它）。
  static const String kindSingle = 'single';

  /// 组会话：成员共享一份原文，单 Agent 入口一律拒绝（`agent-group-chat` D16）。
  static const String kindGroup = 'group';

  static const Set<String> kKindValues = {kindSingle, kindGroup};

  final String id;
  final String title;
  final String agentType;

  /// 会话种类（config 里没有这一项：它是数据库列，见 `session-persistence`）。
  ///
  /// 旧行 / 旧创建路径没有这一列 ⇒ 读成 `single`；非法值同样回落 `single`
  /// （一条手改出来的 `kind` 不该把会话凭空变成组）。
  final String kind;

  /// 单 Agent 会话的覆盖层（`sessions.overrides_json`，可空）。
  ///
  /// 与成员行的 `overrides_json` 走**同一个解析器**（`AgentInstanceOverrides`）。
  final String? overridesJson;

  /// 父会话 id：普通顶层会话为 `null`；一次性子 Agent 的运行记录指向父会话。
  /// 普通列表只返回该字段为 `null` 的顶层会话（见 `SessionRepository.list`）。
  final String? parentSessionId;
  final int createdAt;
  final int updatedAt;

  const Session({
    required this.id,
    required this.title,
    this.agentType = 'general',
    this.parentSessionId,
    required this.createdAt,
    required this.updatedAt,
    this.kind = kindSingle,
    this.overridesJson,
  }) : assert(
          kind == kindSingle || kind == kindGroup,
          'kind 只能是 single 或 group：收到 "$kind"',
        );

  /// 是不是组会话。
  bool get isGroup => kind == kindGroup;

  /// 会话级覆盖层；null = 没有覆盖（列缺失 / 坏 JSON 都按无覆盖处理）。
  AgentInstanceOverrides? get overrides => AgentInstanceOverrides.parse(overridesJson);

  factory Session.fromRow(Map<String, dynamic> row) {
    final rawKind = row['kind'] as String?;
    return Session(
      id: row['id'] as String,
      title: row['title'] as String,
      agentType: row['agent_type'] as String? ?? 'general',
      parentSessionId: row['parent_session_id'] as String?,
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
      kind: kKindValues.contains(rawKind) ? rawKind! : kindSingle,
      overridesJson: row['overrides_json'] as String?,
    );
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'title': title,
        'agent_type': agentType,
        'parent_session_id': parentSessionId,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'kind': kind,
        'overrides_json': overridesJson,
      };

  Session copyWith({
    String? title,
    String? agentType,
    int? updatedAt,
    String? overridesJson,
    bool clearOverrides = false,
  }) {
    return Session(
      id: id,
      title: title ?? this.title,
      agentType: agentType ?? this.agentType,
      parentSessionId: parentSessionId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      kind: kind,
      overridesJson:
          clearOverrides ? null : (overridesJson ?? this.overridesJson),
    );
  }
}
