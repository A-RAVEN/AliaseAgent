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
        onDone: (code, err, stop, _, __) {
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
        onDone: (code, err, stop, _, __) {
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
        onDone: (code, err, stop, _, __) {
          doneCode = code;
          doneErr = err;
          if (!done.isCompleted) done.complete();
        },
      );

      await Future.delayed(const Duration(milliseconds: 300));
      bridge.cancelRequest();

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
        onDone: (code, err, stop, _, __) => order.add('A'),
      );
      await Future.delayed(const Duration(milliseconds: 200));
      final reqB = bridge.sendMessage(
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
        onDone: (code, err, stop, _, __) => order.add('B'),
      );

      await reqA.timeout(const Duration(seconds: 10));
      await reqB.timeout(const Duration(seconds: 10));

      // B must complete strictly after A (serialized by the gate)
      expect(order, ['A', 'B']);
      expect(server2.requestTimes.length, 1);
      await server1.close();
      await server2.close();
    });
  });
}
