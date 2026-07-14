import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/message_repository.dart';

class FakeSessionRepository implements SessionRepository {
  List<Session> sessions;
  FakeSessionRepository(this.sessions);

  @override
  Future<Session> create({String? title, String? agentType}) async {
    final s = Session(
      id: 'new-${sessions.length}',
      title: title ?? 'New Chat',
      agentType: agentType ?? 'general',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    sessions.insert(0, s);
    return s;
  }

  @override
  Future<Session?> get(String id) async {
    try {
      return sessions.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Session>> list() async => sessions.toList();

  @override
  Future<void> delete(String id) async {
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  Future<void> updateTitle(String id, String title) async {
    final i = sessions.indexWhere((s) => s.id == id);
    if (i >= 0) {
      sessions[i] = sessions[i].copyWith(title: title);
    }
  }

  @override
  Future<bool> updateTitleIfDefault(String id, String text) async {
    final s = await get(id);
    if (s == null || s.title != 'New Chat') return false;
    final title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
    await updateTitle(id, title);
    return true;
  }

  @override
  Future<void> touch(String id) async {}
}

class FakeMessageRepository implements MessageRepository {
  final List<Message> messages;

  FakeMessageRepository([List<Message>? messages])
      : messages = messages ?? [];

  @override
  Future<Message> insert({
    required String sessionId,
    required String role,
    required String content,
    int? tokenCount,
  }) async {
    final msg = Message(
      id: 'msg-${messages.length}',
      sessionId: sessionId,
      role: role,
      content: content,
      tokenCount: tokenCount,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    messages.add(msg);
    return msg;
  }

  @override
  Future<List<Message>> queryBySession(String sessionId) async {
    return messages.where((m) => m.sessionId == sessionId).toList();
  }
}
