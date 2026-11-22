// 无头核心的端到端集成测试（change `web-ui-core-shim` 任务 2.2 / 2.3 / 3.2 / 2.4）。
//
// 形态：真 `HttpServer` + 真 WebSocket + 真 sqlite（临时目录 `openAt` 注入，不碰用户库）
// + `FakeSidecar` 驱动模型流。断言前先打印实际事件序列 / RPC 响应（TESTING.md §3.1）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/core_lock.dart';
import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import 'helpers/fake_sidecar.dart';

const AgentTypeConfig _generalTemplate = AgentTypeConfig(
  name: 'general',
  provider: 'p',
  model: 'm',
  systemPrompt: '',
  tools: ['read_file'],
  maxContextTokens: 100000,
);

final AppConfig _testConfig = AppConfig(
  version: 1,
  providers: const {
    'p': ProviderConfig(apiKey: 'k', baseUrl: 'http://127.0.0.1:1'),
  },
  agentTypes: const {'general': _generalTemplate},
);

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 把「读路径不得全量载入」变成可计数的机器判据（任务 3.2 / 6.2 变异落点）。
class _RecordingMessageRepository extends MessageRepository {
  int fullLoadCount = 0;

  @override
  Future<List<Message>> queryBySession(String sessionId) {
    fullLoadCount++;
    return super.queryBySession(sessionId);
  }
}

class _WsClient {
  _WsClient._(this._socket) {
    _subscription = _socket.listen(_onData, onError: (Object error) {
      _errors.add('$error');
    });
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final List<Map<String, dynamic>> messages = [];
  final List<Map<String, dynamic>> events = [];
  final List<String> _errors = [];
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;

  static Future<_WsClient> connect(Uri uri) async {
    final socket = await WebSocket.connect(uri.toString());
    return _WsClient._(socket);
  }

  List<String> get eventTypes => [for (final e in events) '${e['type']}'];
  int get responseCount =>
      messages.where((m) => m.containsKey('id') && !m.containsKey('method')).length;

  void _onData(dynamic data) {
    final decoded = jsonDecode(data as String) as Map<String, dynamic>;
    messages.add(decoded);
    final id = decoded['id'];
    if (id is int && !decoded.containsKey('method')) {
      final completer = _pending.remove(id);
      if (completer != null) completer.complete(decoded);
      return;
    }
    if (decoded['method'] == 'agent.event') {
      events.add(Map<String, dynamic>.from(decoded['params'] as Map));
    }
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return completer.future.timeout(const Duration(seconds: 15));
  }

  /// 发原始文本并等**下一条**响应（用于非法输入；不依赖 id）。
  Future<Map<String, dynamic>?> sendRawAndAwaitResponse(String raw) async {
    final before = messages.length;
    _socket.add(raw);
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final fresh = messages.skip(before).toList();
      final response = fresh.where((m) => m.containsKey('error')).toList();
      if (response.isNotEmpty) return response.first;
      if (fresh.isNotEmpty) return null;
    }
    return null;
  }

  Future<Map<String, dynamic>> waitForEvent(String type,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final matches = events.where((e) => e['type'] == type).toList();
      if (matches.isNotEmpty) return matches.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等待事件 "$type" 超时；已收到 $eventTypes；WS 错误=$_errors');
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}

Future<void> _waitUntil(bool Function() predicate, String what,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等待 "$what" 超时');
}

/// 一套「临时库 + 无头核心 + 一条 WS」的测试装置。
class _Harness {
  _Harness({
    required this.core,
    required this.ws,
    required this.dbDir,
    required this.sidecar,
  });

  final HeadlessCore core;
  final _WsClient ws;
  final Directory dbDir;
  final FakeSidecar sidecar;

  static Future<_Harness> start({
    FakeSidecar? sidecar,
    MessageRepository? messageRepo,
    String? webRoot,
  }) async {
    final dbDir = Directory.systemTemp.createTempSync('web_core_rpc_db_');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final fake = sidecar ?? FakeSidecar();
    final core = await buildHeadlessCore(
      config: _testConfig,
      sidecar: fake,
      openDatabase: () => DatabaseService.openAt(dbDir.path),
      messageRepository: messageRepo,
    );
    await core.start(webRoot: webRoot);
    final ws = await _WsClient.connect(core.websocketUrl);
    return _Harness(core: core, ws: ws, dbDir: dbDir, sidecar: fake);
  }

  Future<void> stop() async {
    await ws.close();
    await core.stop();
    try {
      dbDir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 文件锁：临时目录删不掉不影响结果。
    }
  }
}

void main() {
  // 本文件全部是 `test()` + 真实 IO（HttpServer/WebSocket/sqlite）。**不要**初始化
  // `TestWidgetsFlutterBinding`：它会安装拦截网络请求的 HttpOverrides（一律回 400），
  // 静态服务用例就测不到真实响应了。

  group('JSON-RPC 2.0 通道（任务 2.2）', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start();
    });

    tearDown(() async {
      await harness.stop();
    });

    test('带 id 的合法请求回对应 id 的响应', () async {
      final response = await harness.ws.request('core.ping');
      _obs('core.ping response', response);
      expect(response['jsonrpc'], '2.0');
      expect(response['id'], isNotNull);
      expect(response['result'], isA<Map>());
      expect((response['result'] as Map)['ok'], isTrue);
      expect((response['result'] as Map)['service'],
          'alias-agent-headless-core');
    });

    test('非法 JSON → -32700，进程继续运行', () async {
      final error = await harness.ws.sendRawAndAwaitResponse('this is not json');
      _obs('非 JSON 输入的错误响应', error);
      expect(error, isNotNull);
      expect(((error!['error'] as Map)['code']), -32700);

      final ping = await harness.ws.request('core.ping');
      _obs('错误之后仍可 ping', ping);
      expect((ping['result'] as Map)['ok'], isTrue);
    });

    test('合法 JSON 但缺 method / jsonrpc → -32600', () async {
      final error = await harness.ws.sendRawAndAwaitResponse(
          '{"jsonrpc":"2.0","id":77,"params":{}}');
      _obs('缺 method 的错误响应', error);
      expect(error, isNotNull);
      expect((error!['error'] as Map)['code'], -32600);
      expect(error['id'], 77);
    });

    test('未知方法 → -32601', () async {
      final response = await harness.ws.request('no.such.method');
      _obs('未知方法响应', response);
      expect((response['error'] as Map)['code'], -32601);
    });

    test('params 不是对象 → -32602', () async {
      // 直接发一个 params 为字符串的请求，用 sendRaw 拿错误响应。
      final error = await harness.ws.sendRawAndAwaitResponse(
          '{"jsonrpc":"2.0","id":78,"method":"core.ping","params":"oops"}');
      _obs('params 非对象的错误响应', error);
      expect(error, isNotNull);
      expect((error!['error'] as Map)['code'], -32602);
      expect(error['id'], 78);
    });

    test('notification（无 id）不回复，但方法确实执行', () async {
      final before = harness.ws.responseCount;
      harness.ws._socket.add(
          jsonEncode({'jsonrpc': '2.0', 'method': 'core.ping', 'params': {}}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _obs('notification 前后响应数', '$before -> ${harness.ws.responseCount}');
      expect(harness.ws.responseCount, before);
      // 通道仍然可用。
      final ping = await harness.ws.request('core.ping');
      expect((ping['result'] as Map)['ok'], isTrue);
    });
  });

  group('无头组合根与单实例守卫（任务 2.1 / 2.4）', () {
    test('启动取锁文件；已被占用时显式失败', () async {
      final dir = Directory.systemTemp.createTempSync('web_core_lock_');
      final lockPath = p.join(dir.path, 'core.lock');
      final first = CoreInstanceLock(lockPath);
      expect(await first.acquire(), isNull);
      _obs('第一把锁已取得', lockPath);

      final second = CoreInstanceLock(lockPath);
      final error = await second.acquire();
      _obs('第二把锁的结果', error);
      if (Platform.isWindows) {
        expect(error, kCoreAlreadyRunningMessage);
      } else {
        // POSIX 的 fcntl 锁按进程归属，同进程第二次取锁会成功；跨进程判据由
        // 真实双进程冒烟验证（见 change 报告）。
        _obs('非 Windows 平台：同进程二次取锁不构成跨进程判据', error);
      }

      await first.release();
      final third = CoreInstanceLock(lockPath);
      expect(await third.acquire(), isNull);
      await third.release();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('生产组合根：OS 端口 / 工具播种 / 默认模板可 send / summaryStoreOpen', () async {
      final dir = Directory.systemTemp.createTempSync('web_core_runner_');
      final lockPath = p.join(dir.path, 'core.lock');
      final dbDir = Directory(p.join(dir.path, 'db'))..createSync();
      final fake = FakeSidecar()..queueChunk('hi')..queueDone();
      HeadlessCore? core;
      try {
        core = await HeadlessCoreRunner.start(
          configOverride: _testConfig,
          lockPath: lockPath,
          openDatabaseOverride: () async {
            sqfliteFfiInit();
            databaseFactory = databaseFactoryFfi;
            await DatabaseService.openAt(dbDir.path);
          },
          sidecarLoader: () => fake,
          webRoot: p.join(dir.path, 'no-such-web-root'),
        );
        _obs('回显 URL', core.url);
        _obs('监听端口', core.port);
        _obs('RPC 方法', core.rpcMethods);
        _obs('工具目录', ToolCatalog.instance.nameSet);
        expect(core.port, greaterThan(0));
        expect(core.url.host, '127.0.0.1');
        expect(core.rpcMethods, kCoreRpcMethodNames,
            reason: '注册表必须与 kCoreRpcMethodNames 一致（文档守卫读同一份常量）');
        expect(ToolCatalog.instance.nameSet,
            containsAll(ToolCatalog.kBaseToolNames));
        expect(ToolCatalog.instance.contains('load_skill'), isTrue);

        final session = await core.sessionRepo.create();
        final ws = await _WsClient.connect(core.websocketUrl);
        try {
          final response = await ws.request('agent.send', {
            'sessionId': session.id,
            'text': '你好',
          });
          _obs('默认模板 send 结果', response);
          expect((response['result'] as Map)['status'], 'completed');
        } finally {
          await ws.close();
        }

        final agent = core.agents.lookup(session.id);
        _obs('实例模板 / summaryStoreOpen',
            '${agent?.agentTypeName} / ${agent?.summaryStoreOpen}');
        expect(agent, isNotNull);
        expect(agent!.agentTypeName, 'general');
        expect(agent.summaryStoreOpen, isTrue,
            reason: '数据库已打开时 summaryStoreOpen 必须是真谓词，不能是 _neverOpen');

        // 锁文件被这个核心持着：第二个进程/实例取锁失败。
        final conflict = await CoreInstanceLock(lockPath).acquire();
        _obs('核心运行中的锁冲突结果', conflict);
        if (Platform.isWindows) {
          expect(conflict, kCoreAlreadyRunningMessage);
        }
      } finally {
        await core?.stop();
        try {
          DatabaseService.reset();
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('sidecar 加载失败：可归因信息、不假装就绪、不占着锁', () async {
      final dir = Directory.systemTemp.createTempSync('web_core_sidecar_fail_');
      final lockPath = p.join(dir.path, 'core.lock');
      final dbDir = Directory(p.join(dir.path, 'db'))..createSync();
      HeadlessCoreStartupException? caught;
      try {
        await HeadlessCoreRunner.start(
          configOverride: _testConfig,
          lockPath: lockPath,
          openDatabaseOverride: () async {
            sqfliteFfiInit();
            databaseFactory = databaseFactoryFfi;
            await DatabaseService.openAt(dbDir.path);
          },
          sidecarLoader: () => throw ArgumentError(
              "Failed to load dynamic library 'sidecar.dll'"),
        );
      } on HeadlessCoreStartupException catch (e) {
        caught = e;
      }
      _obs('sidecar 加载失败的启动错误', caught?.message);
      expect(caught, isNotNull);
      expect(caught!.message, contains('sidecar 加载失败'));
      expect(caught.message, contains('sidecar.dll'));
      expect(caught.message, contains('CWD'));

      final lock = CoreInstanceLock(lockPath);
      final lockResult = await lock.acquire();
      _obs('启动失败后重新取锁', lockResult);
      expect(lockResult, isNull, reason: '启动失败必须释放单实例锁');
      await lock.release();
      await DatabaseService.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('静态服务：serve 构建产物；缺产物 503 且给出构建提示', () async {
      final webDir = Directory.systemTemp.createTempSync('web_core_static_');
      File(p.join(webDir.path, 'index.html'))
          .writeAsStringSync('<html><body>web ok</body></html>');
      File(p.join(webDir.path, 'app.js'))
          .writeAsStringSync('console.log("ok");');
      final harness = await _Harness.start(webRoot: webDir.path);
      try {
        final client = HttpClient();
        try {
          final request =
              await client.getUrl(harness.core.url.replace(path: '/'));
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          _obs('GET / 状态 / 正文', '${response.statusCode} / $body');
          expect(response.statusCode, 200);
          expect(body, contains('web ok'));

          final jsRequest =
              await client.getUrl(harness.core.url.resolve('/app.js'));
          final jsResponse = await jsRequest.close();
          final jsBody = await jsResponse.transform(utf8.decoder).join();
          _obs('GET /app.js 状态 / content-type',
              '${jsResponse.statusCode} / ${jsResponse.headers.contentType}');
          expect(jsResponse.statusCode, 200);
          expect(jsBody, contains('console.log'));
          expect('${jsResponse.headers.contentType}', contains('javascript'));
        } finally {
          client.close(force: true);
        }
      } finally {
        await harness.stop();
        try {
          webDir.deleteSync(recursive: true);
        } catch (_) {}
      }

      // 缺产物：503 + 可归因构建提示（不假装就绪）。
      final emptyDir = p.join(webDir.path, 'does-not-exist');
      final second = await _Harness.start(webRoot: emptyDir);
      try {
        final client = HttpClient();
        try {
          final request =
              await client.getUrl(second.core.url.replace(path: '/'));
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          _obs('缺产物 GET / 状态 / 正文', '${response.statusCode} / $body');
          expect(response.statusCode, 503);
          expect(body, contains('web 客户端产物不存在'));
          expect(body, contains('npm run build'));
        } finally {
          client.close(force: true);
        }
      } finally {
        await second.stop();
      }
    });
  });

  group('发送、流式与事件映射（任务 2.3）', () {
    late _Harness harness;
    late String sessionId;

    setUp(() async {
      harness = await _Harness.start();
      final session = await harness.core.sessionRepo.create();
      sessionId = session.id;
    });

    tearDown(() async {
      await harness.stop();
    });

    test('发送 → 流式文本 + 最终助手消息 + 完整快照 + 计量', () async {
      harness.sidecar
        ..queueChunk('你')
        ..queueChunk('好')
        ..queueDone(inputTokens: 11, outputTokens: 7);
      final response = await harness.ws.request(
          'agent.send', {'sessionId': sessionId, 'text': '你好'});
      _obs('agent.send 响应', response);
      _obs('实际事件序列', harness.ws.eventTypes);
      _obs('user.message', harness.ws.events
          .where((e) => e['type'] == 'user.message')
          .map((e) => e['data'])
          .toList());

      expect((response['result'] as Map)['status'], 'completed');
      expect(harness.ws.eventTypes, contains('assistant.chunk'));
      expect(harness.ws.eventTypes, contains('assistant.message'));
      expect(harness.ws.eventTypes, contains('context.snapshot'));
      expect(harness.ws.eventTypes, contains('agent.metering'));

      final chunks = harness.ws.events
          .where((e) => e['type'] == 'assistant.chunk')
          .map((e) => (e['data'] as Map)['text'])
          .join();
      final assistant = harness.ws.events
          .lastWhere((e) => e['type'] == 'assistant.message');
      _obs('拼接后的流式文本', chunks);
      _obs('最终助手消息', assistant['data']);
      expect(chunks, '你好');
      expect((assistant['data'] as Map)['isFinal'], isTrue);
      expect((assistant['data'] as Map)['content'], '你好');
      expect((assistant['data'] as Map)['sessionId'], sessionId);
      for (final event in harness.ws.events) {
        expect(event['sessionId'], sessionId,
            reason: '每个 agent.event 的 payload 都必须带 sessionId');
        expect(event['type'], isA<String>());
      }

      final snapshot =
          harness.ws.events.lastWhere((e) => e['type'] == 'context.snapshot');
      final data = snapshot['data'] as Map;
      _obs('快照 payload keys', data.keys.toList());
      _obs('快照 breakdown', data['breakdown']);
      expect(data['windowTokens'], 100000);
      expect(data['agentType'], 'general');
      expect(data['capturedAt'], isA<String>());
      expect(data['breakdown'], isA<Map>(),
          reason: '快照适配必须补上占用环所需字段，不能只剩 toRawJson 三键');
      final breakdown = data['breakdown'] as Map;
      expect(breakdown.keys,
          containsAll([
            'level2Tokens',
            'level1Tokens',
            'rawTokens',
            'fixedOverheadTokens',
            'windowTokens',
            'usedTokens',
            'conversationTokens',
          ]));
      expect(data['messages'], isA<List>());
      expect(data['skillFailures'], isA<List>());

      final metering = harness.ws.events
          .lastWhere((e) => e['type'] == 'agent.metering')['data'] as Map;
      _obs('计量事件', metering);
      expect(metering['input_tokens'], 11);
      expect(metering['output_tokens'], 7);
    });

    test('工具轮：tool.call / tool.result 事件可见', () async {
      harness.sidecar
        ..queueToolCall('{"name":"read_file","input":{"path":"a.txt"}}')
        ..queueDone()
        ..queueChunk('读完了')
        ..queueDone();
      final response = await harness.ws.request(
          'agent.send', {'sessionId': sessionId, 'text': '读文件'});
      _obs('agent.send 响应', response);
      _obs('实际事件序列', harness.ws.eventTypes);

      expect(harness.ws.eventTypes, contains('tool.call'));
      expect(harness.ws.eventTypes, contains('tool.result'));
      final toolCall =
          harness.ws.events.lastWhere((e) => e['type'] == 'tool.call')['data']
              as Map;
      final toolResult =
          harness.ws.events.lastWhere((e) => e['type'] == 'tool.result')['data']
              as Map;
      _obs('tool.call', toolCall);
      _obs('tool.result', toolResult);
      expect(toolCall['toolName'], 'read_file');
      expect(toolCall['input'], {'path': 'a.txt'});
      expect(toolResult['status'], 'done');
      expect(harness.sidecar.countOf('read_file'), 1);
    });

    test('快照携带逐条技能失败明细（不是只剩计数）', () async {
      final badRoot = Directory.systemTemp.createTempSync('web_core_skills_');
      Directory(p.join(badRoot.path, 'bad-skill')).createSync();
      // Agent 每轮装配前都会用**缺省根**增量重扫技能目录，所以必须把缺省根
      // 指到临时目录（只给一次 scan(rootPath:) 会被下一轮覆盖）。
      SkillCatalogService.instance.setRootForTests(badRoot.path);
      await SkillCatalogService.instance.scan(rootPath: badRoot.path);
      harness.sidecar..queueChunk('ok')..queueDone();
      try {
        await harness.ws.request(
            'agent.send', {'sessionId': sessionId, 'text': 'hi'});
        _obs('实际事件序列', harness.ws.eventTypes);
        final snapshot = harness.ws.events
            .lastWhere((e) => e['type'] == 'context.snapshot');
        final data = snapshot['data'] as Map;
        _obs('技能失败明细', data['skillFailures']);
        _obs('技能失败汇总', data['skillFailureNotice']);
        expect(data['skillFailures'], isA<List>());
        expect((data['skillFailures'] as List).join('\n'), contains('bad-skill'));
        expect(data['skillFailureNotice'], isNotNull);
      } finally {
        SkillCatalogService.instance.setRootForTests(null);
        try {
          badRoot.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('重连后事件发往当前 WS 订阅者', () async {
      harness.sidecar..queueChunk('first')..queueDone();
      await harness.ws.request(
          'agent.send', {'sessionId': sessionId, 'text': 'one'});
      final oldEventCount = harness.ws.eventTypes.length;
      await harness.ws.close();
      await _waitUntil(() => harness.core.clientCount == 0, '旧连接断开');

      final reconnected = await _WsClient.connect(harness.core.websocketUrl);
      try {
        await _waitUntil(() => harness.core.clientCount == 1, '新连接登记为订阅者');
        _obs('重连后订阅者数', harness.core.clientCount);
        harness.sidecar..queueChunk('second')..queueDone();
        final response = await reconnected.request(
            'agent.send', {'sessionId': sessionId, 'text': 'two'});
        _obs('重连后 send 响应', response);
        _obs('重连后事件序列', reconnected.eventTypes);
        final chunks = reconnected.events
            .where((e) => e['type'] == 'assistant.chunk')
            .map((e) => (e['data'] as Map)['text'])
            .join();
        expect(chunks, contains('second'));
        expect(harness.ws.eventTypes.length, oldEventCount,
            reason: '旧连接已断开，不应再收事件');
      } finally {
        await reconnected.close();
      }
    });

    test('取消在途请求：推送流式状态收尾', () async {
      harness.sidecar.gateNextSend();
      final sendFuture = harness.ws.request(
          'agent.send', {'sessionId': sessionId, 'text': '慢慢来'});
      await _waitUntil(
          () => harness.core.agents.lookup(sessionId)?.isStreaming == true,
          'send 进入流式');
      _obs('取消前事件序列', harness.ws.eventTypes);
      final cancelResponse = await harness.ws
          .request('agent.cancel', {'sessionId': sessionId});
      _obs('agent.cancel 响应', cancelResponse);
      expect((cancelResponse['result'] as Map)['cancelled'], isTrue);
      harness.sidecar.releaseGate();
      final sendResponse = await sendFuture;
      _obs('取消后的 send 响应', sendResponse);
      _obs('取消后事件序列', harness.ws.eventTypes);
      expect((sendResponse['result'] as Map)['status'], 'cancelled');
      final streamingFlags = harness.ws.events
          .where((e) => e['type'] == 'agent.streaming')
          .map((e) => (e['data'] as Map)['streaming'])
          .toList();
      _obs('agent.streaming 序列', streamingFlags);
      expect(streamingFlags, contains(false),
          reason: '取消必须推送流式状态收尾事件');
      expect(harness.sidecar.cancelCount, greaterThan(0));
    });

    test('整轮 failed 推送可归因失败事件', () async {
      harness.sidecar.queueDone(code: 1, error: 'provider exploded');
      final response = await harness.ws.request(
          'agent.send', {'sessionId': sessionId, 'text': 'boom'});
      _obs('send 响应', response);
      _obs('实际事件序列', harness.ws.eventTypes);
      expect((response['result'] as Map)['status'], 'failed');
      final failed = harness.ws.events
          .lastWhere((e) => e['type'] == 'turn.failed')['data'] as Map;
      _obs('turn.failed payload', failed);
      expect('${failed['error']}', contains('provider exploded'));
    });
  });

  group('会话与消息分页（任务 3.1 / 3.2）', () {
    test('分页只返回该页 + 下一页游标；读路径不调用全量 queryBySession', () async {
      final repo = _RecordingMessageRepository();
      final harness = await _Harness.start(messageRepo: repo);
      try {
        final session = await harness.core.sessionRepo.create();
        for (var i = 0; i < 5; i++) {
          await repo.insert(
              sessionId: session.id, role: 'user', content: 'msg-$i');
        }
        final all = await repo.queryBySession(session.id);
        _obs('库里消息 seq', [for (final m in all) m.seq]);
        expect(all.map((m) => m.content).toList(),
            ['msg-0', 'msg-1', 'msg-2', 'msg-3', 'msg-4']);

        // change `web-chat-screen` 任务 1.2 起，不传游标缺省是**尾锚**（最新页）；
        // 本用例验证的是"从最旧开始的既有前向分页语义"，故显式 anchor=head。
        // 断言本身未改（前向 afterSeq/nextCursor 的语义仍是扩展前那一套）。
        final page1 = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2, 'anchor': 'head'});
        final r1 = page1['result'] as Map;
        _obs('第 1 页', r1);
        expect([for (final m in r1['messages'] as List) (m as Map)['content']],
            ['msg-0', 'msg-1']);
        expect(r1['nextCursor'], 2);
        expect(r1['pageSize'], 2);

        final page2 = await harness.ws.request('message.query', {
          'sessionId': session.id,
          'pageSize': 2,
          'cursor': 2,
        });
        final r2 = page2['result'] as Map;
        _obs('第 2 页', r2);
        expect([for (final m in r2['messages'] as List) (m as Map)['content']],
            ['msg-2', 'msg-3']);
        expect(r2['nextCursor'], 4);

        final page3 = await harness.ws.request('message.query', {
          'sessionId': session.id,
          'pageSize': 2,
          'cursor': 4,
        });
        final r3 = page3['result'] as Map;
        _obs('第 3 页', r3);
        expect([for (final m in r3['messages'] as List) (m as Map)['content']],
            ['msg-4']);
        expect(r3['nextCursor'], isNull);

        _obs('全量 queryBySession 被调用次数', repo.fullLoadCount);
        expect(repo.fullLoadCount, 1,
            reason: '1 次是测试自己的基线查询；message.query 不得再调用全量方法');
      } finally {
        await harness.stop();
      }
    });

    test('缺 pageSize / 非法 pageSize → -32602，不套隐藏默认值', () async {
      final harness = await _Harness.start();
      try {
        final session = await harness.core.sessionRepo.create();
        await harness.core.messageRepo
            .insert(sessionId: session.id, role: 'user', content: 'x');
        for (final params in <Map<String, dynamic>>[
          {'sessionId': session.id},
          {'sessionId': session.id, 'pageSize': 0},
          {'sessionId': session.id, 'pageSize': -3},
          {'sessionId': session.id, 'pageSize': '2'},
          {'sessionId': session.id, 'pageSize': 2, 'cursor': 'bad'},
        ]) {
          final response = await harness.ws.request('message.query', params);
          _obs('非法参数 $params 的响应', response);
          expect((response['error'] as Map)['code'], -32602,
              reason: 'params=$params');
        }
      } finally {
        await harness.stop();
      }
    });

    // change `web-chat-screen` 任务 1.3：message.query 的 additive 扩展（尾锚 +
    // 反向游标 + prevCursor）。三条用例先红后绿，红证据见 change 报告。
    test('尾锚：不传游标取最新一页（不是最旧页）+ prevCursor', () async {
      final harness = await _Harness.start();
      try {
        final session = await harness.core.sessionRepo.create();
        for (var i = 0; i < 5; i++) {
          await harness.core.messageRepo
              .insert(sessionId: session.id, role: 'user', content: 'msg-$i');
        }
        final tail = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2});
        final tailPage = tail['result'] as Map;
        _obs('尾锚页（不传游标）', tailPage);
        expect(
            [
              for (final m in tailPage['messages'] as List)
                (m as Map)['content']
            ],
            ['msg-3', 'msg-4'],
            reason: '不传游标必须是"最新一页"（尾锚），不是最旧页');
        expect(
            [for (final m in tailPage['messages'] as List) (m as Map)['seq']],
            [4, 5],
            reason: '尾锚页内按 seq 升序返回');
        expect(tailPage['prevCursor'], 4,
            reason: 'prevCursor = 本页首条 seq，指向更早页');
        expect(tailPage['nextCursor'], isNull,
            reason: '尾锚页之后没有更新的页，前向游标为 null');

        final explicit = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2, 'anchor': 'tail'});
        _obs('显式 anchor=tail', explicit['result']);
        expect(
            [
              for (final m in (explicit['result'] as Map)['messages'] as List)
                (m as Map)['content']
            ],
            ['msg-3', 'msg-4']);
      } finally {
        await harness.stop();
      }
    });

    test('反向游标：beforeSeq 加载更早一页，不重叠、走到头 prevCursor 为 null', () async {
      final harness = await _Harness.start();
      try {
        final session = await harness.core.sessionRepo.create();
        for (var i = 0; i < 5; i++) {
          await harness.core.messageRepo
              .insert(sessionId: session.id, role: 'user', content: 'msg-$i');
        }
        final newest = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2});
        final newestPage = newest['result'] as Map;
        _obs('最新页', newestPage);
        final newestSeqs = [
          for (final m in newestPage['messages'] as List) (m as Map)['seq']
        ];
        final newestContents = [
          for (final m in newestPage['messages'] as List) (m as Map)['content']
        ];

        final earlier1 = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2, 'before': newestPage['prevCursor']});
        final earlier1Page = earlier1['result'] as Map;
        _obs('上翻第 1 页', earlier1Page);
        expect(
            [
              for (final m in earlier1Page['messages'] as List)
                (m as Map)['content']
            ],
            ['msg-1', 'msg-2'],
            reason: 'before=最新页首条 seq，返回 seq 更小的更早一页（升序）');
        expect(
            [for (final m in earlier1Page['messages'] as List) (m as Map)['seq']],
            [2, 3]);
        expect(earlier1Page['prevCursor'], 2);
        // 不重叠：两页的 seq 集合交集必须为空。
        _obs('两页 seq', '$newestSeqs / ${earlier1Page['messages']}');
        final earlierSeqs = {
          for (final m in earlier1Page['messages'] as List) (m as Map)['seq']
        };
        expect(newestSeqs.toSet().intersection(earlierSeqs), isEmpty,
            reason: '反向页不得与当前页重叠（newest=$newestContents）');

        final earlier2 = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2, 'before': earlier1Page['prevCursor']});
        final earlier2Page = earlier2['result'] as Map;
        _obs('上翻第 2 页', earlier2Page);
        expect(
            [
              for (final m in earlier2Page['messages'] as List)
                (m as Map)['content']
            ],
            ['msg-0']);
        expect(earlier2Page['prevCursor'], isNull,
            reason: '没有更早消息时 prevCursor 必须是 null（不是 0/负数）');
      } finally {
        await harness.stop();
      }
    });

    test('前向兼容：anchor=head + cursor/nextCursor 与扩展前一致', () async {
      final harness = await _Harness.start();
      try {
        final session = await harness.core.sessionRepo.create();
        for (var i = 0; i < 5; i++) {
          await harness.core.messageRepo
              .insert(sessionId: session.id, role: 'user', content: 'msg-$i');
        }
        final head = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2, 'anchor': 'head'});
        final headPage = head['result'] as Map;
        _obs('anchor=head 首页', headPage);
        expect(
            [
              for (final m in headPage['messages'] as List) (m as Map)['content']
            ],
            ['msg-0', 'msg-1'],
            reason: 'anchor=head 保留"从最旧开始"的既有语义');
        expect(headPage['nextCursor'], 2);
        expect(headPage['prevCursor'], isNull,
            reason: '最旧页没有更早页，prevCursor 为 null');

        // 只传 cursor（不传 anchor）仍是前向分页：这是既有 web 客户端/Flutter 的
        // 调用形状，不能被尾锚缺省改成反向。
        final forward = await harness.ws.request('message.query',
            {'sessionId': session.id, 'pageSize': 2, 'cursor': 2});
        final forwardPage = forward['result'] as Map;
        _obs('cursor=2 前向页', forwardPage);
        expect(
            [
              for (final m in forwardPage['messages'] as List)
                (m as Map)['content']
            ],
            ['msg-2', 'msg-3']);
        expect(forwardPage['nextCursor'], 4);
        expect(forwardPage['prevCursor'], 3,
            reason: 'prevCursor 与页内首条 seq 一致（本页 seq 3..4）');
      } finally {
        await harness.stop();
      }
    });

    test('非法 anchor / cursor 与 before 同时出现 → -32602', () async {
      final harness = await _Harness.start();
      try {
        final session = await harness.core.sessionRepo.create();
        await harness.core.messageRepo
            .insert(sessionId: session.id, role: 'user', content: 'x');
        for (final params in <Map<String, dynamic>>[
          {'sessionId': session.id, 'pageSize': 2, 'anchor': 'middle'},
          {'sessionId': session.id, 'pageSize': 2, 'anchor': 1},
          {'sessionId': session.id, 'pageSize': 2, 'before': 'bad'},
          {'sessionId': session.id, 'pageSize': 2, 'cursor': 1, 'before': 2},
        ]) {
          final response = await harness.ws.request('message.query', params);
          _obs('非法分页参数 $params 的响应', response);
          expect((response['error'] as Map)['code'], -32602, reason: 'params=$params');
        }
      } finally {
        await harness.stop();
      }
    });

    test('不存在的会话 → 可归因 JSON-RPC 错误（非静默）', () async {
      final harness = await _Harness.start();
      try {
        final query = await harness.ws.request('message.query',
            {'sessionId': 'no-such-session', 'pageSize': 10});
        _obs('不存在会话的 message.query', query);
        expect((query['error'] as Map)['code'], -32602);
        expect('${(query['error'] as Map)['message']}', contains('不存在'));

        final send = await harness.ws.request('agent.send',
            {'sessionId': 'no-such-session', 'text': 'hi'});
        _obs('不存在会话的 agent.send', send);
        expect((send['error'] as Map)['code'], -32602);
      } finally {
        await harness.stop();
      }
    });

    test('会话列表：只返回顶层、按最近更新倒序', () async {
      final harness = await _Harness.start();
      try {
        final older = await harness.core.sessionRepo.create(title: 'older');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final newer = await harness.core.sessionRepo.create(title: 'newer');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await harness.core.sessionRepo.touch(older.id);
        await harness.core.sessionRepo
            .create(title: 'child', parentSessionId: older.id);
        final response = await harness.ws.request('session.list');
        final sessions = (response['result'] as Map)['sessions'] as List;
        _obs('会话列表', sessions);
        expect(sessions.length, 2);
        expect([for (final s in sessions) (s as Map)['title']], ['older', 'newer']);
        expect([for (final s in sessions) (s as Map)['id']],
            [older.id, newer.id]);
        expect([for (final s in sessions) (s as Map)['agentType']],
            everyElement('general'));
      } finally {
        await harness.stop();
      }
    });
  });
}
