import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

// ---------------------------------------------------------------------------
// Native C function signatures (must match sidecar_api.h exactly)
//
// change `add-context-handles`：除 ping / browser_available / ensure_search_infra /
// get_search_providers 外，每个导出函数的**第一个参数**都是上下文句柄。
// ---------------------------------------------------------------------------

typedef OnChunkNative = Void Function(Pointer<Utf8> text);
typedef OnToolCallNative = Void Function(Pointer<Utf8> json);
typedef OnThinkingNative = Void Function(Pointer<Utf8> thinkingJson);
typedef OnDoneNative = Void Function(Int32 code, Pointer<Utf8> err, Pointer<Utf8> stopReason, Int32 inputTokens, Int32 outputTokens);

typedef SendMessageNative = Int32 Function(
  Pointer<Utf8> handle,
  Pointer<Utf8> apiKey,
  Pointer<Utf8> baseUrl,
  Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> messagesJson,
  Pointer<Utf8> toolsJson,
  Pointer<Utf8> thinkingMode,
  Pointer<Utf8> thinkingEffort,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnThinkingNative>> onThinking,
  Pointer<NativeFunction<OnDoneNative>> onDone,
  Int32 requestId,
);

typedef SetWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> path);
typedef GetWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8> handle);
/// 机器级的一参接口（ensure_search_infra）：没有句柄，只有配置 JSON。
typedef OneStringNative = Pointer<Utf8> Function(Pointer<Utf8> value);
typedef CancelRequestNative = Pointer<Utf8> Function(Pointer<Utf8> handle, Int32 requestId);
typedef CreateContextNative = Pointer<Utf8> Function(Pointer<Utf8> name);
typedef DisposeContextNative = Pointer<Utf8> Function(Pointer<Utf8> handle);

// Dart-facing types
typedef SendMessageDart = int Function(
  Pointer<Utf8> handle,
  Pointer<Utf8> apiKey,
  Pointer<Utf8> baseUrl,
  Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> messagesJson,
  Pointer<Utf8> toolsJson,
  Pointer<Utf8> thinkingMode,
  Pointer<Utf8> thinkingEffort,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnThinkingNative>> onThinking,
  Pointer<NativeFunction<OnDoneNative>> onDone,
  int requestId,
);

typedef OnDoneDart = void Function(int code, Pointer<Utf8> err, Pointer<Utf8> stopReason, int inputTokens, int outputTokens);

typedef SetWorkspaceDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> path);
typedef GetWorkspaceDart = Pointer<Utf8> Function(Pointer<Utf8> handle);
typedef ReadFileDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> path);
typedef ListDirDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> path);
typedef EnsureSearchInfraDart = Pointer<Utf8> Function(Pointer<Utf8> configJson);
typedef GetSearchProvidersDart = Pointer<Utf8> Function();
typedef WebSearchDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef WebFetchDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef BrowserAvailableDart = Pointer<Utf8> Function();
typedef BrowserNavigateDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef BrowserClickDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef BrowserTypeDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef BrowserSnapshotDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef RunCommandDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef WriteFileDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef EditFileDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef GlobFileDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef GrepFileDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef ReadImageDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef ReadClipboardImageDart = Pointer<Utf8> Function(Pointer<Utf8> handle, Pointer<Utf8> requestJson);
typedef CancelRequestDart = Pointer<Utf8> Function(Pointer<Utf8> handle, int requestId);
typedef CreateContextDart = Pointer<Utf8> Function(Pointer<Utf8> name);
typedef DisposeContextDart = Pointer<Utf8> Function(Pointer<Utf8> handle);

// ---------------------------------------------------------------------------
// Dart-facing callback types
// ---------------------------------------------------------------------------

typedef OnChunkCallback = void Function(String text);
typedef OnToolCallCallback = void Function(String json);
typedef OnThinkingCallback = void Function(String thinkingJson);
typedef OnDoneCallback = void Function(int code, String? error, String? stopReason,
    int? inputTokens, int? outputTokens);

// ---------------------------------------------------------------------------
// get_workspace 的返回值
//
// C++ 侧返回线程本地缓冲里的 JSON，桥必须先立即复制成 Dart 字符串再解析。解析
// 放在下面这个顶层入口里：生产的 SidecarBridge.getWorkspace 与单元测试共用同一条
// 路径，测试不需要、也不允许另造一条假的解析逻辑。
// ---------------------------------------------------------------------------

/// `get_workspace` 的解析结果。成功时 [workspace] 就是该上下文实际保存的值
/// （空工作区就是空串）；失败时带 C++ 侧的 [code] 与 [error]，桥不会把失败伪装
/// 成成功空串。
class WorkspaceQueryResult {
  const WorkspaceQueryResult.success(this.workspace)
      : ok = true,
        code = null,
        error = null;

  const WorkspaceQueryResult.failure(this.code, this.error)
      : ok = false,
        workspace = null;

  final bool ok;
  final String? workspace;
  final String? code;
  final String? error;

  @override
  String toString() => ok
      ? 'WorkspaceQueryResult(ok, workspace: "$workspace")'
      : 'WorkspaceQueryResult(failed, code: $code, error: $error)';
}

/// 解析 `get_workspace` 的原始 JSON 文本（生产与单元测试共用）。
///
/// - `{"ok":true,"workspace":"…"}` → [WorkspaceQueryResult.success]，空串原样保留；
/// - `{"ok":false,"code":"unknown_context","error":"…"}` → 失败结果，错误码保留；
/// - 非 JSON、非对象、或声称成功却没有 `workspace` 字符串 → 抛 [StateError]，
///   消息点名 `get_workspace`，让"返回了看不懂的东西"变成可归因错误而不是空成功。
WorkspaceQueryResult parseWorkspaceResponse(String raw) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw StateError('get_workspace returned non-JSON: $raw (${e.message})');
  }
  if (decoded is! Map<String, dynamic>) {
    throw StateError('get_workspace returned non-object JSON: $raw');
  }
  if (decoded['ok'] != true) {
    final code = decoded['code'];
    final error = decoded['error'];
    return WorkspaceQueryResult.failure(
      code is String && code.isNotEmpty ? code : 'get_workspace_failed',
      error is String && error.isNotEmpty ? error : 'get_workspace failed: $raw',
    );
  }
  final workspace = decoded['workspace'];
  if (workspace is! String) {
    throw StateError(
        'get_workspace succeeded without a workspace string: $raw');
  }
  return WorkspaceQueryResult.success(workspace);
}

// ---------------------------------------------------------------------------
// ISidecar — abstract interface for sidecar communication
// ---------------------------------------------------------------------------

abstract class ISidecar {
  /// 幂等地保证 `sessionId` 对应的上下文存在。返回这次是否新建。
  /// 新建时（且给了 `defaultWorkspace`）由桥设置该上下文的工作区；已存在时
  /// 不覆盖已有工作区。空名字与保留名会抛错（C++ 侧拒绝，桥不静默吞掉）。
  Future<bool> ensureContext(String sessionId, {String? defaultWorkspace});

  /// 销毁上下文：先拒绝新调用、等该上下文的排队请求与回调处理结束，再异步
  /// 调用 C++ dispose 完成底层排空与清理。不阻塞界面线程。
  Future<void> disposeContext(String sessionId);

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
  });

  /// 取消该上下文最近入队的请求（请求 id 定向）。
  void cancelRequest(String handle);

  String? setWorkspace(String handle, String path);

  /// 只读读取该上下文当前保存的工作区（C++ `get_workspace`）。成功时
  /// [WorkspaceQueryResult.workspace] 是实际值，空工作区如实为空串；未知或已
  /// 销毁的句柄返回 `ok:false` + `unknown_context`，不隐式创建上下文。
  WorkspaceQueryResult getWorkspace(String handle);

  String readFile(String handle, String requestJson);
  String listDir(String handle, String path);

  // File edit tools
  String writeFile(String handle, String requestJson);
  String editFile(String handle, String requestJson);

  // Ripgrep-backed search tools
  String globFile(String handle, String requestJson);
  String grepFile(String handle, String requestJson);

  // Image tools (add-image-input).
  String readImage(String handle, String requestJson);
  String readClipboardImage(String handle, String requestJson);

  // Search & web fetch
  String ensureSearchInfra(String configJson);
  String getSearchProviders();
  Future<String> webSearch(String handle, String requestJson);
  Future<String> webFetch(String handle, String requestJson);

  // Browser tool (add-browser-tool) — persistent headed Edge worker.
  Future<String> browserAvailable();
  Future<String> browserNavigate(String handle, String requestJson);
  Future<String> browserClick(String handle, String requestJson);
  Future<String> browserType(String handle, String requestJson);
  Future<String> browserSnapshot(String handle, String requestJson);

  // Command tool (add-command-tool).
  Future<String> runCommand(String handle, String requestJson);

  // Spill 读回（spill-large-tool-output）：只读该上下文自己的 spill 目录。
  String readSpill(String handle, String requestJson);

  /// 把一个只读工具调用派到 worker isolate 执行（change
  /// `parallelize-readonly-tool-calls` 任务 4.1）。
  ///
  /// 只接受六个同步只读工具名：`read_file`、`list_dir`、`glob_file`、
  /// `grep_file`、`read_spill`、`read_image`。`requestJson` 的形态与同名同步方法
  /// 一致（`list_dir` 是裸路径，其余是请求 JSON）。
  ///
  /// 用途：并发段的每个成员各起一个 isolate，同步 FFI 调用才会真正重叠。段长为 1
  /// 时调用方仍走原来的同步方法，单工具时序不变。名字不在支持集里时返回带名字的
  /// 显式错误 JSON，不静默当别的工具执行。
  Future<String> callToolOnWorker(
      String toolName, String handle, String requestJson);
}

// ---------------------------------------------------------------------------
// SidecarBridge
// ---------------------------------------------------------------------------

class SidecarBridge implements ISidecar {
  static SidecarBridge? _instance;

  late final DynamicLibrary _lib;
  late final CreateContextDart _createContextFn;
  late final DisposeContextDart _disposeContextFn;
  late final SetWorkspaceDart _setWorkspaceFn;
  late final GetWorkspaceDart _getWorkspaceFn;
  late final ReadFileDart _readFileFn;
  late final ListDirDart _listDirFn;
  late final EnsureSearchInfraDart _ensureSearchInfraFn;
  late final GetSearchProvidersDart _getSearchProvidersFn;
  late final WebSearchDart _webSearchFn;
  late final WebFetchDart _webFetchFn;
  late final BrowserAvailableDart _browserAvailableFn;
  late final BrowserNavigateDart _browserNavigateFn;
  late final BrowserClickDart _browserClickFn;
  late final BrowserTypeDart _browserTypeFn;
  late final BrowserSnapshotDart _browserSnapshotFn;
  late final WriteFileDart _writeFileFn;
  late final EditFileDart _editFileFn;
  late final GlobFileDart _globFileFn;
  late final GrepFileDart _grepFileFn;
  late final ReadImageDart _readImageFn;
  late final ReadClipboardImageDart _readClipboardImageFn;
  late final CancelRequestDart _cancelRequestFn;
  late final RunCommandDart _readSpillFn;

  // 串行闸门按上下文分（change add-context-handles）：同上下文的 sendMessage 仍
  // 严格按序，不同上下文的请求互不排队。
  final Map<String, Future<void>> _chains = {};
  final Map<String, int> _lastRequestIds = {};
  final Map<String, int> _pendingRequests = {};

  // 取消后一直没有真实 done 的上下文：不合成 onDone、拒绝新请求，直到销毁或
  // 进程重启（design 决策 10）。
  final Set<String> _poisoned = {};

  // 正在销毁的上下文：不再接收新调用。
  final Set<String> _closing = {};

  // 请求 id 仍保证跨上下文唯一（共享计数器，只用于让 cancel 能定向）。
  int _nextRequestId = 1;

  /// 测试注入：取消后等待真实 done 的兜底时长。生产默认 30 秒；测试可缩短。
  static Duration cancelFallbackDelay = const Duration(seconds: 30);

  /// 测试注入：接收超时（生产 120 秒）。只给"无 done 走毒化"的用例缩短时间。
  static Duration receiveTimeout = const Duration(seconds: 120);

  /// 测试注入：让取消**失败**（不调用 C++ 的 cancel_request），用来制造
  /// 「取消后一直没有真实 done」这条分支。生产恒为 false。
  static bool cancelFailureForTests = false;

  SidecarBridge._() {
    _lib = _openLibrary();
    _createContextFn =
        _lib.lookupFunction<CreateContextNative, CreateContextDart>('create_context');
    _disposeContextFn =
        _lib.lookupFunction<DisposeContextNative, DisposeContextDart>('dispose_context');
    _setWorkspaceFn =
        _lib.lookupFunction<SetWorkspaceNative, SetWorkspaceDart>('set_workspace');
    _getWorkspaceFn =
        _lib.lookupFunction<GetWorkspaceNative, GetWorkspaceDart>('get_workspace');
    _readFileFn =
        _lib.lookupFunction<SetWorkspaceNative, ReadFileDart>('read_file');
    _listDirFn =
        _lib.lookupFunction<SetWorkspaceNative, ListDirDart>('list_dir');
    _ensureSearchInfraFn =
        _lib.lookupFunction<OneStringNative, EnsureSearchInfraDart>('ensure_search_infra');
    _getSearchProvidersFn =
        _lib.lookupFunction<Pointer<Utf8> Function(), GetSearchProvidersDart>('get_search_providers');
    _webSearchFn =
        _lib.lookupFunction<SetWorkspaceNative, WebSearchDart>('web_search');
    _webFetchFn =
        _lib.lookupFunction<SetWorkspaceNative, WebFetchDart>('web_fetch');
    _browserAvailableFn =
        _lib.lookupFunction<Pointer<Utf8> Function(), BrowserAvailableDart>('browser_available');
    _browserNavigateFn =
        _lib.lookupFunction<SetWorkspaceNative, BrowserNavigateDart>('browser_navigate');
    _browserClickFn =
        _lib.lookupFunction<SetWorkspaceNative, BrowserClickDart>('browser_click');
    _browserTypeFn =
        _lib.lookupFunction<SetWorkspaceNative, BrowserTypeDart>('browser_type');
    _browserSnapshotFn =
        _lib.lookupFunction<SetWorkspaceNative, BrowserSnapshotDart>('browser_snapshot');
    _writeFileFn =
        _lib.lookupFunction<SetWorkspaceNative, WriteFileDart>('write_file');
    _editFileFn =
        _lib.lookupFunction<SetWorkspaceNative, EditFileDart>('edit_file');
    _globFileFn =
        _lib.lookupFunction<SetWorkspaceNative, GlobFileDart>('glob_file');
    _grepFileFn =
        _lib.lookupFunction<SetWorkspaceNative, GrepFileDart>('grep_file');
    _readImageFn =
        _lib.lookupFunction<SetWorkspaceNative, ReadImageDart>('read_image');
    _readClipboardImageFn =
        _lib.lookupFunction<SetWorkspaceNative, ReadClipboardImageDart>('read_clipboard_image');
    _cancelRequestFn =
        _lib.lookupFunction<CancelRequestNative, CancelRequestDart>('cancel_request');
    _readSpillFn =
        _lib.lookupFunction<SetWorkspaceNative, RunCommandDart>('read_spill');
  }

  static SidecarBridge get instance {
    _instance ??= SidecarBridge._();
    return _instance!;
  }

  /// 测试用：重置每个上下文的排队状态（不动 C++ 侧）。
  void resetForTests() {
    _chains.clear();
    _lastRequestIds.clear();
    _pendingRequests.clear();
    _poisoned.clear();
    _closing.clear();
  }

  @visibleForTesting
  bool isPoisoned(String handle) => _poisoned.contains(handle);

  @visibleForTesting
  int pendingRequests(String handle) => _pendingRequests[handle] ?? 0;

  // -- 上下文生命周期 --------------------------------------------------------

  @override
  Future<bool> ensureContext(String sessionId, {String? defaultWorkspace}) async {
    if (sessionId.isEmpty) {
      throw StateError('create_context failed: empty_context');
    }
    final ptr = sessionId.toNativeUtf8();
    final String text;
    try {
      final resultPtr = _createContextFn(ptr);
      text = resultPtr.toDartString();
    } finally {
      malloc.free(ptr);
    }
    final Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      throw StateError('create_context returned non-JSON: $text');
    }
    if (parsed['ok'] != true) {
      throw StateError(
          'create_context failed: ${parsed['code']}: ${parsed['error']}');
    }
    final created = parsed['created'] == true;
    if (created && defaultWorkspace != null && defaultWorkspace.isNotEmpty) {
      setWorkspace(sessionId, defaultWorkspace);
    }
    _closing.remove(sessionId);
    return created;
  }

  @override
  Future<void> disposeContext(String sessionId) async {
    _closing.add(sessionId);
    // 先等这个上下文已入队的请求与它们触发的回调处理结束（桥内队列），
    // 再让 C++ 侧排空模型/工具/浏览器在途调用并清理资源。
    final chain = _chains[sessionId];
    if (chain != null) {
      try {
        await chain;
      } catch (_) {}
    }
    // 让已经排到事件队列里的回调/计时器先跑完。
    await Future<void>.delayed(Duration.zero);

    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
      'handle': sessionId,
      'requestJson': '',
      'workerType': 'dispose_context',
    });
    final result = await receivePort.first as String;
    receivePort.close();

    final Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(result) as Map<String, dynamic>;
    } catch (e) {
      throw StateError('dispose_context returned non-JSON: $result');
    }
    if (parsed['ok'] != true) {
      throw StateError(
          'dispose_context failed: ${parsed['code']}: ${parsed['error']}');
    }
    _chains.remove(sessionId);
    _lastRequestIds.remove(sessionId);
    _pendingRequests.remove(sessionId);
    _poisoned.remove(sessionId);
    _closing.remove(sessionId);
  }

  // -- non-blocking model call (FFI runs on a worker isolate; callbacks are
  //    delivered to THIS isolate in real-time via NativeCallable) --

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
  }) {
    if (_poisoned.contains(handle) || _closing.contains(handle)) {
      // 取消失败已经毒化了这个上下文：不再发请求，也不合成模型 done。
      scheduleMicrotask(() => onDone(-3, 'context_poisoned: $handle', null, 0, 0));
      return Future<void>.value();
    }
    final requestId = _nextRequestId++;
    _lastRequestIds[handle] = requestId;
    _pendingRequests[handle] = (_pendingRequests[handle] ?? 0) + 1;
    final prev = _chains[handle] ?? Future<void>.value();
    final result = prev.then((_) => _sendMessageInner(
          handle: handle,
          apiKey: apiKey,
          baseUrl: baseUrl,
          model: model,
          systemPrompt: systemPrompt,
          messagesJson: messagesJson,
          toolsJson: toolsJson,
          thinkingMode: thinkingMode,
          thinkingEffort: thinkingEffort,
          requestId: requestId,
          onChunk: onChunk,
          onToolCall: onToolCall,
          onThinking: onThinking,
          onDone: onDone,
        ));
    _chains[handle] = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  void cancelRequest(String handle) {
    // 请求 id 定向取消：只取消该上下文最近入队的那个请求。没有在途请求时是
    // no-op（否则会给一个已完成的 id 留下 C++ 侧的取消闩锁）。
    if ((_pendingRequests[handle] ?? 0) <= 0) return;
    final id = _lastRequestIds[handle];
    if (id != null && id != 0) {
      if (cancelFailureForTests) return;  // 测试注入：取消失败
      final handlePtr = handle.toNativeUtf8();
      try {
        _cancelRequestFn(handlePtr, id);
      } finally {
        malloc.free(handlePtr);
      }
    }
  }

  Future<void> _sendMessageInner({
    required String handle,
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required String thinkingMode,
    required String thinkingEffort,
    required int requestId,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  }) async {
    final completer = Completer<void>();
    var finished = false;
    var timedOut = false;

    late final NativeCallable<OnChunkNative> onChunkCallable;
    late final NativeCallable<OnToolCallNative> onToolCallCallable;
    late final NativeCallable<OnThinkingNative> onThinkingCallable;
    late final NativeCallable<OnDoneNative> onDoneCallable;

    void decrementPending() {
      final current = _pendingRequests[handle] ?? 0;
      if (current > 0) _pendingRequests[handle] = current - 1;
    }

    void finish(int code, String error, String stopReason, int inputTokens,
        int outputTokens,
        {bool closeCallables = true}) {
      if (finished) return; // idempotent: ignore duplicate done (F5)
      finished = true;
      decrementPending();
      if (closeCallables) {
        Timer.run(() {
          onChunkCallable.close();
          onToolCallCallable.close();
          onThinkingCallable.close();
          onDoneCallable.close();
        });
      }
      completer.complete();
      onDone(
          code,
          error.isEmpty ? null : (timedOut && code != 0 ? 'Request timed out after 120s' : error),
          stopReason.isEmpty ? null : stopReason,
          inputTokens, outputTokens);
    }

    onChunkCallable = NativeCallable<OnChunkNative>.listener(
      (Pointer<Utf8> ptr) {
        onChunk(ptr.toDartString());
      },
    );
    onToolCallCallable = NativeCallable<OnToolCallNative>.listener(
      (Pointer<Utf8> ptr) {
        onToolCall(ptr.toDartString());
      },
    );
    onThinkingCallable = NativeCallable<OnThinkingNative>.listener(
      (Pointer<Utf8> ptr) {
        onThinking?.call(ptr.toDartString());
      },
    );
    onDoneCallable = NativeCallable<OnDoneNative>.listener(
      (int code, Pointer<Utf8> errPtr, Pointer<Utf8> stopReasonPtr,
          int inputTokens, int outputTokens) {
        finish(code, errPtr.toDartString(), stopReasonPtr.toDartString(),
            inputTokens, outputTokens);
      },
    );

    await Isolate.spawn(_workerMain, {
      'handle': handle,
      'apiKey': apiKey,
      'baseUrl': baseUrl,
      'model': model,
      'systemPrompt': systemPrompt,
      'messagesJson': messagesJson,
      'toolsJson': toolsJson,
      'thinkingMode': thinkingMode,
      'thinkingEffort': thinkingEffort,
      'requestId': requestId,
      'onChunkAddr': onChunkCallable.nativeFunction.address,
      'onToolCallAddr': onToolCallCallable.nativeFunction.address,
      'onThinkingAddr': onThinkingCallable.nativeFunction.address,
      'onDoneAddr': onDoneCallable.nativeFunction.address,
    });

    // ---- Timeout: real cancellation, never a fake done ---------------------
    final timeoutTimer = Timer(receiveTimeout, () {
      if (finished) return;
      timedOut = true;
      // ignore: avoid_print
      print('[SidecarBridge] request #$requestId on "$handle" timed out after '
          '${receiveTimeout.inSeconds}s — cancelling');
      if (!cancelFailureForTests) {
        final handlePtr = handle.toNativeUtf8();
        try {
          _cancelRequestFn(handlePtr, requestId);
        } finally {
          malloc.free(handlePtr);
        }
      }
      // 兜底：取消路径一直不交付真实 done 时，**不合成 onDone**。等待方拿到错误，
      // 该上下文标为 context_poisoned、拒绝后续请求，callable 保持打开（curl 线程
      // 可能还在调用它）。只能靠销毁或进程重启清除。
      final fallback = Timer(cancelFallbackDelay, () {
        if (finished) return;
        finished = true;
        decrementPending();
        _poisoned.add(handle);
        // ignore: avoid_print
        print('[SidecarBridge] FALLBACK: no done on "$handle" after cancel — '
            'marking context_poisoned without synthesising onDone');
        completer.completeError(StateError(
            'context_poisoned: $handle (no done after cancel; dispose or restart required)'));
      });
      // 这个派生 Future 只用来在请求结束时取消兜底计时器；它自己会继承失败状态，
      // 必须显式 ignore，否则会变成未处理的异步错误（测试里会直接失败）。
      completer.future.whenComplete(fallback.cancel).ignore();
    });

    try {
      await completer.future;
    } finally {
      timeoutTimer.cancel();
    }
  }

  // -- worker isolate entry point (FFI call only; callbacks bypass the worker)

  static void _workerMain(Map<String, dynamic> args) {
    final handle = args['handle'] as String;
    final apiKey = args['apiKey'] as String;
    final baseUrl = args['baseUrl'] as String;
    final model = args['model'] as String;
    final systemPrompt = args['systemPrompt'] as String;
    final messagesJson = args['messagesJson'] as String;
    final toolsJson = args['toolsJson'] as String;
    final thinkingMode = args['thinkingMode'] as String;
    final thinkingEffort = args['thinkingEffort'] as String;
    final requestId = args['requestId'] as int;
    final onChunkAddr = args['onChunkAddr'] as int;
    final onToolCallAddr = args['onToolCallAddr'] as int;
    final onThinkingAddr = args['onThinkingAddr'] as int;
    final onDoneAddr = args['onDoneAddr'] as int;

    final onChunkPtr = Pointer<NativeFunction<OnChunkNative>>.fromAddress(onChunkAddr);
    final onToolCallPtr = Pointer<NativeFunction<OnToolCallNative>>.fromAddress(onToolCallAddr);
    final onThinkingPtr = Pointer<NativeFunction<OnThinkingNative>>.fromAddress(onThinkingAddr);
    final onDonePtr = Pointer<NativeFunction<OnDoneNative>>.fromAddress(onDoneAddr);

    try {
      final lib = _openLibrary();
      final sendMessageFn =
          lib.lookupFunction<SendMessageNative, SendMessageDart>('send_message');

      final handlePtr = handle.toNativeUtf8();
      final apiKeyPtr = apiKey.toNativeUtf8();
      final baseUrlPtr = baseUrl.toNativeUtf8();
      final modelPtr = model.toNativeUtf8();
      final systemPromptPtr = systemPrompt.toNativeUtf8();
      final messagesJsonPtr = messagesJson.toNativeUtf8();
      final toolsJsonPtr = toolsJson.toNativeUtf8();
      final thinkingModePtr = thinkingMode.toNativeUtf8();
      final thinkingEffortPtr = thinkingEffort.toNativeUtf8();

      try {
        sendMessageFn(
          handlePtr,
          apiKeyPtr,
          baseUrlPtr,
          modelPtr,
          systemPromptPtr,
          messagesJsonPtr,
          toolsJsonPtr,
          thinkingModePtr,
          thinkingEffortPtr,
          onChunkPtr,
          onToolCallPtr,
          onThinkingPtr,
          onDonePtr,
          requestId,
        );
      } finally {
        malloc.free(handlePtr);
        malloc.free(apiKeyPtr);
        malloc.free(baseUrlPtr);
        malloc.free(modelPtr);
        malloc.free(systemPromptPtr);
        malloc.free(messagesJsonPtr);
        malloc.free(toolsJsonPtr);
        malloc.free(thinkingModePtr);
        malloc.free(thinkingEffortPtr);
      }
    } catch (e, st) {
      // Deliver done(-1) via the on_done native pointer so the main isolate
      // completes the request and the serialization gate releases.
      // ignore: avoid_print
      print('[SidecarBridge] worker error: $e\n$st');
      try {
        final onDoneDart = onDonePtr
            .cast<NativeFunction<OnDoneNative>>()
            .asFunction<OnDoneDart>();
        // NEVER free these strings: the NativeCallable listener reads them
        // asynchronously on the main isolate's event loop after this worker has
        // already exited — freeing here is a use-after-free.
        final errPtr = e.toString().toNativeUtf8();
        final stopPtr = ''.toNativeUtf8();
        onDoneDart(-1, errPtr, stopPtr, 0, 0);
      } catch (_) {
        // Nothing more we can do.
      }
    }
  }

  // -- tools (run on main isolate — they're fast, local calls) --

  @override
  String? setWorkspace(String handle, String path) {
    final handlePtr = handle.toNativeUtf8();
    final ptr = path.toNativeUtf8();
    try {
      final resultPtr = _setWorkspaceFn(handlePtr, ptr);
      final result = resultPtr.toDartString();
      return result.isEmpty ? null : result;
    } finally {
      malloc.free(handlePtr);
      malloc.free(ptr);
    }
  }

  @override
  WorkspaceQueryResult getWorkspace(String handle) {
    final handlePtr = handle.toNativeUtf8();
    try {
      // C++ 返回的指针由调用线程结果缓冲持有：拿到后立即复制成 Dart 字符串，
      // 再交给上面那个生产与测试共用的解析入口。
      final raw = _getWorkspaceFn(handlePtr).toDartString();
      return parseWorkspaceResponse(raw);
    } finally {
      malloc.free(handlePtr);
    }
  }

  @override
  String readFile(String handle, String requestJson) {
    // If input doesn't look like JSON, wrap it as {"path":"..."}
    final json = requestJson.trimLeft().startsWith('{')
        ? requestJson
        : '{"path":"${_jsonEscape(requestJson)}"}';
    final handlePtr = handle.toNativeUtf8();
    final ptr = json.toNativeUtf8();
    try {
      return _readFileFn(handlePtr, ptr).toDartString();
    } finally {
      malloc.free(handlePtr);
      malloc.free(ptr);
    }
  }

  @override
  String writeFile(String handle, String requestJson) {
    return _callJsonTool(_writeFileFn, handle, requestJson);
  }

  @override
  String editFile(String handle, String requestJson) {
    return _callJsonTool(_editFileFn, handle, requestJson);
  }

  @override
  String globFile(String handle, String requestJson) {
    return _callJsonTool(_globFileFn, handle, requestJson);
  }

  @override
  String grepFile(String handle, String requestJson) {
    return _callJsonTool(_grepFileFn, handle, requestJson);
  }

  @override
  String readSpill(String handle, String requestJson) {
    return _callJsonTool(_readSpillFn, handle, requestJson);
  }

  @override
  String readImage(String handle, String requestJson) {
    return _callJsonTool(_readImageFn, handle, requestJson);
  }

  @override
  String readClipboardImage(String handle, String requestJson) {
    return _callJsonTool(_readClipboardImageFn, handle, requestJson);
  }

  String _callJsonTool(
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>) fn,
      String handle,
      String requestJson) {
    final handlePtr = handle.toNativeUtf8();
    final ptr = requestJson.toNativeUtf8();
    try {
      return fn(handlePtr, ptr).toDartString();
    } finally {
      malloc.free(handlePtr);
      malloc.free(ptr);
    }
  }

  /// Minimal JSON string escape for path embedding.
  static String _jsonEscape(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  @override
  String listDir(String handle, String path) {
    final handlePtr = handle.toNativeUtf8();
    final ptr = path.toNativeUtf8();
    try {
      return _listDirFn(handlePtr, ptr).toDartString();
    } finally {
      malloc.free(handlePtr);
      malloc.free(ptr);
    }
  }

  // -- search & web fetch --

  @override
  String ensureSearchInfra(String configJson) {
    final ptr = configJson.toNativeUtf8();
    try {
      return _ensureSearchInfraFn(ptr).toDartString();
    } finally {
      malloc.free(ptr);
    }
  }

  @override
  String getSearchProviders() {
    return _getSearchProvidersFn().toDartString();
  }

  @override
  Future<String> webSearch(String handle, String requestJson) {
    return _workerTool(handle, requestJson, 'web_search', const Duration(seconds: 120),
        onTimeout: '{"ok":false,"error":"web_search timed out"}');
  }

  @override
  Future<String> webFetch(String handle, String requestJson) {
    return _workerTool(handle, requestJson, 'web_fetch', const Duration(seconds: 120),
        onTimeout: '{"ok":false,"error":"web_fetch timed out"}');
  }

  // -- browser tool (add-browser-tool) --

  @override
  Future<String> browserAvailable() async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
      'handle': '',
      'requestJson': '',
      'workerType': 'browser_available',
    });
    final result = await receivePort.first.timeout(
      const Duration(seconds: 120),
      onTimeout: () => '{"ok":true,"available":false,"error":"browser_available timed out"}',
    ) as String;
    receivePort.close();
    return result;
  }

  @override
  Future<String> browserNavigate(String handle, String requestJson) =>
      _workerTool(handle, requestJson, 'browser_navigate', const Duration(seconds: 120),
          onTimeout:
              '{"ok":false,"error":"browser_navigate timed out","dead":true}');

  @override
  Future<String> browserClick(String handle, String requestJson) =>
      _workerTool(handle, requestJson, 'browser_click', const Duration(seconds: 120),
          onTimeout: '{"ok":false,"error":"browser_click timed out","dead":true}');

  @override
  Future<String> browserType(String handle, String requestJson) =>
      _workerTool(handle, requestJson, 'browser_type', const Duration(seconds: 120),
          onTimeout: '{"ok":false,"error":"browser_type timed out","dead":true}');

  @override
  Future<String> browserSnapshot(String handle, String requestJson) =>
      _workerTool(handle, requestJson, 'browser_snapshot', const Duration(seconds: 120),
          onTimeout:
              '{"ok":false,"error":"browser_snapshot timed out","dead":true}');

  // -- command tool (add-command-tool) --

  @override
  Future<String> runCommand(String handle, String requestJson) =>
      // 真正的超时判定在 sidecar 里；这里给得比命令自己的上限宽一截，好让超时的
      // 结果由 sidecar 报出来，而不是被这一层抢先掐断。
      _workerTool(handle, requestJson, 'run_command', const Duration(minutes: 11),
          onTimeout:
              '{"ok":false,"error":"命令等待超时：这一层没能等到命令结束（sidecar 侧的超时应当先到）。"}');

  // -- 并发段的 worker 入口（change parallelize-readonly-tool-calls） --

  @override
  Future<String> callToolOnWorker(
      String toolName, String handle, String requestJson) async {
    // 入参形态与同名同步方法一致：`read_file` 像 `readFile` 那样接受裸路径，
    // `list_dir` 本来就是裸路径，其余是请求 JSON。
    var payload = requestJson;
    if (toolName == 'read_file' && !payload.trimLeft().startsWith('{')) {
      payload = '{"path":"${_jsonEscape(payload)}"}';
    }
    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
      'handle': handle,
      'requestJson': payload,
      'workerType': toolName,
    });
    // 这里刻意不加超时：这六个工具原来的同步路径也没有超时，套一层 isolate 不改变
    // "多久算超时"这件事（不发明新数值）。worker 内的任何异常都会回一条错误 JSON。
    final result = await receivePort.first as String;
    receivePort.close();
    return result;
  }

  Future<String> _workerTool(
      String handle, String requestJson, String workerType, Duration timeout,
      {required String onTimeout}) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
      'handle': handle,
      'requestJson': requestJson,
      'workerType': workerType,
    });
    final result = await receivePort.first.timeout(timeout, onTimeout: () => onTimeout)
        as String;
    receivePort.close();
    return result;
  }

  /// Worker isolate entry point for the tool calls that must not block the UI.
  static void _webWorkerMain(Map<String, dynamic> args) {
    final sendPort = args['sendPort'] as SendPort;
    final handle = (args['handle'] as String?) ?? '';
    final requestJson = args['requestJson'] as String;
    final workerType = args['workerType'] as String;

    try {
      final lib = _openLibrary();
      final Pointer<Utf8> handlePtr =
          handle.isEmpty ? nullptr : handle.toNativeUtf8();
      final ptr = requestJson.isEmpty ? null : requestJson.toNativeUtf8();
      try {
        Pointer<Utf8> resultPtr;
        // browser_available / ensure_search_infra take no handle.
        if (workerType == 'browser_available') {
          final fn = lib.lookupFunction<Pointer<Utf8> Function(), BrowserAvailableDart>(
              'browser_available');
          resultPtr = fn();
        } else if (workerType == 'dispose_context') {
          final fn = lib.lookupFunction<DisposeContextNative, DisposeContextDart>(
              'dispose_context');
          resultPtr = fn(handlePtr);
        } else {
          switch (workerType) {
            case 'web_search':
              final fn = lib.lookupFunction<SetWorkspaceNative, WebSearchDart>('web_search');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'web_fetch':
              final fn = lib.lookupFunction<SetWorkspaceNative, WebFetchDart>('web_fetch');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'browser_navigate':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserNavigateDart>(
                  'browser_navigate');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'browser_click':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserClickDart>('browser_click');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'browser_type':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserTypeDart>('browser_type');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'browser_snapshot':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserSnapshotDart>(
                  'browser_snapshot');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'run_command':
              final fn = lib.lookupFunction<SetWorkspaceNative, RunCommandDart>('run_command');
              resultPtr = fn(handlePtr, ptr!);
              break;
            // 并发段的同步只读工具（change parallelize-readonly-tool-calls 任务 4.1）：
            // 每个 isolate 打开的是同一份 sidecar.dll，C++ 侧各自一条线程、返回各走
            // thread_local 槽。
            case 'read_file':
              final fn = lib.lookupFunction<SetWorkspaceNative, ReadFileDart>('read_file');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'list_dir':
              final fn = lib.lookupFunction<SetWorkspaceNative, ListDirDart>('list_dir');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'glob_file':
              final fn = lib.lookupFunction<SetWorkspaceNative, GlobFileDart>('glob_file');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'grep_file':
              final fn = lib.lookupFunction<SetWorkspaceNative, GrepFileDart>('grep_file');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'read_spill':
              final fn = lib.lookupFunction<SetWorkspaceNative, RunCommandDart>('read_spill');
              resultPtr = fn(handlePtr, ptr!);
              break;
            case 'read_image':
              final fn = lib.lookupFunction<SetWorkspaceNative, ReadImageDart>('read_image');
              resultPtr = fn(handlePtr, ptr!);
              break;
            default:
              sendPort.send('{"ok":false,"error":"unknown worker type: $workerType"}');
              return;
          }
        }
        if (resultPtr == nullptr) {
          sendPort.send('{"ok":false,"error":"$workerType: FFI returned null pointer"}');
        } else {
          sendPort.send(resultPtr.toDartString());
        }
      } finally {
        if (handlePtr != nullptr) malloc.free(handlePtr);
        if (ptr != null) malloc.free(ptr);
      }
    } catch (e, st) {
      sendPort.send('{"ok":false,"error":"$workerType isolate error: $e"}');
    }
  }

  // -- internal --

  static DynamicLibrary _openLibrary() {
    if (Platform.isWindows) return DynamicLibrary.open('sidecar.dll');
    if (Platform.isMacOS) return DynamicLibrary.open('libsidecar.dylib');
    if (Platform.isLinux) return DynamicLibrary.open('libsidecar.so');
    throw UnsupportedError('Unsupported platform');
  }
}
