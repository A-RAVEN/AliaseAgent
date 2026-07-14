import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/models/tool_call_activity.dart';

/// Shared factories for creating test data without touching real I/O.

Session testSession({
  String id = 's1',
  String title = 'Test Session',
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return Session(
    id: id,
    title: title,
    agentType: 'general',
    createdAt: now,
    updatedAt: now,
  );
}

List<Session> testSessions(int count) {
  return List.generate(
    count,
    (i) => testSession(id: 's${i + 1}', title: 'Session ${i + 1}'),
  );
}

Message testMessage({
  String id = 'm1',
  String sessionId = 's1',
  String role = 'user',
  String content = 'Hello',
}) {
  return Message(
    id: id,
    sessionId: sessionId,
    role: role,
    content: content,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
}

ToolCallActivity testToolActivity({
  String id = 't1',
  String toolName = 'read_file',
  Map<String, dynamic> input = const {'path': '/test/file.txt'},
  ToolCallStatus status = ToolCallStatus.done,
  String? resultPreview,
}) {
  return ToolCallActivity(
    id: id,
    toolName: toolName,
    input: input,
    status: status,
    resultPreview: resultPreview ?? 'file content here',
  );
}
