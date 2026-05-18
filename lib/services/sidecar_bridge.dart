import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// 4.1 — Native C function signatures (must match sidecar_api.h exactly)
// ---------------------------------------------------------------------------

// C-side native types (Int32, Void, etc.) — used with NativeCallable and
// as the first type parameter to lookupFunction.
typedef OnChunkNative = Void Function(Pointer<Utf8> text);
typedef OnToolCallNative = Void Function(Pointer<Utf8> json);
typedef OnDoneNative = Void Function(Int32 code, Pointer<Utf8> err);

typedef SendMessageNative = Int32 Function(
  Pointer<Utf8> apiKey,
  Pointer<Utf8> baseUrl,
  Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> messagesJson,
  Pointer<Utf8> toolsJson,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnDoneNative>> onDone,
);

typedef SetWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8> path);

// Dart-facing types (int, void) — the second type parameter to lookupFunction.
typedef SendMessageDart = int Function(
  Pointer<Utf8> apiKey,
  Pointer<Utf8> baseUrl,
  Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> messagesJson,
  Pointer<Utf8> toolsJson,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnDoneNative>> onDone,
);

typedef SetWorkspaceDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ReadFileDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ListDirDart = Pointer<Utf8> Function(Pointer<Utf8> path);

// ---------------------------------------------------------------------------
// 4.2 — Dart-facing callback types
// ---------------------------------------------------------------------------

typedef OnChunkCallback = void Function(String text);
typedef OnToolCallCallback = void Function(String json);
typedef OnDoneCallback = void Function(int code, String? error);

// ---------------------------------------------------------------------------
// 4.3 & 4.4 — SidecarBridge with callback marshaling
// ---------------------------------------------------------------------------

class SidecarBridge {
  static SidecarBridge? _instance;

  late final DynamicLibrary _lib;
  late final SendMessageDart _sendMessageFn;
  late final SetWorkspaceDart _setWorkspaceFn;
  late final ReadFileDart _readFileFn;
  late final ListDirDart _listDirFn;

  SidecarBridge._() {
    _lib = _openLibrary();
    _sendMessageFn =
        _lib.lookupFunction<SendMessageNative, SendMessageDart>('send_message');
    _setWorkspaceFn =
        _lib.lookupFunction<SetWorkspaceNative, SetWorkspaceDart>('set_workspace');
    _readFileFn =
        _lib.lookupFunction<SetWorkspaceNative, ReadFileDart>('read_file');
    _listDirFn =
        _lib.lookupFunction<SetWorkspaceNative, ListDirDart>('list_dir');
  }

  static SidecarBridge get instance {
    _instance ??= SidecarBridge._();
    return _instance!;
  }

  // -- public API --

  /// Send a message to the model. Blocks until the C++ side completes.
  /// Callbacks are invoked synchronously before this method returns.
  int sendMessage({
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    required OnDoneCallback onDone,
  }) {
    final apiKeyPtr = apiKey.toNativeUtf8();
    final baseUrlPtr = baseUrl.toNativeUtf8();
    final modelPtr = model.toNativeUtf8();
    final systemPromptPtr = systemPrompt.toNativeUtf8();
    final messagesJsonPtr = messagesJson.toNativeUtf8();
    final toolsJsonPtr = toolsJson.toNativeUtf8();

    // 4.4 — NativeCallable.listener marshals Dart closures to C function
    // pointers and delivers callbacks from any thread to this isolate's
    // event loop.
    final onChunkCallable = NativeCallable<OnChunkNative>.listener((ptr) {
      onChunk(ptr.toDartString());
    });
    final onToolCallCallable = NativeCallable<OnToolCallNative>.listener((ptr) {
      onToolCall(ptr.toDartString());
    });
    final onDoneCallable = NativeCallable<OnDoneNative>.listener((code, ptr) {
      final err = ptr.toDartString();
      onDone(code, err.isEmpty ? null : err);
    });

    final result = _sendMessageFn(
      apiKeyPtr,
      baseUrlPtr,
      modelPtr,
      systemPromptPtr,
      messagesJsonPtr,
      toolsJsonPtr,
      onChunkCallable.nativeFunction,
      onToolCallCallable.nativeFunction,
      onDoneCallable.nativeFunction,
    );

    malloc.free(apiKeyPtr);
    malloc.free(baseUrlPtr);
    malloc.free(modelPtr);
    malloc.free(systemPromptPtr);
    malloc.free(messagesJsonPtr);
    malloc.free(toolsJsonPtr);

    // NativeCallables stay alive for the duration of the synchronous call;
    // all callbacks have fired by the time sendMessage returns.

    return result;
  }

  /// Returns null on success, or an error message on failure.
  String? setWorkspace(String path) {
    final ptr = path.toNativeUtf8();
    final resultPtr = _setWorkspaceFn(ptr);
    malloc.free(ptr);
    final result = resultPtr.toDartString();
    return result.isEmpty ? null : result;
  }

  /// Read a file within the workspace.
  /// Returns JSON: {"ok":true,"content":"..."} or {"ok":false,"error":"..."}
  String readFile(String path) {
    final ptr = path.toNativeUtf8();
    final resultPtr = _readFileFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  /// List directory contents within the workspace.
  /// Returns JSON: {"ok":true,"entries":[...]} or {"ok":false,"error":"..."}
  String listDir(String path) {
    final ptr = path.toNativeUtf8();
    final resultPtr = _listDirFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

  // -- internal --

  static DynamicLibrary _openLibrary() {
    if (Platform.isWindows) return DynamicLibrary.open('sidecar.dll');
    if (Platform.isMacOS) return DynamicLibrary.open('libsidecar.dylib');
    if (Platform.isLinux) return DynamicLibrary.open('libsidecar.so');
    throw UnsupportedError('Unsupported platform');
  }
}