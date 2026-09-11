import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Native C function signatures (must match sidecar_api.h exactly)
// ---------------------------------------------------------------------------

typedef OnChunkNative = Void Function(Pointer<Utf8> text);
typedef OnToolCallNative = Void Function(Pointer<Utf8> json);
typedef OnThinkingNative = Void Function(Pointer<Utf8> thinkingJson);
typedef OnDoneNative = Void Function(Int32 code, Pointer<Utf8> err, Pointer<Utf8> stopReason, Int32 inputTokens, Int32 outputTokens);

typedef SendMessageNative = Int32 Function(
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

typedef SetWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef CancelRequestNative = Void Function(Int32 requestId);

// Dart-facing types
typedef SendMessageDart = int Function(
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

typedef SetWorkspaceDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ReadFileDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ListDirDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef EnsureSearchInfraDart = Pointer<Utf8> Function(Pointer<Utf8> configJson);
typedef GetSearchProvidersDart = Pointer<Utf8> Function();
typedef WebSearchDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef WebFetchDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef BrowserAvailableDart = Pointer<Utf8> Function();
typedef BrowserNavigateDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef BrowserClickDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef BrowserTypeDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef BrowserSnapshotDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef WriteFileDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef EditFileDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef GlobFileDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef GrepFileDart = Pointer<Utf8> Function(Pointer<Utf8> requestJson);
typedef CancelRequestDart = void Function(int requestId);

// ---------------------------------------------------------------------------
// Dart-facing callback types
// ---------------------------------------------------------------------------

typedef OnChunkCallback = void Function(String text);
typedef OnToolCallCallback = void Function(String json);
typedef OnThinkingCallback = void Function(String thinkingJson);
typedef OnDoneCallback = void Function(int code, String? error, String? stopReason,
    int? inputTokens, int? outputTokens);

// ---------------------------------------------------------------------------
// ISidecar — abstract interface for sidecar communication
// ---------------------------------------------------------------------------

abstract class ISidecar {
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
  });

  /// Cancel the in-flight send_message request (if any). Thread-safe, returns
  /// immediately; no-op when idle. The C++ side aborts the stream and delivers
  /// on_done(-1, "cancelled") before the request returns.
  void cancelRequest();

  String? setWorkspace(String path);
  String readFile(String requestJson);
  String listDir(String path);

  // File edit tools
  String writeFile(String requestJson);
  String editFile(String requestJson);

  // Ripgrep-backed search tools
  String globFile(String requestJson);
  String grepFile(String requestJson);

  // Search & web fetch
  String ensureSearchInfra(String configJson);
  String getSearchProviders();
  Future<String> webSearch(String requestJson);
  Future<String> webFetch(String requestJson);

  // Browser tool (add-browser-tool) — persistent headed Edge worker.
  // browserAvailable probes Playwright + a usable Edge/Chromium at declaration
  // time; the ops drive multi-step browsing on a persistent session.
  Future<String> browserAvailable();
  Future<String> browserNavigate(String requestJson);
  Future<String> browserClick(String requestJson);
  Future<String> browserType(String requestJson);
  Future<String> browserSnapshot(String requestJson);
}

// ---------------------------------------------------------------------------
// SidecarBridge
// ---------------------------------------------------------------------------

class SidecarBridge implements ISidecar {
  static SidecarBridge? _instance;

  late final DynamicLibrary _lib;
  late final SetWorkspaceDart _setWorkspaceFn;
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
  late final CancelRequestDart _cancelRequestFn;

  // Serialization gate (D3): all sendMessage calls execute strictly one at a
  // time. A new request starts only after the previous request's done callback
  // has been processed by this isolate — which is exactly what the C++ side's
  // pending_strings cleanup barrier (D3) depends on.
  Future<void>? _chain;

  // Request-id targeted cancel (design D8). Every sendMessage is assigned a
  // unique monotonically increasing id BEFORE it is enqueued, and that id is
  // passed to the C++ `send_message` so cancel_request(id) can abort the SPECIFIC
  // request (even one only enqueued / not yet running — a global flag cannot,
  // because execute() resets it). `_lastRequestId` is the most recently enqueued
  // request: at a user-send preempt it is the background fold's current request,
  // so cancelRequest() targets exactly that and never the user's own request.
  int _nextRequestId = 1;
  int? _lastRequestId;
  // Count of requests enqueued but not yet resolved. cancelRequest() only cancels
  // when >0 — so it never targets an ALREADY-COMPLETED request id, which would
  // otherwise leave a stale cancel_request_id latched in the C++ gateway (poison
  // on a later hot-restart id reuse). See model_gateway cancel_request_id.
  int _pendingRequests = 0;

  SidecarBridge._() {
    _lib = _openLibrary();
    _setWorkspaceFn =
        _lib.lookupFunction<SetWorkspaceNative, SetWorkspaceDart>('set_workspace');
    _readFileFn =
        _lib.lookupFunction<SetWorkspaceNative, ReadFileDart>('read_file');
    _listDirFn =
        _lib.lookupFunction<SetWorkspaceNative, ListDirDart>('list_dir');
    _ensureSearchInfraFn =
        _lib.lookupFunction<SetWorkspaceNative, EnsureSearchInfraDart>('ensure_search_infra');
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
    _cancelRequestFn =
        _lib.lookupFunction<CancelRequestNative, CancelRequestDart>('cancel_request');
  }

  static SidecarBridge get instance {
    _instance ??= SidecarBridge._();
    return _instance!;
  }

  // -- non-blocking model call (FFI runs on a worker isolate; callbacks are
  //    delivered to THIS isolate in real-time via NativeCallable) --

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
  }) {
    // Assign a unique id BEFORE enqueueing so cancel_request(id) can target this
    // request even while it is queued / not yet running (design D8).
    final requestId = _nextRequestId++;
    _lastRequestId = requestId;
    _pendingRequests++;
    return _enqueue(() => _sendMessageInner(
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
  }

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final prev = _chain ?? Future<void>.value();
    final result = prev.then((_) => task());
    // Keep the chain alive even if this request errors
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  void cancelRequest() {
    // Request-id targeted cancel (design D8): cancel the most recently enqueued
    // request. At a user-send preempt this is the background fold's current
    // request, so it aborts that — never the user's own request (assigned a
    // different id after the preempt). No-op when NO request is pending: if we
    // cancelled a stale/completed id it would latch cancel_request_id in C++
    // (uncleared -> a later hot-restart id reuse spuriously cancels). Only a LIVE
    // (enqueued/running) request has a meaningful id to cancel.
    if (_pendingRequests <= 0) return;
    final id = _lastRequestId;
    if (id != null && id != 0) _cancelRequestFn(id);
  }

  Future<void> _sendMessageInner({
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
    // ---- NativeCallable listeners created on THIS isolate (D2) -----------
    // .listener callbacks are delivered to the creating isolate's event loop.
    // The C++ curl thread invokes them in real-time during the stream; the
    // messages land directly on this isolate's queue (previously they were
    // queued behind the worker isolate blocked in the FFI call).
    final completer = Completer<void>();
    var finished = false;
    var timedOut = false;

    // late final: finish() closes the callables, and the done callable invokes
    // finish() — the closures only run asynchronously, after assignment.
    late final NativeCallable<OnChunkNative> onChunkCallable;
    late final NativeCallable<OnToolCallNative> onToolCallCallable;
    late final NativeCallable<OnThinkingNative> onThinkingCallable;
    late final NativeCallable<OnDoneNative> onDoneCallable;

    void finish(int code, String error, String stopReason, int inputTokens,
        int outputTokens,
        {bool closeCallables = true}) {
      if (finished) return; // idempotent: ignore duplicate done (F5)
      finished = true;
      // This request is now complete — decrement BEFORE onDone fires, so a caller
      // (e.g. _endStreaming) that invokes cancelRequest() from the onDone callback
      // sees no pending request and does NOT latch a stale/completed id in C++.
      _pendingRequests--;
      // Close callables only after a real done (success or cancellation):
      // by the time this callback is processed, the curl thread has already
      // terminated (done is its last action before join), so no callback can
      // fire after close (F6). The defensive fallback path (9.3) passes
      // closeCallables: false — if the cancel path failed to terminate the
      // curl thread within the fallback window, closing would be UB while it
      // may still invoke callbacks; leaking the callables is the safe trade-off.
      if (closeCallables) {
        Timer.run(() {
          onChunkCallable.close();
          onToolCallCallable.close();
          onThinkingCallable.close();
          onDoneCallable.close();
        });
      }
      completer.complete();
      onDone(code,
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

    // ---- Worker isolate: rebuild pointers from addresses, call FFI --------
    await Isolate.spawn(_workerMain, {
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

    // ---- Timeout: real cancellation, never a fake done (8.5) --------------
    // On timeout we ask the C++ side to abort; the curl thread then delivers
    // on_done(-1, "cancelled") which flows through finish() above — the bridge
    // closes callables only after that real done.
    final timeoutTimer = Timer(const Duration(seconds: 120), () {
      if (finished) return;
      timedOut = true;
      // ignore: avoid_print
      print('[SidecarBridge] request #$requestId timed out after 120s — cancelling');
      _cancelRequestFn(requestId);
      // Fallback in case the cancel path never delivers a done (defensive).
      // closeCallables: false (9.3) — the curl thread may still be alive if
      // cancellation failed to terminate it; closing would be UB. We complete
      // the Future and surface the error; any late real done is ignored by
      // finish()'s idempotency guard, and the callables are deliberately
      // leaked (safe) rather than closed (UB).
      // Residual window (11.3, R3-F2): if the stuck request eventually
      // completes after this fallback released the gate, its post-perform
      // done delivers an error string through the C++ pending_strings pool —
      // which a NEW request's execute() clears under request_mutex while this
      // old done message is still queued on the main isolate (the D3 barrier
      // is broken by the fallback). The listener would then read freed
      // memory. Accepted as a documented low-probability edge (requires
      // cancel to fail completely + the stuck request to terminate >30s
      // later + a new message in between); not structurally fixable without
      // request-scoped string ownership, which is out of scope.
      final fallback = Timer(const Duration(seconds: 30), () {
        if (!finished) {
          // ignore: avoid_print
          print('[SidecarBridge] FALLBACK: no done 30s after cancel — '
              'releasing gate without closing callables (leaked, 10.3)');
          finish(-1, 'Request timed out after 120s (no done after cancel)', '',
              0, 0, closeCallables: false);
        }
      });
      completer.future.whenComplete(fallback.cancel);
    });

    await completer.future;
    timeoutTimer.cancel();
  }

  // -- worker isolate entry point (FFI call only; callbacks bypass the worker)

  static void _workerMain(Map<String, dynamic> args) {
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

    // Rebuild native function pointers from their addresses (D2): the address
    // integer is trivially sendable across isolates, the Pointer object itself
    // has no documented sendability guarantee.
    final onChunkPtr = Pointer<NativeFunction<OnChunkNative>>.fromAddress(onChunkAddr);
    final onToolCallPtr = Pointer<NativeFunction<OnToolCallNative>>.fromAddress(onToolCallAddr);
    final onThinkingPtr = Pointer<NativeFunction<OnThinkingNative>>.fromAddress(onThinkingAddr);
    final onDonePtr = Pointer<NativeFunction<OnDoneNative>>.fromAddress(onDoneAddr);

    // Fast-fail (9.6): any Dart exception in this worker (DLL load, symbol
    // lookup, FFI call) would otherwise kill the isolate silently, leaving
    // the serialization gate stalled until the 120s+30s timeout. Deliver a
    // synthetic done(-1) through the on_done pointer instead so the gate
    // releases immediately and the UI surfaces the real error.
    try {
      final lib = _openLibrary();
      final sendMessageFn =
          lib.lookupFunction<SendMessageNative, SendMessageDart>('send_message');

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
        // NEVER free these strings (R2-F1 fix): the NativeCallable listener
        // reads them asynchronously on the main isolate's event loop after
        // this worker has already exited — freeing here is a use-after-free.
        // A deliberate leak on this (rare) error path mirrors the C++ side's
        // pending_strings lifetime approach.
        final errPtr = e.toString().toNativeUtf8();
        // A nullptr stopReason would make the listener's toDartString() throw
        // (ffi's toDartString rejects nullptr), swallowing the done delivery
        // and stalling the gate until the 150s fallback. Pass a non-null
        // (deliberately leaked) empty string instead.
        final stopPtr = ''.toNativeUtf8();
        onDoneDart(-1, errPtr, stopPtr, 0, 0);
      } catch (_) {
        // Nothing more we can do — the 120s+30s timeout path still releases
        // the gate as a last resort.
      }
    }
  }

  // -- tools (run on main isolate — they're fast, local calls) --

  @override
  String? setWorkspace(String path) {
    final ptr = path.toNativeUtf8();
    final resultPtr = _setWorkspaceFn(ptr);
    malloc.free(ptr);
    final result = resultPtr.toDartString();
    return result.isEmpty ? null : result;
  }

  @override
  String readFile(String requestJson) {
    // If input doesn't look like JSON, wrap it as {"path":"..."}
    final json = requestJson.trimLeft().startsWith('{')
        ? requestJson
        : '{"path":"${_jsonEscape(requestJson)}"}';
    final ptr = json.toNativeUtf8();
    final resultPtr = _readFileFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  @override
  String writeFile(String requestJson) {
    final ptr = requestJson.toNativeUtf8();
    final resultPtr = _writeFileFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  @override
  String editFile(String requestJson) {
    final ptr = requestJson.toNativeUtf8();
    final resultPtr = _editFileFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  @override
  String globFile(String requestJson) {
    final ptr = requestJson.toNativeUtf8();
    final resultPtr = _globFileFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  @override
  String grepFile(String requestJson) {
    final ptr = requestJson.toNativeUtf8();
    final resultPtr = _grepFileFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
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
  String listDir(String path) {
    final ptr = path.toNativeUtf8();
    final resultPtr = _listDirFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  // -- search & web fetch (task 8.7) --

  @override
  String ensureSearchInfra(String configJson) {
    final ptr = configJson.toNativeUtf8();
    final resultPtr = _ensureSearchInfraFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  @override
  String getSearchProviders() {
    final resultPtr = _getSearchProvidersFn();
    return resultPtr.toDartString();
  }

  @override
  Future<String> webSearch(String requestJson) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
      'requestJson': requestJson,
      'workerType': 'web_search',
    });
    final result = await receivePort.first.timeout(
      const Duration(seconds: 120),
      onTimeout: () => '{"ok":false,"error":"web_search timed out"}',
    ) as String;
    receivePort.close();
    return result;
  }

  @override
  Future<String> webFetch(String requestJson) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
      'requestJson': requestJson,
      'workerType': 'web_fetch',
    });
    final result = await receivePort.first.timeout(
      const Duration(seconds: 120),
      onTimeout: () => '{"ok":false,"error":"web_fetch timed out"}',
    ) as String;
    receivePort.close();
    return result;
  }

  // -- browser tool (add-browser-tool) --

  @override
  Future<String> browserAvailable() async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
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
  Future<String> browserNavigate(String requestJson) async => _browserOp(requestJson, 'browser_navigate');

  @override
  Future<String> browserClick(String requestJson) async => _browserOp(requestJson, 'browser_click');

  @override
  Future<String> browserType(String requestJson) async => _browserOp(requestJson, 'browser_type');

  @override
  Future<String> browserSnapshot(String requestJson) async => _browserOp(requestJson, 'browser_snapshot');

  Future<String> _browserOp(String requestJson, String workerType) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_webWorkerMain, {
      'sendPort': receivePort.sendPort,
      'requestJson': requestJson,
      'workerType': workerType,
    });
    final result = await receivePort.first.timeout(
      const Duration(seconds: 120),
      onTimeout: () => '{"ok":false,"error":"$workerType timed out","dead":true}',
    ) as String;
    receivePort.close();
    return result;
  }

  /// Worker isolate entry point for web_search / web_fetch (tasks 8.5, 8.8)
  static void _webWorkerMain(Map<String, dynamic> args) {
    final sendPort = args['sendPort'] as SendPort;
    final requestJson = args['requestJson'] as String;
    final workerType = args['workerType'] as String;

    try {
      final lib = _openLibrary();
      final ptr = requestJson.isEmpty ? null : requestJson.toNativeUtf8();
      try {
        Pointer<Utf8> resultPtr;
        // browser_available takes no request JSON; its FFI signature is () -> ptr.
        if (workerType == 'browser_available') {
          final fn = lib.lookupFunction<Pointer<Utf8> Function(), BrowserAvailableDart>(
              'browser_available');
          resultPtr = fn();
        } else {
          switch (workerType) {
            case 'web_search':
              final fn = lib.lookupFunction<SetWorkspaceNative, WebSearchDart>('web_search');
              resultPtr = fn(ptr!);
              break;
            case 'web_fetch':
              final fn = lib.lookupFunction<SetWorkspaceNative, WebFetchDart>('web_fetch');
              resultPtr = fn(ptr!);
              break;
            case 'browser_navigate':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserNavigateDart>(
                  'browser_navigate');
              resultPtr = fn(ptr!);
              break;
            case 'browser_click':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserClickDart>('browser_click');
              resultPtr = fn(ptr!);
              break;
            case 'browser_type':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserTypeDart>('browser_type');
              resultPtr = fn(ptr!);
              break;
            case 'browser_snapshot':
              final fn = lib.lookupFunction<SetWorkspaceNative, BrowserSnapshotDart>(
                  'browser_snapshot');
              resultPtr = fn(ptr!);
              break;
            default:
              sendPort.send('{"ok":false,"error":"unknown worker type: $workerType"}');
              return;
          }
        }
        // Guard against null pointer — ffi's toDartString() rejects nullptr
        // with UnsupportedError (11.2); dereferencing the result would crash
        if (resultPtr == nullptr) {
          sendPort.send('{"ok":false,"error":"$workerType: FFI returned null pointer"}');
        } else {
          sendPort.send(resultPtr.toDartString());
        }
      } finally {
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
