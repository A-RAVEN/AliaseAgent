import 'dart:async';
import 'dart:io' show sleep;

import 'package:alias_agent/services/sidecar_bridge.dart';

/// 一次工具入口调用的记录（change `parallelize-readonly-tool-calls` 任务 4.2）。
///
/// 记录**每一次**工具入口的真实开始 / 结束时刻与所经入口，用例据此断言并发时间窗、
/// 交付顺序与"取消时零调用"。这是增量字段：既有用例读桩结果的方式不受影响。
class FakeToolCall {
  FakeToolCall({
    required this.toolName,
    required this.entry,
    required this.requestJson,
    required this.startedAt,
  });

  /// 工具名（`read_file` / `grep_file` / `web_fetch` …）。
  final String toolName;

  /// 调用经过的入口：
  ///   - `sync`：六个同步只读方法或写类同步方法（主 isolate 直接调用）；
  ///   - `worker`：`callToolOnWorker`（并发段的 worker isolate 入口）；
  ///   - `async`：`webSearch` / `webFetch` / `runCommand` / 浏览器等本来就异步的方法。
  final String entry;

  /// 这次调用收到的请求原文（`list_dir` 是裸路径，其余是 JSON 字符串）。
  final String requestJson;

  final DateTime startedAt;
  DateTime? endedAt;

  bool get finished => endedAt != null;

  /// 执行时间窗（毫秒）。未结束时为 null。
  double? get durationMs => endedAt == null
      ? null
      : endedAt!.difference(startedAt).inMicroseconds / 1000.0;

  @override
  String toString() => 'FakeToolCall($toolName/$entry, '
      'start=${startedAt.microsecondsSinceEpoch}, '
      'end=${endedAt?.microsecondsSinceEpoch})';
}

/// A programmable fake sidecar for integration testing.
///
/// Queue events before calling [sendMessage]; they replay in order.
/// Use [stubReadFile] / [stubListDir] to control tool execution results.
class FakeSidecar implements ISidecar {
  final List<_FakeEvent> _events = [];
  String? _readFileResult;
  String? _listDirResult;

  // ---------------------------------------------------------------------------
  // 工具调用记录与可编程延迟 / 抛错（change parallelize-readonly-tool-calls 4.2）
  // ---------------------------------------------------------------------------

  /// 每一次工具入口调用（按发生顺序）。用例用它做时间窗、入口与顺序断言。
  final List<FakeToolCall> toolCalls = [];

  /// 按工具名注册的延迟。**这些毫秒数是测试构造值，不是产品里的任何限制** ——
  /// 只用来把"并发 vs 串行"的差别放大到可观测。
  final Map<String, Duration> _toolDelays = {};

  /// 按工具名注册的抛错（模拟工具执行失败）。值就是抛出去的错误。
  final Map<String, Object> _toolThrows = {};

  /// 给某个工具名登记一次执行延迟（测试构造值）。
  void stubToolDelay(String toolName, Duration delay) {
    _toolDelays[toolName] = delay;
  }

  /// 给某个工具名登记"一调就抛这个错"（字符串会被包成 [Exception]，好让错误文本
  /// 带上用例给的原因串）。
  void stubToolThrow(String toolName, Object error) {
    _toolThrows[toolName] = error;
  }

  /// 某个工具名被调用过几次。
  int countOf(String toolName) =>
      toolCalls.where((c) => c.toolName == toolName).length;

  /// 某个工具名的全部调用记录。
  List<FakeToolCall> callsOf(String toolName) =>
      toolCalls.where((c) => c.toolName == toolName).toList();

  /// 所有调用经过的入口（去重前）。
  List<String> get entriesUsed => [for (final c in toolCalls) c.entry];

  FakeToolCall _beginCall(String toolName, String entry, String requestJson) {
    final call = FakeToolCall(
      toolName: toolName,
      entry: entry,
      requestJson: requestJson,
      startedAt: DateTime.now(),
    );
    toolCalls.add(call);
    return call;
  }

  void _applySyncDelayAndThrow(String toolName) {
    final delay = _toolDelays[toolName];
    if (delay != null && delay > Duration.zero) {
      // 同步入口只能阻塞当前 isolate —— 它本来就只出现在"逐个段"里，段内没有
      // 并发可被这段等待挡住。
      sleep(delay);
    }
    final error = _toolThrows[toolName];
    if (error != null) throw _asError(error);
  }

  Future<void> _applyAsyncDelayAndThrow(String toolName) async {
    final delay = _toolDelays[toolName];
    if (delay != null && delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final error = _toolThrows[toolName];
    if (error != null) throw _asError(error);
  }

  static Object _asError(Object error) =>
      error is String ? Exception(error) : error;

  /// 包住同步工具入口：记录开始 / 结束，再执行桩逻辑。
  String _syncEntry(
      String toolName, String requestJson, String Function() body) {
    final call = _beginCall(toolName, 'sync', requestJson);
    try {
      _applySyncDelayAndThrow(toolName);
      return body();
    } finally {
      call.endedAt = DateTime.now();
    }
  }

  /// 包住本来异步的工具入口：记录开始 / 结束，再执行桩逻辑。
  Future<String> _asyncEntry(
      String toolName, String requestJson, Future<String> Function() body) async {
    final call = _beginCall(toolName, 'async', requestJson);
    try {
      await _applyAsyncDelayAndThrow(toolName);
      return await body();
    } finally {
      call.endedAt = DateTime.now();
    }
  }

  /// 并发段的 worker 入口：记录开始 / 结束，再按工具名返回对应的桩结果。
  Future<String> _workerEntry(
      String toolName, String requestJson, String Function() body) async {
    final call = _beginCall(toolName, 'worker', requestJson);
    try {
      await _applyAsyncDelayAndThrow(toolName);
      return body();
    } finally {
      call.endedAt = DateTime.now();
    }
  }

  // Search stubs (task 10.2)
  String _searchProvidersResult = '[]';
  String _webSearchResult = '{"ok":true,"results":{}}';
  String _webFetchResult = '{"ok":true,"content":""}';
  String _ensureSearchInfraResult = '{"ok":true}';

  // Browser tool stubs (add-browser-tool). Default: browser not available, ops
  // degrade to a readable error.
  String _browserAvailableResult = '{"ok":true,"available":false,"error":"no browser"}';
  String _browserNavigateResult = '{"ok":false,"error":"browser unavailable"}';
  String _browserClickResult = '{"ok":false,"error":"browser unavailable"}';
  String _browserTypeResult = '{"ok":false,"error":"browser unavailable"}';
  String _browserSnapshotResult = '{"ok":false,"error":"browser unavailable"}';

  // Command tool stub (add-command-tool). Default: 一条成功的空输出，用例可以覆盖。
  String _runCommandResult = '{"ok":true,"exit_code":0,"stdout":"","stderr":"",'
      '"timed_out":false,"duration_ms":1,"truncated":{"stdout":false,"stderr":false}}';

  // File edit stubs
  String _writeFileResult = '{"ok":true,"bytes_written":0,"created":true}';
  String _editFileResult = '{"ok":true,"replacements":1}';
  String _globFileResult = '{"ok":true,"paths":[],"count":0}';
  String _grepFileResult = '{"ok":true,"matches":[],"count":0}';

  // Image tool stubs (add-image-input). 默认都失败，用例按需覆盖。
  String _readImageResult = '{"ok":false,"error":"fake: read_image not stubbed"}';
  String _readClipboardImageResult = '{"ok":false,"error":"clipboard has no image"}';

  /// 最近一次 read_image / read_clipboard_image 的入参原文与调用次数 —— 用来断言
  /// "模型没声明图片输入时，工具前置检查直接失败、根本没调 sidecar"。
  String? lastReadImageRequest;
  String? lastReadClipboardImageRequest;
  int readImageCallCount = 0;
  int readClipboardImageCallCount = 0;

  void stubSearchProviders(String json) { _searchProvidersResult = json; }
  void stubWebSearch(String json) { _webSearchResult = json; }
  void stubWebFetch(String json) { _webFetchResult = json; }
  void stubEnsureSearchInfra(String json) { _ensureSearchInfraResult = json; }

  /// 最近一次 `ensureSearchInfra` 收到的配置原文（add-deepseek-web-search 任务 3.4）：
  /// 用来断言"会话模型的地址与密钥真的被一起交下去了"。
  String? lastEnsureSearchInfraConfig;

  /// 非空时 `ensureSearchInfra()` 会等它完成才返回 —— 用它把"动态工具还没装好"的
  /// 窗口摆出来（fix-silent-truncation 6.4）。这个窗口比 `browserAvailableGate` 更靠前：
  /// `_initSearchAndTools()` 先把 8 个本地工具同步装好，然后 await 搜索初始化，
  /// 那时 `_toolDefs` **恰好**就是"只有本地工具"的状态。
  Completer<void>? ensureSearchInfraGate;

  /// 非空时 `browserAvailable()` 会等它完成才返回 —— 用来在窗口用例里制造
  /// "动态工具还没探完"的那段窗口（fix-silent-truncation 6.3）。用例自己
  /// `complete()` 之后记得清空。
  Completer<void>? browserAvailableGate;
  void stubBrowserAvailable(String json) { _browserAvailableResult = json; }
  void stubBrowserNavigate(String json) { _browserNavigateResult = json; }
  void stubBrowserClick(String json) { _browserClickResult = json; }
  void stubBrowserType(String json) { _browserTypeResult = json; }
  void stubBrowserSnapshot(String json) { _browserSnapshotResult = json; }
  void stubRunCommand(String json) { _runCommandResult = json; }
  void stubWriteFile(String json) { _writeFileResult = json; }
  void stubEditFile(String json) { _editFileResult = json; }
  void stubGlobFile(String json) { _globFileResult = json; }
  void stubGrepFile(String json) { _grepFileResult = json; }
  void stubReadImage(String json) { _readImageResult = json; }
  void stubReadClipboardImage(String json) { _readClipboardImageResult = json; }

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

  /// 每个上下文接口收到的句柄（change add-context-handles）：用例据此断言
  /// "轮次属甲时工具调用仍带甲"，而不是读当时的 `_currentId`。
  final List<String> ensureContextCalls = [];
  final List<String> disposeContextCalls = [];

  /// `ensureContext` 收到的 `defaultWorkspace`（change
  /// add-agent-object-and-templates 任务 2.1）：逐个记录，用例据此断言"缺省工作区
  /// 只在 created:true 时由工厂交下去"。
  final List<String?> ensureContextDefaultWorkspaces = [];
  final Map<String, String?> defaultWorkspaceByHandle = {};

  /// `setWorkspace` 收到的句柄与路径（同上）。
  final List<({String handle, String path})> setWorkspaceCalls = [];

  final List<String> sendHandles = [];
  final List<String> cancelHandles = [];
  final List<String> toolHandles = [];
  final Map<String, bool> _createdByEnsure = {};
  final Set<String> _ensured = {};

  /// 可选：让 ensureContext 对某个句柄返回 created:true/false（默认首次 true）。
  void stubCreated(String sessionId, bool created) {
    _createdByEnsure[sessionId] = created;
  }

  @override
  Future<bool> ensureContext(String sessionId, {String? defaultWorkspace}) async {
    ensureContextCalls.add(sessionId);
    ensureContextDefaultWorkspaces.add(defaultWorkspace);
    defaultWorkspaceByHandle[sessionId] = defaultWorkspace;
    final created = _createdByEnsure[sessionId] ?? !_ensured.contains(sessionId);
    _ensured.add(sessionId);
    return created;
  }

  @override
  Future<void> disposeContext(String sessionId) async {
    disposeContextCalls.add(sessionId);
  }

  /// The last request's JSON + profile (for asserting the compaction projection
  /// and the summary profile mode are actually sent).
  String? lastMessagesJson;
  String? lastSystemPrompt;
  String? lastThinkingMode;
  String? lastThinkingEffort;
  String? lastBaseUrl;
  String? lastModel;
  String? lastToolsJson;
  /// 最近一次 sendMessage 的上下文句柄（2.7 / 2.8 的验收用它核对归属）。
  String? lastSendHandle;

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
  void cancelRequest(String handle) {
    cancelCount++;
    cancelHandles.add(handle);
  }

  @override
  Future<void> sendMessage({
    required String handle,
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
    lastSendHandle = handle;
    sendHandles.add(handle);
    lastMessagesJson = messagesJson;
    lastSystemPrompt = systemPrompt;
    lastThinkingMode = thinkingMode;
    lastThinkingEffort = thinkingEffort;
    lastBaseUrl = baseUrl;
    lastModel = model;
    lastToolsJson = toolsJson;

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
  String? setWorkspace(String handle, String path) {
    toolHandles.add(handle);
    setWorkspaceCalls.add((handle: handle, path: path));
    return null;
  }

  /// `get_workspace` 桩（add-spawn-subagent-tool 1.2）：按句柄记录每次查询，并返回
  /// 该句柄自己的工作区。没有为某句柄设值时返回空串 —— 与真实的新建上下文一致，
  /// 不用应用主目录顶替。
  final List<String> getWorkspaceCalls = [];
  final Map<String, String> workspaceByHandle = {};

  /// 非空时所有 `get_workspace` 调用都返回这个错误码（例如 unknown_context）。
  String? workspaceFailureCode;

  void stubWorkspace(String handle, String workspace) {
    workspaceByHandle[handle] = workspace;
  }

  @override
  WorkspaceQueryResult getWorkspace(String handle) {
    getWorkspaceCalls.add(handle);
    final code = workspaceFailureCode;
    if (code != null) {
      return WorkspaceQueryResult.failure(code, 'fake: $code ($handle)');
    }
    return WorkspaceQueryResult.success(workspaceByHandle[handle] ?? '');
  }

  @override
  String readFile(String handle, String requestJson) {
    toolHandles.add(handle);
    return _syncEntry('read_file', requestJson, () {
      return _readFileResult ??
          '{"ok":true,"content":"fake content","total_lines":1,"start_line":1,"end_line":1}';
    });
  }

  @override
  String listDir(String handle, String path) {
    toolHandles.add(handle);
    return _syncEntry('list_dir', path, () {
      return _listDirResult ?? '{"ok":true,"content":"[]"}';
    });
  }

  @override
  String ensureSearchInfra(String configJson) {
    lastEnsureSearchInfraConfig = configJson;
    return _ensureSearchInfraResult;
  }

  @override
  String getSearchProviders() => _searchProvidersResult;

  @override
  Future<String> webSearch(String handle, String requestJson) {
    toolHandles.add(handle);
    return _asyncEntry('web_search', requestJson, () async => _webSearchResult);
  }

  @override
  Future<String> webFetch(String handle, String requestJson) {
    toolHandles.add(handle);
    return _asyncEntry('web_fetch', requestJson, () async => _webFetchResult);
  }

  @override
  Future<String> browserAvailable() async {
    // 需要"探测还没回来"这个窗口时，用例先设一个 Completer（fix-silent-truncation 6.3）。
    final gate = browserAvailableGate;
    if (gate != null) await gate.future;
    return _browserAvailableResult;
  }

  @override
  Future<String> browserNavigate(String handle, String requestJson) {
    toolHandles.add(handle);
    return _asyncEntry(
        'browser_navigate', requestJson, () async => _browserNavigateResult);
  }

  @override
  Future<String> browserClick(String handle, String requestJson) {
    toolHandles.add(handle);
    return _asyncEntry(
        'browser_click', requestJson, () async => _browserClickResult);
  }

  @override
  Future<String> browserType(String handle, String requestJson) {
    toolHandles.add(handle);
    return _asyncEntry(
        'browser_type', requestJson, () async => _browserTypeResult);
  }

  @override
  Future<String> browserSnapshot(String handle, String requestJson) {
    toolHandles.add(handle);
    return _asyncEntry(
        'browser_snapshot', requestJson, () async => _browserSnapshotResult);
  }

  /// 命令工具：返回用例设定的结果，并把最后一次请求记下来（用例可以核对
  /// "组装进请求的四个配置值"到底传了什么）。
  String? lastRunCommandRequest;
  @override
  Future<String> runCommand(String handle, String requestJson) {
    toolHandles.add(handle);
    lastRunCommandRequest = requestJson;
    return _asyncEntry('run_command', requestJson, () async => _runCommandResult);
  }

  // Spill 读回桩（spill-large-tool-output）。默认返回空区间，用例按需覆盖。
  String _readSpillResult = '{"ok":true,"text":"","bytes_read":0,"total_bytes":0}';
  String? lastReadSpillRequest;
  void stubReadSpill(String json) { _readSpillResult = json; }

  @override
  String readSpill(String handle, String requestJson) {
    toolHandles.add(handle);
    lastReadSpillRequest = requestJson;
    return _syncEntry('read_spill', requestJson, () => _readSpillResult);
  }

  @override
  String writeFile(String handle, String requestJson) {
    toolHandles.add(handle);
    return _syncEntry('write_file', requestJson, () => _writeFileResult);
  }

  @override
  String editFile(String handle, String requestJson) {
    toolHandles.add(handle);
    return _syncEntry('edit_file', requestJson, () => _editFileResult);
  }

  @override
  String globFile(String handle, String requestJson) {
    toolHandles.add(handle);
    return _syncEntry('glob_file', requestJson, () => _globFileResult);
  }

  @override
  String grepFile(String handle, String requestJson) {
    toolHandles.add(handle);
    return _syncEntry('grep_file', requestJson, () => _grepFileResult);
  }

  @override
  String readImage(String handle, String requestJson) {
    toolHandles.add(handle);
    return _syncEntry('read_image', requestJson, () {
      readImageCallCount++;
      lastReadImageRequest = requestJson;
      return _readImageResult;
    });
  }

  @override
  String readClipboardImage(String handle, String requestJson) {
    toolHandles.add(handle);
    return _syncEntry('read_clipboard_image', requestJson, () {
      readClipboardImageCallCount++;
      lastReadClipboardImageRequest = requestJson;
      return _readClipboardImageResult;
    });
  }

  // ---------------------------------------------------------------------------
  // 并发段的 worker 入口（change parallelize-readonly-tool-calls 任务 4.2）
  // ---------------------------------------------------------------------------

  /// 把六个同步只读工具之一派到"worker"入口执行。记录与同步入口分开（entry =
  /// `worker`），用例据此断言"段长 ≥2 时才走 worker、段长 1 仍走同步方法"。
  @override
  Future<String> callToolOnWorker(
      String toolName, String handle, String requestJson) {
    toolHandles.add(handle);
    return _workerEntry(toolName, requestJson, () {
      switch (toolName) {
        case 'read_file':
          return _readFileResult ??
              '{"ok":true,"content":"fake content","total_lines":1,"start_line":1,"end_line":1}';
        case 'list_dir':
          return _listDirResult ?? '{"ok":true,"content":"[]"}';
        case 'glob_file':
          return _globFileResult;
        case 'grep_file':
          return _grepFileResult;
        case 'read_spill':
          lastReadSpillRequest = requestJson;
          return _readSpillResult;
        case 'read_image':
          readImageCallCount++;
          lastReadImageRequest = requestJson;
          return _readImageResult;
        default:
          // 没归类到 worker 表里的名字：显式报错并带上名字（不静默当别的工具执行）。
          return '{"ok":false,"error":"unknown worker tool: $toolName"}';
      }
    });
  }
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
