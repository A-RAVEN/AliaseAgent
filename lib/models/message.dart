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
    );
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
      };
}