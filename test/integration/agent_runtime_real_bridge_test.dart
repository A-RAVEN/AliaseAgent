import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';

/// Agent → 既有 FFI 的真实传递（change `add-agent-object-and-templates` 任务 2.5）。
///
/// 用真实 `SidecarBridge`（真 DLL）配**本地 SSE 服务**，不连接任何外部模型：
/// 从服务端收到的请求体核对模型、推理配置、系统提示词、工具与句柄归属；两个实例的
/// 请求区间、取消与计量不串；带密钥的 provider 夹具证明密钥真的用于发送、但没有进入
/// 日志、可序列化配置或上下文快照。
void main() {
  const canary = 'sk-CANARY-MUST-NOT-LEAK-9f3c';
  late _SseServer server;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  Session session(String id, String agentType) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: 1,
        updatedAt: 1,
      );

  setUpAll(() async {
    await SidecarBridge.instance.ensureContext('real-agent-a');
    await SidecarBridge.instance.ensureContext('real-agent-b');
  });

  setUp(() async {
    ToolCatalog.instance.seed({
      'read_file': def('read_file'),
      'list_dir': def('list_dir'),
    });
    server = _SseServer();
    await server.start();
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'alpha',
      provider: 'local',
      model: 'alpha-model',
      systemPrompt: 'ALPHA-SYSTEM-PROMPT',
      tools: ['read_file'],
      thinkingEffort: 'high',
      maxContextTokens: 100000,
    ));
    registry.register(const AgentTypeConfig(
      name: 'beta',
      provider: 'local',
      model: 'beta-model',
      systemPrompt: 'BETA-SYSTEM-PROMPT',
      tools: ['list_dir'],
      maxContextTokens: 90000,
    ));
    resolver = ProviderResolver(AppConfig(
      version: 1,
      providers: {
        'local': ProviderConfig(
          apiKey: canary,
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      },
    ));
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
  });

  tearDown(() async {
    await server.close();
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  AgentFactory factory() => AgentFactory(
        templates: registry,
        providerResolver: () => resolver,
        config: const AppConfig(version: 1),
        sidecar: SidecarBridge.instance,
        sessionRepo: sessionRepo,
        messageRepo: msgRepo,
        summaryNodeRepo: SummaryNodeRepository(),
        registry: agents,
        summaryProvider: FakeSummaryProvider(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: () => false,
      );

  test('真实 FFI：两个实例的模型、推理、系统提示词、工具与句柄都从各自生效配置出发', () async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
      originalDebugPrint(message, wrapWidth: wrapWidth);
    };
    addTearDown(() => debugPrint = originalDebugPrint);

    final a = await factory().create(session('real-agent-a', 'alpha'));
    final b = await factory().create(session('real-agent-b', 'beta'));

    await a.send('甲的真实请求');
    await b.send('乙的真实请求');

    // ignore: avoid_print
    print('  [OBS] 服务端收到的请求数=${server.requests.length} '
        '它们按到达顺序排列；下面逐份核对：');
    expect(server.requests.length, 2);
    final first = server.requests[0];
    final second = server.requests[1];
    final firstJson = jsonDecode(utf8.decode(first.body)) as Map<String, dynamic>;
    final secondJson =
        jsonDecode(utf8.decode(second.body)) as Map<String, dynamic>;
    // ignore: avoid_print
    print('  [OBS] 第1个请求 model=${firstJson['model']} '
        'thinking=${firstJson['thinking']} system 含 ALPHA=${(firstJson['system'] as String?)?.contains('ALPHA-SYSTEM-PROMPT')} '
        'tools=${(firstJson['tools'] as List).map((t) => t['name']).toList()} '
        'x-api-key 含密钥=${(first.headers['x-api-key'] ?? '').contains(canary)}');
    // ignore: avoid_print
    print('  [OBS] 第2个请求 model=${secondJson['model']} '
        'thinking=${secondJson['thinking']} system 含 BETA=${(secondJson['system'] as String?)?.contains('BETA-SYSTEM-PROMPT')} '
        'tools=${(secondJson['tools'] as List).map((t) => t['name']).toList()}');

    expect(firstJson['model'], 'alpha-model');
    expect((firstJson['system'] as String), contains('ALPHA-SYSTEM-PROMPT'));
    expect((firstJson['thinking'] as Map)['type'], 'adaptive');
    expect((firstJson['tools'] as List).map((t) => t['name']).toList(),
        ['read_file']);
    expect(first.headers['x-api-key'], canary,
        reason: '真实发送路径必须用配置里的密钥（否则这条密钥夹具没意义）');

    expect(secondJson['model'], 'beta-model');
    expect((secondJson['system'] as String), contains('BETA-SYSTEM-PROMPT'));
    expect((secondJson['thinking'] as Map)['type'], 'disabled');
    expect((secondJson['tools'] as List).map((t) => t['name']).toList(),
        ['list_dir']);

    // 回调与写库归属各自会话。
    expect(a.messageHistory.any((m) => m.content == 'real-bridge-reply'), isTrue);
    expect(b.messageHistory.any((m) => m.content == 'real-bridge-reply'), isTrue);
    expect(msgRepo.messages
        .where((m) => m.sessionId == 'real-agent-a' && m.role == 'assistant')
        .isNotEmpty, isTrue);
    expect(msgRepo.messages
        .where((m) => m.sessionId == 'real-agent-b' && m.role == 'assistant')
        .isNotEmpty, isTrue);
    expect(a.metering.requests, 1);
    expect(b.metering.requests, 1);

    // 密钥不泄漏：日志、可序列化配置、上下文快照都不含那个值。
    final configJson = a.config.toJson().toString();
    final snapshotJson = a.contextSnapshot == null
        ? ''
        : jsonEncode(a.contextSnapshot!.toRawJson());
    final leakedInLogs = logs.where((l) => l.contains(canary)).toList();
    // ignore: avoid_print
    print('  [OBS] 密钥泄漏检查：日志条数=${logs.length} 命中=${leakedInLogs.length} '
        '配置快照命中=${configJson.contains(canary)} '
        'ContextSnapshot 命中=${snapshotJson.isNotEmpty && snapshotJson.contains(canary)}');
    expect(leakedInLogs, isEmpty, reason: '日志不许泄漏 provider api_key');
    expect(configJson.contains(canary), isFalse,
        reason: '可序列化的实例生效配置不许含密钥');
    expect(a.contextSnapshot, isNotNull);
    expect(snapshotJson.contains(canary), isFalse,
        reason: '上下文快照不许含密钥');
  });

  test('真实 FFI：两个实例请求区间重叠；取消甲只结束甲，乙照常完成并各自计量', () async {
    // 让甲的回复刻意变慢：乙先完成时甲一定还在流（否则"重叠"只是时序巧合）。
    server.slowModel = 'alpha-model';
    server.slowDelayMs = 120;
    server.delayMs = 10;
    server.chunkSize = 16;
    final a = await factory().create(session('real-agent-a', 'alpha'));
    final b = await factory().create(session('real-agent-b', 'beta'));

    final sendA = a.send('甲的慢请求');
    // 等甲的请求真的开始（服务端收到连接）再发乙。
    for (var i = 0; i < 200 && server.requests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final sendB = b.send('乙的请求');
    // 等到乙也进入发送、且甲的请求还没结束。
    for (var i = 0;
        i < 200 && (!b.isStreaming || b.messageHistory.isEmpty);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // ignore: avoid_print
    print('  [OBS] 重叠检查：a.isStreaming=${a.isStreaming} '
        'b.isStreaming=${b.isStreaming} 服务端请求数=${server.requests.length} '
        '乙是否已有回复=${b.messageHistory.any((m) => m.content == 'real-bridge-reply')}');

    // 乙先完成、甲还在流 —— 两个实例不在同一条串行队列里。
    await sendB.timeout(const Duration(seconds: 20));
    expect(a.isStreaming, isTrue,
        reason: '乙完成时甲还应该在流（请求区间重叠）');
    expect(b.messageHistory.any((m) => m.content == 'real-bridge-reply'), isTrue);

    a.cancel();
    await sendA.timeout(const Duration(seconds: 20));
    // ignore: avoid_print
    print('  [OBS] 取消后：a.isStreaming=${a.isStreaming} '
        'a 历史条数=${a.messageHistory.length} b 历史条数=${b.messageHistory.length} '
        'a.requests=${a.metering.requests} b.requests=${b.metering.requests}');
    expect(a.isStreaming, isFalse);
    expect(b.messageHistory.any((m) => m.content == 'real-bridge-reply'), isTrue,
        reason: '取消甲不得影响乙的结果');
    expect(b.messageHistory.length, greaterThan(1));
    expect(a.metering.requests, 1);
    expect(b.metering.requests, 1);
    final bridge = SidecarBridge.instance;
    expect(bridge.pendingRequests('real-agent-a'), 0,
        reason: '甲的取消必须让桥内的请求收尾');
  });
}

/// 本地 SSE 服务：逐个连接记录请求头/请求体，再按分片慢慢吐同一段回复。
class _SseServer {
  ServerSocket? _socket;
  final List<_CapturedRequest> requests = [];
  final List<Socket> _clients = [];
  final List<Timer> _timers = [];

  int delayMs = 20;
  int chunkSize = 64;

  /// 让某个模型的回复刻意变慢（重叠测试用）：请求体里出现这个模型名就走
  /// [slowDelayMs]，否则走 [delayMs]。
  String? slowModel;
  int slowDelayMs = 20;

  static const String body =
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"real-bridge-reply"}}\n\n'
      'data: {"type":"message_stop"}\n\n';

  int get port => _socket!.port;

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket!.listen(_handleClient);
  }

  void _handleClient(Socket client) {
    _clients.add(client);
    final buffer = <int>[];
    var headerEnd = -1;
    var contentLength = 0;
    var started = false;

    client.listen((data) {
      if (started) return;
      buffer.addAll(data);
      if (headerEnd < 0) {
        headerEnd = _indexOfHeaderEnd(buffer);
        if (headerEnd < 0) return;
        final headers = latin1.decode(buffer.sublist(0, headerEnd));
        final match = RegExp(r'content-length:\s*(\d+)', caseSensitive: false)
            .firstMatch(headers);
        contentLength = int.tryParse(match?.group(1) ?? '') ?? 0;
      }
      final bodyStart = headerEnd + 4;
      if (buffer.length - bodyStart < contentLength) return;
      started = true;
      final headerText = latin1.decode(buffer.sublist(0, headerEnd));
      final bodyBytes = buffer.sublist(bodyStart, bodyStart + contentLength);
      requests.add(_CapturedRequest(_parseHeaders(headerText), bodyBytes));
      _respond(client, bodyBytes);
    }, onError: (_) {}, onDone: () {}, cancelOnError: false);
  }

  int _indexOfHeaderEnd(List<int> bytes) {
    for (var i = 3; i < bytes.length; i++) {
      if (bytes[i - 3] == 13 &&
          bytes[i - 2] == 10 &&
          bytes[i - 1] == 13 &&
          bytes[i] == 10) {
        return i - 3;
      }
    }
    return -1;
  }

  Map<String, String> _parseHeaders(String raw) {
    final out = <String, String>{};
    final lines = raw.split('\r\n');
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      out[line.substring(0, idx).trim().toLowerCase()] =
          line.substring(idx + 1).trim();
    }
    return out;
  }

  void _respond(Socket client, List<int> requestBody) {
    var delay = delayMs;
    final slow = slowModel;
    if (slow != null) {
      try {
        final json = jsonDecode(utf8.decode(requestBody)) as Map<String, dynamic>;
        if (json['model'] == slow) delay = slowDelayMs;
      } catch (_) {}
    }
    try {
      client.write('HTTP/1.1 200 OK\r\n'
          'Content-Type: text/event-stream\r\n'
          'Transfer-Encoding: chunked\r\n\r\n');
    } catch (_) {
      return;
    }
    var pos = 0;
    late Timer timer;
    timer = Timer.periodic(Duration(milliseconds: delay), (t) {
      if (pos >= body.length) {
        t.cancel();
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
        t.cancel();
      }
      pos += n;
    });
    _timers.add(timer);
  }

  Future<void> close() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final client in _clients) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();
    try {
      await _socket?.close();
    } catch (_) {}
  }
}

class _CapturedRequest {
  final Map<String, String> headers;
  final List<int> body;

  const _CapturedRequest(this.headers, this.body);
}
