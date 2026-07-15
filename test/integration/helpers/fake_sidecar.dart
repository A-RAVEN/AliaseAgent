import 'package:alias_agent/services/sidecar_bridge.dart';

/// A programmable fake sidecar for integration testing.
///
/// Queue events before calling [sendMessage]; they replay in order.
/// Use [stubReadFile] / [stubListDir] to control tool execution results.
class FakeSidecar implements ISidecar {
  final List<_FakeEvent> _events = [];
  String? _readFileResult;
  String? _listDirResult;

  // ---------------------------------------------------------------------------
  // Queue API
  // ---------------------------------------------------------------------------

  void queueChunk(String text) {
    _events.add(_FakeEvent(type: 'chunk', text: text));
  }

  void queueToolCall(String json) {
    _events.add(_FakeEvent(type: 'tool_call', json: json));
  }

  void queueThinking(String json) {
    _events.add(_FakeEvent(type: 'thinking', json: json));
  }

  void queueDone({int code = 0, String? error, String? stopReason}) {
    _events.add(_FakeEvent(
      type: 'done',
      code: code,
      error: error,
      stopReason: stopReason,
    ));
  }

  // ---------------------------------------------------------------------------
  // Tool stubs
  // ---------------------------------------------------------------------------

  void stubReadFile(String resultJson) {
    _readFileResult = resultJson;
  }

  void stubListDir(String resultJson) {
    _listDirResult = resultJson;
  }

  // ---------------------------------------------------------------------------
  // ISidecar implementation
  // ---------------------------------------------------------------------------

  @override
  Future<void> sendMessage({
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  }) async {
    // Snapshot and clear — events are consumed per sendMessage() call
    final events = List<_FakeEvent>.from(_events);
    _events.clear();
    for (final event in events) {
      switch (event.type) {
        case 'chunk':
          onChunk(event.text!);
        case 'tool_call':
          onToolCall(event.json!);
        case 'thinking':
          onThinking?.call(event.json!);
        case 'done':
          onDone(event.code, event.error, event.stopReason);
          return;
      }
    }
    // If no done event queued, fire a default done
    onDone(0, null, 'end_turn');
  }

  @override
  String? setWorkspace(String path) => null;

  @override
  String readFile(String path) =>
      _readFileResult ?? '{"ok":true,"content":"fake content"}';

  @override
  String listDir(String path) =>
      _listDirResult ?? '{"ok":true,"content":"[]"}';
}

// ---------------------------------------------------------------------------
// Internal event model
// ---------------------------------------------------------------------------

class _FakeEvent {
  final String type;
  final String? text;
  final String? json;
  final int code;
  final String? error;
  final String? stopReason;

  const _FakeEvent({
    required this.type,
    this.text,
    this.json,
    this.code = 0,
    this.error,
    this.stopReason,
  });
}
