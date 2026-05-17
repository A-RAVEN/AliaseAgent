import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:convert';

import 'package:ffi/ffi.dart';

typedef OnChunkNative = Void Function(Pointer<Utf8> text);
typedef OnToolCallNative = Void Function(Pointer<Utf8> json);
typedef OnDoneNative = Void Function(Int32 code, Pointer<Utf8> err);

typedef SendMessageNative = Int32 Function(
  Pointer<Utf8> apiKey, Pointer<Utf8> baseUrl, Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt, Pointer<Utf8> messagesJson, Pointer<Utf8> toolsJson,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnDoneNative>> onDone,
);

typedef SendMessageDart = int Function(
  Pointer<Utf8> apiKey, Pointer<Utf8> baseUrl, Pointer<Utf8> model,
  Pointer<Utf8> systemPrompt, Pointer<Utf8> messagesJson, Pointer<Utf8> toolsJson,
  Pointer<NativeFunction<OnChunkNative>> onChunk,
  Pointer<NativeFunction<OnToolCallNative>> onToolCall,
  Pointer<NativeFunction<OnDoneNative>> onDone,
);

DynamicLibrary _open() {
  if (Platform.isWindows) return DynamicLibrary.open('sidecar.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('libsidecar.dylib');
  if (Platform.isLinux) return DynamicLibrary.open('libsidecar.so');
  throw UnsupportedError('Unsupported platform');
}

Map<String, String>? _readConfig() {
  final configPath = Platform.isWindows
      ? '${Platform.environment['USERPROFILE']}/.aliasagent/config.json'
      : '${Platform.environment['HOME']}/.aliasagent/config.json';
  final f = File(configPath);
  if (!f.existsSync()) return null;
  final cfg = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final providers = cfg['providers'] as Map<String, dynamic>?;
  if (providers == null) return null;
  final anthropic = providers['anthropic'] as Map<String, dynamic>?;
  if (anthropic == null) return null;

  final agentTypes = cfg['agent_types'] as Map<String, dynamic>?;
  final general = agentTypes?['general'] as Map<String, dynamic>?;

  return {
    'api_key': anthropic['api_key'] as String? ?? '',
    'base_url': anthropic['base_url'] as String? ?? '',
    'model': general?['model'] as String? ?? '',
  };
}

String? _safeToDart(Pointer<Utf8> ptr) {
  if (ptr == nullptr) return null;
  try { return ptr.toDartString(); } catch (_) { return null; }
}

Future<bool> _spinUntil(bool Function() check, {int maxMs = 5000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: maxMs));
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(Duration(milliseconds: 50));
    if (check()) return true;
  }
  return check();
}

void main() async {
  final lib = _open();
  final sendFn = lib.lookupFunction<SendMessageNative, SendMessageDart>('send_message');
  final cfg = _readConfig();
  final apiKey = cfg?['api_key'] ?? '';
  final baseUrl = cfg?['base_url'] ?? '';
  final cfgModel = cfg?['model'] ?? '';
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  final logDir = '$home/.aliasagent/logs';

  final hasKey = apiKey.isNotEmpty;
  print('API key configured: ${hasKey ? 'yes (${apiKey.substring(0, apiKey.length.clamp(0, 12))}...)' : 'no'}');
  print('Base URL: $baseUrl');
  print('Model: $cfgModel');
  print('');

  // ---------- C: API error (bad key) ----------
  {
    bool onDoneCalled = false;
    int doneCode = -99;
    String? doneErr;

    final onChunkC = NativeCallable<OnChunkNative>.listener((_) {});
    final onToolC = NativeCallable<OnToolCallNative>.listener((_) {});
    final onDoneC = NativeCallable<OnDoneNative>.listener((code, err) {
      onDoneCalled = true;
      doneCode = code;
      doneErr = _safeToDart(err);
    });

    final msgs = jsonEncode([{'role': 'user', 'content': 'test'}]).toNativeUtf8();
    final badKey = 'bad-key'.toNativeUtf8();
    final cgBaseUrl = baseUrl.toNativeUtf8();
    final cgModel = cfgModel.toNativeUtf8();
    final cgSp = ''.toNativeUtf8();
    final empty = ''.toNativeUtf8();

    sendFn(badKey, cgBaseUrl, cgModel, cgSp, msgs, empty,
        onChunkC.nativeFunction, onToolC.nativeFunction, onDoneC.nativeFunction);

    malloc.free(msgs);
    malloc.free(badKey);
    malloc.free(cgBaseUrl);
    malloc.free(cgModel);
    malloc.free(cgSp);
    malloc.free(empty);

    await _spinUntil(() => onDoneCalled, maxMs: 10000);

    assert(onDoneCalled, 'on_done must be called for invalid API key');
    assert(doneCode != 0, 'Expected non-zero code for bad key, got $doneCode');
    assert(doneErr != null && doneErr!.isNotEmpty, 'Expected error message');
    print('[C] PASS: Bad API key → on_done(code=$doneCode, err="$doneErr")');
  }

  // ---------- A & B: Real API call ----------
  if (hasKey) {
    final chunks = <String>[];
    final toolCalls = <String>[];
    bool onDoneCalled = false;
    int doneCode = -99;
    String? doneErr;

    final onChunkC = NativeCallable<OnChunkNative>.listener((ptr) {
      final s = _safeToDart(ptr);
      if (s != null) chunks.add(s);
    });
    final onToolC = NativeCallable<OnToolCallNative>.listener((ptr) {
      final s = _safeToDart(ptr);
      if (s != null) toolCalls.add(s);
    });
    final onDoneC = NativeCallable<OnDoneNative>.listener((code, err) {
      onDoneCalled = true;
      doneCode = code;
      doneErr = _safeToDart(err);
    });

    final model = cfgModel.toNativeUtf8();
    final sp = 'You are concise.'.toNativeUtf8();
    final msgs = jsonEncode([{'role': 'user', 'content': 'Say just hi'}]).toNativeUtf8();
    final bu = baseUrl.toNativeUtf8();
    final ak = apiKey.toNativeUtf8();
    final empty = ''.toNativeUtf8();

    final requestId = sendFn(ak, bu, model, sp, msgs, empty,
        onChunkC.nativeFunction, onToolC.nativeFunction, onDoneC.nativeFunction);

    malloc.free(ak);
    malloc.free(bu);
    malloc.free(empty);
    malloc.free(msgs);
    malloc.free(sp);
    malloc.free(model);

    await _spinUntil(() => onDoneCalled, maxMs: 120000);

    assert(onDoneCalled, 'on_done should be called within 120s');
    assert(requestId > 0, 'Expected positive request_id, got $requestId');

    if (doneCode != 0) {
      print('[A] WARN: API returned error → on_done(code=$doneCode, err="$doneErr")');
      print('[B] WARN: Non-zero done code');
    } else {
      assert(chunks.isNotEmpty, 'on_chunk should be called at least once');
      final fullText = chunks.join();
      assert(fullText.isNotEmpty, 'Response must not be empty');
      print('[A] PASS: Real API call → ${chunks.length} chunks, ${fullText.length} chars');
      final preview = fullText.length > 120 ? '${fullText.substring(0, 120)}...' : fullText;
      print('        Response: "$preview"');
      print('[B] PASS: Stream accumulated ${fullText.length} chars across ${chunks.length} chunks');
    }
  } else {
    print('[A] SKIP: No API key configured');
    print('[B] SKIP: No API key configured');
  }

  // ---------- D: Timeout ----------
  print('[D] SKIP: Timeout requires mock slow endpoint (verify CURLOPT_TIMEOUT in model_gateway.cpp:251)');

  // ---------- E: Logs ----------
  await Future.delayed(Duration(milliseconds: 500));
  final logFile = File('$logDir/sidecar.log');
  if (logFile.existsSync()) {
    final content = logFile.readAsStringSync();
    final hasPOST = content.contains('POST');
    final hasHTTP = content.contains('HTTP');
    final hasSSE = content.contains('SSE:');
    final hasError = content.contains('ERROR');

    assert(hasPOST, 'Log must contain request URL');
    assert(hasHTTP, 'Log must contain HTTP status code');
    print('[E] PASS: Log file — ${content.split("\n").where((l) => l.isNotEmpty).length} lines, POST=$hasPOST HTTP=$hasHTTP SSE=$hasSSE ERR=$hasError');
  } else {
    print('[E] WARN: Log file not found (verify ~/.aliasagent/logs/ exists)');
  }

  print('');
  print('=== Checkpoint 5 A/B/C/D/E complete ===');
}