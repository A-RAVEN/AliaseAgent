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

Message testMessageWithToolCalls({
  String id = 'm1',
  String sessionId = 's1',
  String role = 'assistant',
  String content = 'Here is the file content.',
  String toolCallsJson = '[{"id":"tc1","toolName":"read_file","input":{"path":"/test/file.txt"},"status":"done","result":"file content here"}]',
}) {
  return Message(
    id: id,
    sessionId: sessionId,
    role: role,
    content: content,
    toolCallsJson: toolCallsJson,
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
