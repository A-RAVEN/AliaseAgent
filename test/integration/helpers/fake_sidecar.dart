import 'package:alias_agent/services/sidecar_bridge.dart';

/// A programmable fake sidecar for integration testing.
///
/// Queue events before calling [sendMessage]; they replay in order.
/// Use [stubReadFile] / [stubListDir] to control tool execution results.
class FakeSidecar implements ISidecar {
  final List<_FakeEvent> _events = [];
  String? _readFileResult;
  String? _listDirResult;

  // Search stubs (task 10.2)
  String _searchProvidersResult = '[]';
  String _webSearchResult = '{"ok":true,"results":{}}';
  String _webFetchResult = '{"ok":true,"content":""}';
  String _ensureSearchInfraResult = '{"ok":true}';

  // File edit stubs
  String _writeFileResult = '{"ok":true,"bytes_written":0,"created":true}';
  String _editFileResult = '{"ok":true,"replacements":1}';

  void stubSearchProviders(String json) { _searchProvidersResult = json; }
  void stubWebSearch(String json) { _webSearchResult = json; }
  void stubWebFetch(String json) { _webFetchResult = json; }
  void stubEnsureSearchInfra(String json) { _ensureSearchInfraResult = json; }
  void stubWriteFile(String json) { _writeFileResult = json; }
  void stubEditFile(String json) { _editFileResult = json; }

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
    required String thinkingMode,
    required String thinkingEffort,
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
  String readFile(String requestJson) =>
      _readFileResult ?? '{"ok":true,"content":"fake content","total_lines":1,"start_line":1,"end_line":1}';

  @override
  String listDir(String path) =>
      _listDirResult ?? '{"ok":true,"content":"[]"}';

  @override
  String ensureSearchInfra(String configJson) => _ensureSearchInfraResult;

  @override
  String getSearchProviders() => _searchProvidersResult;

  @override
  Future<String> webSearch(String requestJson) async => _webSearchResult;

  @override
  Future<String> webFetch(String requestJson) async => _webFetchResult;

  @override
  String writeFile(String requestJson) => _writeFileResult;

  @override
  String editFile(String requestJson) => _editFileResult;
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
