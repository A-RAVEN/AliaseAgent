import 'dart:async';

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
  String _globFileResult = '{"ok":true,"paths":[],"count":0}';
  String _grepFileResult = '{"ok":true,"matches":[],"count":0}';

  void stubSearchProviders(String json) { _searchProvidersResult = json; }
  void stubWebSearch(String json) { _webSearchResult = json; }
  void stubWebFetch(String json) { _webFetchResult = json; }
  void stubEnsureSearchInfra(String json) { _ensureSearchInfraResult = json; }
  void stubWriteFile(String json) { _writeFileResult = json; }
  void stubEditFile(String json) { _editFileResult = json; }
  void stubGlobFile(String json) { _globFileResult = json; }
  void stubGrepFile(String json) { _grepFileResult = json; }

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

  void queueDone({int code = 0, String? error, String? stopReason,
      int inputTokens = 0, int outputTokens = 0}) {
    _events.add(_FakeEvent(
      type: 'done',
      code: code,
      error: error,
      stopReason: stopReason,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
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

  /// Records cancelRequest() invocations (for tests asserting the cancel path).
  int cancelCount = 0;

  /// The last request's JSON + profile (for asserting the compaction projection
  /// and the summary profile mode are actually sent).
  String? lastMessagesJson;
  String? lastSystemPrompt;
  String? lastThinkingMode;
  String? lastBaseUrl;
  String? lastModel;

  /// Suspends the NEXT sendMessage's event delivery until [releaseGate] is
  /// called — lets tests interleave a mid-stream session switch (11.4).
  /// Queue semantics (16.6): each gateNextSend() pushes a gate; each
  /// sendMessage pops its own gate and registers it as awaiting; each
  /// releaseGate() completes the OLDEST awaiting sendMessage, so multiple
  /// suspended sends can be sequenced in order.
  final List<Completer<void>> _gates = [];
  final List<Completer<void>> _awaitingGates = [];

  void gateNextSend() {
    _gates.add(Completer<void>());
  }

  void releaseGate() {
    if (_awaitingGates.isNotEmpty) {
      _awaitingGates.removeAt(0).complete();
    }
  }

  /// True when events remain queued (e.g. a tool-loop turn was aborted
  /// before consuming its events — 12.4).
  bool get hasQueuedEvents => _events.isNotEmpty;

  @override
  void cancelRequest() {
    cancelCount++;
  }

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
    // Record the request for assertion (compaction projection / summary profile).
    lastMessagesJson = messagesJson;
    lastSystemPrompt = systemPrompt;
    lastThinkingMode = thinkingMode;
    lastBaseUrl = baseUrl;
    lastModel = model;

    // Gate (11.4): suspend event delivery until the test releases it.
    // Per-send semantics (17.1): each sendMessage pops ITS OWN gate — the
    // oldest pending send waits on the oldest gate, so releaseGate() releases
    // exactly one sendMessage in FIFO order.
    if (_gates.isNotEmpty) {
      final gate = _gates.removeAt(0);
      _awaitingGates.add(gate);
      await gate.future;
    }
    // Consume events up to (and including) the first done — events queued for
    // LATER sendMessage calls (multi-turn tool loops) stay queued.
    var consumed = 0;
    final snapshot = List<_FakeEvent>.from(_events);
    for (final event in snapshot) {
      consumed++;
      switch (event.type) {
        case 'chunk':
          onChunk(event.text!);
        case 'tool_call':
          onToolCall(event.json!);
        case 'thinking':
          onThinking?.call(event.json!);
        case 'done':
          onDone(event.code, event.error, event.stopReason,
              event.inputTokens, event.outputTokens);
          _events.removeRange(0, consumed);
          return;
      }
    }
    // If no done event queued, consume everything and fire a default done
    _events.clear();
    onDone(0, null, 'end_turn', 0, 0);
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

  @override
  String globFile(String requestJson) => _globFileResult;

  @override
  String grepFile(String requestJson) => _grepFileResult;
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
  final int inputTokens;
  final int outputTokens;

  const _FakeEvent({
    required this.type,
    this.text,
    this.json,
    this.code = 0,
    this.error,
    this.stopReason,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });
}
