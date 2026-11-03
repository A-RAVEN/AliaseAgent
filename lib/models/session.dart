class Session {
  final String id;
  final String title;
  final String agentType;

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
  });

  factory Session.fromRow(Map<String, dynamic> row) {
    return Session(
      id: row['id'] as String,
      title: row['title'] as String,
      agentType: row['agent_type'] as String? ?? 'general',
      parentSessionId: row['parent_session_id'] as String?,
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
    );
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'title': title,
        'agent_type': agentType,
        'parent_session_id': parentSessionId,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  Session copyWith({
    String? title,
    String? agentType,
    int? updatedAt,
  }) {
    return Session(
      id: id,
      title: title ?? this.title,
      agentType: agentType ?? this.agentType,
      parentSessionId: parentSessionId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}