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
typedef OnDoneNative = Void Function(Int32 code, Pointer<Utf8> err, Pointer<Utf8> stopReason);

typedef SendMessageNative = Int32 Function(
  Pointer<Utf8> apiKey,
  Pointer<Utf8> baseUrl,
  Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> messagesJson,
  Pointer<Utf8> toolsJson,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnThinkingNative>> onThinking,
  Pointer<NativeFunction<OnDoneNative>> onDone,
);

typedef SetWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8> path);

// Dart-facing types
typedef SendMessageDart = int Function(
  Pointer<Utf8> apiKey,
  Pointer<Utf8> baseUrl,
  Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> messagesJson,
  Pointer<Utf8> toolsJson,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnThinkingNative>> onThinking,
  Pointer<NativeFunction<OnDoneNative>> onDone,
);

typedef SetWorkspaceDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ReadFileDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef ListDirDart = Pointer<Utf8> Function(Pointer<Utf8> path);

// ---------------------------------------------------------------------------
// Dart-facing callback types
// ---------------------------------------------------------------------------

typedef OnChunkCallback = void Function(String text);
typedef OnToolCallCallback = void Function(String json);
typedef OnThinkingCallback = void Function(String thinkingJson);
typedef OnDoneCallback = void Function(int code, String? error, String? stopReason);

// ---------------------------------------------------------------------------
// SidecarBridge
// ---------------------------------------------------------------------------

class SidecarBridge {
  static SidecarBridge? _instance;

  late final DynamicLibrary _lib;
  late final SetWorkspaceDart _setWorkspaceFn;
  late final ReadFileDart _readFileFn;
  late final ListDirDart _listDirFn;

  SidecarBridge._() {
    _lib = _openLibrary();
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

  // -- non-blocking model call (runs FFI on a worker isolate) --

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
    final receivePort = ReceivePort();

    await Isolate.spawn(_workerMain, {
      'sendPort': receivePort.sendPort,
      'apiKey': apiKey,
      'baseUrl': baseUrl,
      'model': model,
      'systemPrompt': systemPrompt,
      'messagesJson': messagesJson,
      'toolsJson': toolsJson,
    });

    await for (final msg in receivePort) {
      final map = msg as Map<String, dynamic>;
      switch (map['type'] as String) {
        case 'chunk':
          onChunk(map['text'] as String);
        case 'tool_call':
          onToolCall(map['json'] as String);
        case 'thinking':
          onThinking?.call(map['json'] as String);
        case 'done':
          final code = map['code'] as int;
          final error = map['error'] as String?;
          final stopReason = map['stopReason'] as String?;
          onDone(code, error, stopReason);
          receivePort.close();
          return;
      }
    }
  }

  // -- worker isolate entry point --

  static void _workerMain(Map<String, dynamic> args) {
    final sendPort = args['sendPort'] as SendPort;
    final apiKey = args['apiKey'] as String;
    final baseUrl = args['baseUrl'] as String;
    final model = args['model'] as String;
    final systemPrompt = args['systemPrompt'] as String;
    final messagesJson = args['messagesJson'] as String;
    final toolsJson = args['toolsJson'] as String;

    final lib = _openLibrary();
    final sendMessageFn =
        lib.lookupFunction<SendMessageNative, SendMessageDart>('send_message');

    final apiKeyPtr = apiKey.toNativeUtf8();
    final baseUrlPtr = baseUrl.toNativeUtf8();
    final modelPtr = model.toNativeUtf8();
    final systemPromptPtr = systemPrompt.toNativeUtf8();
    final messagesJsonPtr = messagesJson.toNativeUtf8();
    final toolsJsonPtr = toolsJson.toNativeUtf8();

    final onChunkCallable = NativeCallable<OnChunkNative>.listener(
      (Pointer<Utf8> ptr) {
        sendPort.send({'type': 'chunk', 'text': ptr.toDartString()});
      },
    );
    final onToolCallCallable = NativeCallable<OnToolCallNative>.listener(
      (Pointer<Utf8> ptr) {
        sendPort.send({'type': 'tool_call', 'json': ptr.toDartString()});
      },
    );
    final onThinkingCallable = NativeCallable<OnThinkingNative>.listener(
      (Pointer<Utf8> ptr) {
        sendPort.send({'type': 'thinking', 'json': ptr.toDartString()});
      },
    );
    final onDoneCallable = NativeCallable<OnDoneNative>.listener(
      (int code, Pointer<Utf8> errPtr, Pointer<Utf8> stopReasonPtr) {
        final err = errPtr.toDartString();
        final stopReason = stopReasonPtr.toDartString();
        sendPort.send({
          'type': 'done',
          'code': code,
          'error': err.isEmpty ? null : err,
          'stopReason': stopReason.isEmpty ? null : stopReason,
        });
      },
    );

    sendMessageFn(
      apiKeyPtr,
      baseUrlPtr,
      modelPtr,
      systemPromptPtr,
      messagesJsonPtr,
      toolsJsonPtr,
      onChunkCallable.nativeFunction,
      onToolCallCallable.nativeFunction,
      onThinkingCallable.nativeFunction,
      onDoneCallable.nativeFunction,
    );

    malloc.free(apiKeyPtr);
    malloc.free(baseUrlPtr);
    malloc.free(modelPtr);
    malloc.free(systemPromptPtr);
    malloc.free(messagesJsonPtr);
    malloc.free(toolsJsonPtr);

    // Schedule cleanup after queued callbacks have fired on this isolate
    Timer.run(() {
      onChunkCallable.close();
      onToolCallCallable.close();
      onThinkingCallable.close();
      onDoneCallable.close();
    });
  }

  // -- tools (run on main isolate — they're fast, local calls) --

  String? setWorkspace(String path) {
    final ptr = path.toNativeUtf8();
    final resultPtr = _setWorkspaceFn(ptr);
    malloc.free(ptr);
    final result = resultPtr.toDartString();
    return result.isEmpty ? null : result;
  }

  String readFile(String path) {
    final ptr = path.toNativeUtf8();
    final resultPtr = _readFileFn(ptr);
    malloc.free(ptr);
    return resultPtr.toDartString();
  }

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
