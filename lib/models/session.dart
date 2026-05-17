class Session {
  final String id;
  final String title;
  final String agentType;
  final int createdAt;
  final int updatedAt;

  const Session({
    required this.id,
    required this.title,
    this.agentType = 'general',
    required this.createdAt,
    required this.updatedAt,
  });

  factory Session.fromRow(Map<String, dynamic> row) {
    return Session(
      id: row['id'] as String,
      title: row['title'] as String,
      agentType: row['agent_type'] as String? ?? 'general',
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
    );
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'title': title,
        'agent_type': agentType,
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
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}