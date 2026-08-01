class Message {
  final String id;
  final String sessionId;
  final String role; // 'user' or 'assistant'
  final String content;
  final String? toolCallsJson;
  final String? thinkingJson;
  final int? tokenCount;
  final int createdAt;

  const Message({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.toolCallsJson,
    this.thinkingJson,
    this.tokenCount,
    required this.createdAt,
  });

  factory Message.fromRow(Map<String, dynamic> row) {
    return Message(
      id: row['id'] as String,
      sessionId: row['session_id'] as String,
      role: row['role'] as String,
      content: row['content'] as String,
      toolCallsJson: row['tool_calls'] as String?,
      thinkingJson: row['thinking_json'] as String?,
      tokenCount: row['token_count'] as int?,
      createdAt: row['created_at'] as int,
    );
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'session_id': sessionId,
        'role': role,
        'content': content,
        'tool_calls': toolCallsJson,
        'thinking_json': thinkingJson,
        'token_count': tokenCount,
        'created_at': createdAt,
      };
}