import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

/// SSE mock server for real-bridge tests. Streams a response body in chunks
/// with configurable delay, records request arrival times.
class _SseServer {
  final List<DateTime> requestTimes = [];

  ServerSocket? _socket;
  Timer? _writer;

  int get port => _socket!.port;

  Future<void> start(String body, {int chunkSize = 64, int delayMs = 50}) async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket!.listen((client) {
      _client = client;
      client.listen((data) {
        if (!utf8.decode(data, allowMalformed: true).contains('\r\n\r\n')) {
          return;
        }
        requestTimes.add(DateTime.now());
        // Swallow async socket errors (e.g. curl aborting mid-stream) — they
        // would otherwise surface as uncaught zone errors and fail the test.
        unawaited(client.done.catchError((_) {}));
        client.write('HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream\r\n'
            'Transfer-Encoding: chunked\r\n\r\n');
        var pos = 0;
        _writer = Timer.periodic(Duration(milliseconds: delayMs), (timer) {
          if (pos >= body.length) {
            timer.cancel();
            _writer = null;
            try {
              client.write('0\r\n\r\n');
              client.close();
            } catch (_) {}
            return;
          }
          final n =
              chunkSize < (body.length - pos) ? chunkSize : (body.length - pos);
          try {
            client.write('${n.toRadixString(16)}\r\n');
            client.write(body.substring(pos, pos + n));
            client.write('\r\n');
          } catch (_) {
            // Client (curl) aborted the connection — stop streaming
            timer.cancel();
            _writer = null;
          }
          pos += n;
        });
      }, onDone: _stopWriter, onError: (_) => _stopWriter());
    });
  }

  void _stopWriter() {
    _writer?.cancel();
    _writer = null;
  }

  Future<void> close() async {
    // CRITICAL: cancel the writer AND close the client socket. If the stream
    // has not fully flushed (no trailing 0-chunk), leaving the client open
    // keeps curl blocked in read() forever — the C++ execute() then never
    // returns and its request_mutex deadlocks every later request.
    _stopWriter();
    try {
      await _client?.close();
    } catch (_) {
      // Client may already be gone (e.g. curl aborted the connection)
    }
    try {
      await _socket?.close();
    } catch (_) {}
  }

  Socket? _client;
}

void main() {
  // change add-context-handles：模型请求也按上下文句柄归属。
  const ctxA = 'realtime-a';
  const ctxB = 'realtime-b';

  setUpAll(() async {
    await SidecarBridge.instance.ensureContext(ctxA);
    await SidecarBridge.instance.ensureContext(ctxB);
  });

  group('SidecarBridge real-time behaviors (real DLL)', () {
    test('callbacks arrive in real-time before the stream completes', () async {
      final body =
          'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"incr"}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}\n\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final server = _SseServer();
      await server.start(body, chunkSize: 32, delayMs: 150); // ~1s stream

      final bridge = SidecarBridge.instance;
      final deltas = <String>[];
      final done = Completer<void>();

      final req = bridge.sendMessage(
        handle: ctxA,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"hi"}]',
        toolsJson: '',
        thinkingMode: 'adaptive',
        thinkingEffort: 'high',
        onChunk: (_) {},
        onToolCall: (_) {},
        onThinking: (json) => deltas.add(json),
        onDone: (code, err, stop, _, _) {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future.timeout(const Duration(seconds: 10));
      await req.timeout(const Duration(seconds: 10));
      expect(deltas.any((j) => j.contains('"thinking_delta"')), isTrue);
      expect(deltas.any((j) => j.contains('"type":"thinking"')), isTrue);
      await server.close();
    });

    test('done fires exactly once when message_stop and [DONE] both present',
        () async {
      final body =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}\n\n'
          'data: {"type":"message_stop"}\n\n'
          'data: [DONE]\n\n';
      final server = _SseServer();
      await server.start(body, chunkSize: 1024, delayMs: 10);

      final bridge = SidecarBridge.instance;
      var doneCount = 0;
      int? doneCode;

      await bridge.sendMessage(
        handle: ctxA,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"hi"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (code, err, stop, _, _) {
          doneCount++;
          doneCode = code;
        },
      );

      expect(doneCount, 1); // idempotent done (message_stop + [DONE])
      expect(doneCode, 0);
      await server.close();
    });

    test('cancelRequest aborts the stream and delivers done(-1, cancelled)',
        () async {
      // ~10s stream if uncancelled
      final body =
          'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a"}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"b"}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}\n\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final server = _SseServer();
      await server.start(body, chunkSize: 32, delayMs: 200);

      final bridge = SidecarBridge.instance;
      final done = Completer<void>();
      int? doneCode;
      String? doneErr;

      final req = bridge.sendMessage(
        handle: ctxA,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"hi"}]',
        toolsJson: '',
        thinkingMode: 'adaptive',
        thinkingEffort: 'high',
        onChunk: (_) {},
        onToolCall: (_) {},
        onThinking: (_) {},
        onDone: (code, err, stop, _, _) {
          doneCode = code;
          doneErr = err;
          if (!done.isCompleted) done.complete();
        },
      );

      await Future.delayed(const Duration(milliseconds: 300));
      bridge.cancelRequest(ctxA);

      await done.future.timeout(const Duration(seconds: 5));
      await req.timeout(const Duration(seconds: 5));
      expect(doneCode, -1);
      expect(doneErr, 'cancelled');
      // Let the RST settle before closing the server (avoids a racing async
      // write error surfacing in the test zone).
      await Future.delayed(const Duration(milliseconds: 300));
      await server.close();
    });

    test('serialization gate: second sendMessage waits for the first', () async {
      final slowBody =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"slow"}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final fastBody =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fast"}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final server1 = _SseServer();
      await server1.start(slowBody, chunkSize: 16, delayMs: 100); // ~500ms
      final server2 = _SseServer();
      await server2.start(fastBody, chunkSize: 1024, delayMs: 10);

      final bridge = SidecarBridge.instance;
      final order = <String>[];

      final reqA = bridge.sendMessage(
        handle: ctxA,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server1.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"a"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (code, err, stop, _, _) => order.add('A'),
      );
      await Future.delayed(const Duration(milliseconds: 200));
      final reqB = bridge.sendMessage(
        handle: ctxA,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server2.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"b"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (code, err, stop, _, _) => order.add('B'),
      );

      await reqA.timeout(const Duration(seconds: 10));
      await reqB.timeout(const Duration(seconds: 10));

      // B must complete strictly after A (serialized by the gate)
      expect(order, ['A', 'B']);
      expect(server2.requestTimes.length, 1);
      await server1.close();
      await server2.close();
    });

    // change add-context-handles 任务 2.7：不同上下文不排队、取消不串、无 done 走毒化。

    test('两个上下文的请求区间重叠（乙不等甲）', () async {
      final slowBody =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"slow"}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final fastBody =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fast"}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final server1 = _SseServer();
      await server1.start(slowBody, chunkSize: 8, delayMs: 60); // ~1s
      final server2 = _SseServer();
      await server2.start(fastBody, chunkSize: 1024, delayMs: 10);
      final bridge = SidecarBridge.instance;
      final doneAt = <String, DateTime>{};

      final reqA = bridge.sendMessage(
        handle: ctxA,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server1.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"a"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (_, _, _, _, _) =>
            doneAt['A'] = DateTime.now(),
      );
      await Future.delayed(const Duration(milliseconds: 150));
      final reqB = bridge.sendMessage(
        handle: ctxB,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server2.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"b"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (_, _, _, _, _) =>
            doneAt['B'] = DateTime.now(),
      );

      await reqB.timeout(const Duration(seconds: 10));
      // 乙必须在甲结束之前完成 —— 两个上下文各有自己的闸门与网关。
      expect(doneAt.containsKey('B'), isTrue);
      expect(doneAt.containsKey('A'), isFalse,
          reason: '乙完成时甲的慢请求还应该在跑（执行区间重叠）');
      await reqA.timeout(const Duration(seconds: 15));
      expect(doneAt['B']!.isBefore(doneAt['A']!), isTrue);
      // ignore: avoid_print
      print('[OBS] 不同上下文完成顺序: B=${doneAt['B']} A=${doneAt['A']}');
      await server1.close();
      await server2.close();
    });

    test('取消甲只让甲结束，乙照常完成', () async {
      final body =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final server1 = _SseServer();
      await server1.start(body, chunkSize: 8, delayMs: 80);
      final server2 = _SseServer();
      await server2.start(body, chunkSize: 8, delayMs: 80);
      final bridge = SidecarBridge.instance;
      final codes = <String, int>{};
      final done = <String, Completer<void>>{
        'A': Completer<void>(),
        'B': Completer<void>(),
      };

      final reqA = bridge.sendMessage(
        handle: ctxA,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server1.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"a"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (code, _, _, _, _) {
          codes['A'] = code;
          if (!done['A']!.isCompleted) done['A']!.complete();
        },
      );
      final reqB = bridge.sendMessage(
        handle: ctxB,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server2.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"b"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (code, _, _, _, _) {
          codes['B'] = code;
          if (!done['B']!.isCompleted) done['B']!.complete();
        },
      );
      await Future.delayed(const Duration(milliseconds: 300));
      bridge.cancelRequest(ctxA);
      await reqA.timeout(const Duration(seconds: 10));
      await done['B']!.future.timeout(const Duration(seconds: 15));
      await reqB.timeout(const Duration(seconds: 15));

      expect(codes['A'], -1, reason: '甲的请求必须以 cancelled 结束');
      expect(codes['B'], 0, reason: '取消甲不得影响乙');
      await server1.close();
      await server2.close();
    });

    test('取消后一直没有真实 done ⇒ 报错 + context_poisoned，不合成 onDone', () async {
      // 服务端流得很慢（约 2 秒），测试把接收超时与兜底都缩短，并让取消**失败**，
      // 制造「取消后一直没有 done」这条分支。生产常量不变。
      final body =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"late"}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final server = _SseServer();
      await server.start(body, chunkSize: 4, delayMs: 200);
      final bridge = SidecarBridge.instance;
      const ctxC = 'realtime-poison';

      SidecarBridge.receiveTimeout = const Duration(milliseconds: 300);
      SidecarBridge.cancelFallbackDelay = const Duration(milliseconds: 200);
      SidecarBridge.cancelFailureForTests = true;
      await bridge.ensureContext(ctxC);
      var onDoneCalls = 0;
      try {
        await expectLater(
          bridge.sendMessage(
            handle: ctxC,
            apiKey: 'sk-test',
            baseUrl: 'http://127.0.0.1:${server.port}',
            model: 'test-model',
            systemPrompt: '',
            messagesJson: '[{"role":"user","content":"c"}]',
            toolsJson: '',
            thinkingMode: 'disabled',
            thinkingEffort: '',
            onChunk: (_) {},
            onToolCall: (_) {},
            onDone: (_, _, _, _, _) => onDoneCalls++,
          ),
          throwsA(isA<StateError>()),
        );
        expect(onDoneCalls, 0, reason: '不许合成模型 done');
        expect(bridge.isPoisoned(ctxC), isTrue);

        // 之后的请求被拒绝：通过 onDone 交付 context_poisoned，且不发起新请求。
        var rejected = 0;
        String? rejectedErr;
        await bridge.sendMessage(
          handle: ctxC,
          apiKey: 'sk-test',
          baseUrl: 'http://127.0.0.1:${server.port}',
          model: 'test-model',
          systemPrompt: '',
          messagesJson: '[{"role":"user","content":"again"}]',
          toolsJson: '',
          thinkingMode: 'disabled',
          thinkingEffort: '',
          onChunk: (_) {},
          onToolCall: (_) {},
          onDone: (code, err, _, _, _) {
            rejected++;
            rejectedErr = err;
          },
        );
        expect(rejected, 1);
        expect(rejectedErr, contains('context_poisoned'));
      } finally {
        SidecarBridge.receiveTimeout = const Duration(seconds: 120);
        SidecarBridge.cancelFallbackDelay = const Duration(seconds: 30);
        SidecarBridge.cancelFailureForTests = false;
        await server.close();
      }
    });
    test('disposeContext 不提前删桥内队列、也不阻塞界面线程', () async {
      final body =
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"slow"}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final server = _SseServer();
      await server.start(body, chunkSize: 8, delayMs: 80); // ~1 秒
      final bridge = SidecarBridge.instance;
      const handle = 'realtime-dispose';
      await bridge.ensureContext(handle);

      final req = bridge.sendMessage(
        handle: handle,
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'test-model',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"slow"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onDone: (_, _, _, _, _) {},
      );
      await Future.delayed(const Duration(milliseconds: 250));
      expect(bridge.pendingRequests(handle), 1,
          reason: '请求还在飞，桥内计数必须是 1');

      var disposeDone = false;
      final disposeFuture =
          bridge.disposeContext(handle).then((_) => disposeDone = true);
      // 界面线程（本 isolate）在 dispose 等待期间必须还能跑计时器。
      var ticks = 0;
      final ticker = Timer.periodic(const Duration(milliseconds: 20), (_) => ticks++);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(disposeDone, isFalse, reason: '请求没结束，dispose 不许提前完成');
      expect(bridge.pendingRequests(handle), 1,
          reason: 'dispose 完成前不许删桥内队列/计数');
      expect(ticks, greaterThan(0), reason: '界面线程没有被同步 FFI 堵住');

      await req.timeout(const Duration(seconds: 10));
      await disposeFuture.timeout(const Duration(seconds: 10));
      ticker.cancel();
      expect(disposeDone, isTrue);
      expect(bridge.pendingRequests(handle), 0,
          reason: 'dispose 完成后队列/计数才清空');
      await server.close();
    });
  });
}
