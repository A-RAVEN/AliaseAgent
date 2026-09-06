/// A frozen, deep-copied snapshot of the exact context handed to the model
/// gateway on one main-conversation request.
///
/// Captured right before `_sidecar.sendMessage(...)` in `_callModel`, at the
/// point where `systemPrompt` / `messages` / `toolsJson` and the request
/// parameters (`model` / `thinkingMode` / `thinkingEffort`) are all in scope.
/// `messages` is a deep copy (re-decoded from the `messagesJson` string that is
/// actually transmitted), so later in-place `.add` growth of the live
/// `apiMessages` in the tool loop never mutates an existing snapshot.
///
/// Pure data — no side effects, no live references.
class ContextSnapshot {
  final String sessionId;
  final String systemPrompt;
  final List<Map<String, dynamic>> messages;
  final String toolsJson;
  final String model;
  final String thinkingMode;
  final String thinkingEffort;
  final DateTime capturedAt;

  const ContextSnapshot({
    required this.sessionId,
    required this.systemPrompt,
    required this.messages,
    required this.toolsJson,
    required this.model,
    required this.thinkingMode,
    required this.thinkingEffort,
    required this.capturedAt,
  });

  /// Header label shown in the context view so the user can tell which session
  /// a retained snapshot belongs to (see design D6 / task 1.4 — a session switch
  /// retains the last snapshot and labels it, rather than clearing it).
  String get sessionLabel => 'snapshot for session=$sessionId';

  /// The full raw-JSON form (system + messages + tools) offered as copyable text
  /// in the view (task 2.7).
  Map<String, dynamic> toRawJson() => {
        'system': systemPrompt,
        'messages': messages,
        'tools': toolsJson,
      };
}
