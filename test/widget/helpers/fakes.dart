import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/message_repository.dart';

class FakeSessionRepository implements SessionRepository {
  List<Session> sessions;
  FakeSessionRepository(this.sessions);

  @override
  Future<Session> create({String? title, String? agentType, String? parentSessionId, String kind = Session.kindSingle, String? overridesJson, bool reactionsEnabled = true, int? maxRounds}) async {
    final s = Session(
      id: 'new-${sessions.length}',
      title: title ?? 'New Chat',
      agentType: agentType ?? 'general',
      parentSessionId: parentSessionId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      overridesJson: overridesJson,
      reactionsEnabled: reactionsEnabled,
      maxRounds: maxRounds,
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
  Future<void> updateOverrides(String id, String? json) async {
    final index = sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final old = sessions[index];
    sessions[index] = Session(
      id: old.id,
      title: old.title,
      agentType: old.agentType,
      parentSessionId: old.parentSessionId,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
      kind: old.kind,
      overridesJson: json,
      reactionsEnabled: old.reactionsEnabled,
      maxRounds: old.maxRounds,
    );
  }

  @override
  Future<List<Session>> list() async => sessions.toList();

  @override
  Future<List<Session>> listChildren(String parentSessionId) async =>
      sessions.where((s) => s.parentSessionId == parentSessionId).toList();

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
    if (s == null) return false;
    // 缺省判据按 kind 泛化（与真仓库同口径）：组认「新组」与「New Chat」，单会话认后者。
    final defaults = s.isGroup ? const {'新组', 'New Chat'} : const {'New Chat'};
    if (!defaults.contains(s.title)) return false;
    final title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
    await updateTitle(id, title);
    return true;
  }

  @override
  Future<void> updateReactionsEnabled(String id, bool enabled) async {
    final i = sessions.indexWhere((s) => s.id == id);
    if (i < 0) return;
    sessions[i] = sessions[i].copyWith(reactionsEnabled: enabled);
  }

  @override
  Future<void> updateMaxRounds(String id, int? maxRounds) async {
    final i = sessions.indexWhere((s) => s.id == id);
    if (i < 0) return;
    // 显式 null = 恢复默认（`clearMaxRounds`；命名参数上 null 与"不传"不可区分）。
    sessions[i] = maxRounds == null
        ? sessions[i].copyWith(clearMaxRounds: true)
        : sessions[i].copyWith(maxRounds: maxRounds);
  }

  @override
  Future<void> touch(String id) async {}

  @override
  Future<Session> updateAgentType(String id, String agentType) async {
    final i = sessions.indexWhere((s) => s.id == id);
    if (i < 0) {
      throw SessionAgentTypeUpdateException(
        sessionId: id,
        agentType: agentType,
        updatedRows: 0,
        message: '会话 "$id" 不存在：没有更新到唯一既有行（假仓库）。',
      );
    }
    sessions[i] = sessions[i].copyWith(agentType: agentType);
    return sessions[i];
  }
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
    String? toolCallsJson,
    String? thinkingJson,
    int? tokenCount,
    int? outputTokenCount,
    List<String> attachments = const [],
    String? author,
    String visibility = Message.visibilityPublic,
  }) async {
    final msg = Message(
      id: 'msg-${messages.length}',
      sessionId: sessionId,
      role: role,
      content: content,
      toolCallsJson: toolCallsJson,
      thinkingJson: thinkingJson,
      tokenCount: tokenCount,
      outputTokenCount: outputTokenCount,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      attachments: attachments,
      author: author,
      visibility: visibility,
    );
    messages.add(msg);
    return msg;
  }

  @override
  Future<List<Message>> queryBySession(String sessionId) async {
    return messages.where((m) => m.sessionId == sessionId).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> queryRawAfterSeq(
      String sessionId, int afterSeq) async {
    return [
      for (final message in messages)
        if (message.sessionId == sessionId && (message.seq ?? 0) > afterSeq)
          message.toRow(),
    ]..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
  }

  @override
  Future<List<Map<String, dynamic>>> queryRawInRange(
      String sessionId, int minSeq, int maxSeq) async {
    return [
      for (final message in messages)
        if (message.sessionId == sessionId &&
            (message.seq ?? 0) >= minSeq &&
            (message.seq ?? 0) <= maxSeq)
          message.toRow(),
    ]..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
  }

  @override
  Future<void> updateToolCalls(String id, String toolCallsJson) async {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx >= 0) {
      messages[idx] = Message(
        id: messages[idx].id,
        seq: messages[idx].seq,
        sessionId: messages[idx].sessionId,
        role: messages[idx].role,
        content: messages[idx].content,
        toolCallsJson: toolCallsJson,
        thinkingJson: messages[idx].thinkingJson,
        tokenCount: messages[idx].tokenCount,
        createdAt: messages[idx].createdAt,
      );
    }
  }
}
