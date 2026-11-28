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
import 'package:alias_agent/services/workspace.dart';

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
    // 返工 12.1：`workspace.listDirs` 省略 path 时的起点 —— 注入临时目录，
    // **绝不**让用例去列举用户真实主目录。
    String? homeDir,
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
      // 配置 / 附件也搬进临时目录：本文件绝不落到用户真实 ~/.aliasagent 的 config。
      configPath: p.join(dbDir.path, 'config.json'),
      attachmentsDir: p.join(dbDir.path, 'attachments'),
      homeDir: homeDir,
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

    // ---------------------------------------------------------------------
    // 群聊：group.update（change `group-reactive-mode` 任务 4.2）
    // ---------------------------------------------------------------------

    test('group.update 已注册：改开关回读、缺字段 -32602', () async {
      // 注册表与清单一致（漏注册在核心启动时就抛 StateError，这里再核一次）。
      expect(harness.core.rpcMethods, kCoreRpcMethodNames);
      expect(harness.core.rpcMethods, contains('group.update'));
      // 异步链的查询方法（change `group-reactive-mode` R.3）：清单与实现一致。
      expect(kCoreRpcMethodNames, contains('group.chain'));
      expect(harness.core.rpcMethods, contains('group.chain'));

      final created = await harness.ws.request('group.create', {
        'title': 'web 组',
        'reactionsEnabled': true,
      });
      final groupId = (created['result'] as Map)['group']['id'] as String;
      final updated = await harness.ws.request('group.update', {
        'groupId': groupId,
        'reactionsEnabled': false,
      });
      _obs('group.update 响应', updated);
      expect(((updated['result'] as Map)['group'] as Map)['reactionsEnabled'],
          isFalse);

      final missing = await harness.ws.request('group.update', {
        'groupId': groupId,
      });
      _obs('缺字段错误', missing['error']);
      expect((missing['error'] as Map)['code'], -32602);
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

  // ---------------------------------------------------------------------------
  // change `custom-workspace` 任务 7.1：工作路径 RPC 面
  //   session.create{workspace} / session.setWorkspace / session.list / group.list
  //   的 workspace 序列化、-32602 语义、busy 不排队不改值、方法清单。
  // ---------------------------------------------------------------------------
  group('工作路径 RPC（change `custom-workspace`）', () {
    late _Harness harness;
    late Directory base;
    late Directory workspaceA;
    late Directory workspaceB;

    setUp(() async {
      harness = await _Harness.start();
      base = Directory.systemTemp.createTempSync('workspace_rpc_');
      workspaceA = Directory(p.join(base.path, 'ws-a'))..createSync(recursive: true);
      workspaceB = Directory(p.join(base.path, 'ws-b'))..createSync(recursive: true);
    });

    tearDown(() async {
      await harness.stop();
      if (base.existsSync()) {
        try {
          base.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Future<int> sessionCount() async =>
        (await harness.core.sessionRepo.list()).length;

    test('session.create{workspace} 落库并读回；非法路径 -32602 且不建行；空白 = 省略', () async {
      final created = await harness.ws.request('session.create', {
        'title': '带工作区',
        'workspace': workspaceA.path,
      });
      _obs('session.create 回包', created);
      expect(created['error'], isNull);
      final session = (created['result'] as Map)['session'] as Map;
      final sessionId = session['id'] as String;
      expect(session['workspace'], workspaceA.path);

      final list = await harness.ws.request('session.list');
      final listed = (list['result'] as Map)['sessions'] as List;
      final row = listed.singleWhere((item) => (item as Map)['id'] == sessionId);
      expect((row as Map)['workspace'], workspaceA.path,
          reason: 'session.list 必须序列化 workspace');

      final before = await sessionCount();
      final badCases = <String, String>{
        '不存在': p.join(base.path, 'nope-9f1'),
        '相对': p.join('relative', 'dir'),
        '指向文件': (File(p.join(base.path, 'a-file.txt'))..writeAsStringSync('x'))
            .path,
      };
      for (final entry in badCases.entries) {
        final response = await harness.ws.request('session.create', {
          'title': '坏工作区-${entry.key}',
          'workspace': entry.value,
        });
        _obs('非法 workspace（${entry.key}）', response);
        expect((response['error'] as Map)['code'], -32602,
            reason: '${entry.key} 必须被拒绝');
        expect('${(response['error'] as Map)['message']}',
            contains(entry.value));
      }
      // 类型不对（不是字符串）同样是 -32602（消息不 Echo 值，只点名字段）。
      final wrongType = await harness.ws.request('session.create', {
        'title': '类型不对',
        'workspace': 42,
      });
      _obs('非字符串 workspace', wrongType);
      expect((wrongType['error'] as Map)['code'], -32602);
      expect('${(wrongType['error'] as Map)['message']}',
          contains('workspace'));
      expect(await sessionCount(), before, reason: '非法路径不得创建会话行');

      final blank = await harness.ws.request('session.create', {
        'title': '空白工作区',
        'workspace': '   ',
      });
      _obs('空白 workspace 的回包', blank);
      expect(blank['error'], isNull);
      final blankSession = (blank['result'] as Map)['session'] as Map;
      expect(blankSession['workspace'], isNull, reason: '只有空白 = 省略（NULL）');
      final reread = await harness.core.sessionRepo
          .get(blankSession['id'] as String);
      expect(reread!.workspace, isNull);
    });

    test('session.setWorkspace：成功改库 + 实例上下文；非法 / 组 / 不存在 / 流式中各自可归因', () async {
      final created = await harness.ws.request('session.create', {
        'title': '切换单聊',
        'workspace': workspaceA.path,
      });
      final sessionId =
          ((created['result'] as Map)['session'] as Map)['id'] as String;

      // 先发一轮让实例存在（上下文已按 A 建立）。
      harness.sidecar.queueChunk('第一轮');
      harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
      await harness.ws.request('agent.send', {'sessionId': sessionId, 'text': 'hi'});
      expect(harness.sidecar.getWorkspace(sessionId).workspace, workspaceA.path);

      final ok = await harness.ws.request('session.setWorkspace', {
        'sessionId': sessionId,
        'workspace': workspaceB.path,
      });
      _obs('session.setWorkspace 成功回包', ok);
      expect(ok['error'], isNull);
      final updated = (ok['result'] as Map)['session'] as Map;
      expect(updated['workspace'], workspaceB.path);
      expect((await harness.core.sessionRepo.get(sessionId))!.workspace,
          workspaceB.path, reason: '库里的 workspace 必须已改');
      final contextRead = harness.sidecar.getWorkspace(sessionId);
      _obs('切换后实例上下文', contextRead);
      expect(contextRead.ok, isTrue);
      expect(p.equals(contextRead.workspace!, workspaceB.path), isTrue,
          reason: '有在册实例时上下文必须同步切到新目录');

      // 非法路径：-32602 且库 / 上下文都不变。
      final file = File(p.join(base.path, 'not-dir.txt'))..writeAsStringSync('x');
      for (final bad in <Object>[
        p.join(base.path, 'still-missing-9f1'),
        'relative/path',
        file.path,
        '',
        42,
      ]) {
        final response = await harness.ws.request('session.setWorkspace', {
          'sessionId': sessionId,
          'workspace': bad,
        });
        _obs('非法 setWorkspace（$bad）', response);
        expect((response['error'] as Map)['code'], -32602);
      }
      expect((await harness.core.sessionRepo.get(sessionId))!.workspace,
          workspaceB.path, reason: '失败不得改库');
      expect(p.equals(harness.sidecar.getWorkspace(sessionId).workspace!,
          workspaceB.path), isTrue, reason: '失败不得改运行中上下文');

      // 不存在的会话。
      final missing = await harness.ws.request('session.setWorkspace', {
        'sessionId': 'no-such-session',
        'workspace': workspaceA.path,
      });
      _obs('不存在会话的 setWorkspace', missing);
      expect((missing['error'] as Map)['code'], -32602);

      // 组会话用错方法：指明改用 group.setWorkspace。
      final group = await harness.ws.request('group.create', {'title': '一个组'});
      final groupId = ((group['result'] as Map)['group'] as Map)['id'] as String;
      final wrongKind = await harness.ws.request('session.setWorkspace', {
        'sessionId': groupId,
        'workspace': workspaceA.path,
      });
      _obs('组会话的 session.setWorkspace', wrongKind);
      expect((wrongKind['error'] as Map)['code'], -32602);
      expect('${(wrongKind['error'] as Map)['message']}',
          contains('group.setWorkspace'));
      expect((await harness.core.sessionRepo.get(groupId))!.workspace, isNull,
          reason: 'kind 不符不得改库');

      // 流式中：可归因 busy，且不排队 / 不改值。
      harness.sidecar.gateNextSend();
      harness.sidecar.queueChunk('流式中');
      harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
      final pending = harness.ws.request('agent.send', {
        'sessionId': sessionId,
        'text': '占住实例',
      });
      await _waitUntil(
          () => harness.sidecar.awaitingGateCount == 1, '实例进入流式并挂住');
      final busy = await harness.ws.request('session.setWorkspace', {
        'sessionId': sessionId,
        'workspace': workspaceA.path,
      });
      _obs('流式中的 session.setWorkspace', busy);
      expect((busy['error'] as Map)['code'], -32602);
      expect('${(busy['error'] as Map)['message']}', contains('busy'));
      expect((await harness.core.sessionRepo.get(sessionId))!.workspace,
          workspaceB.path, reason: 'busy 不改值');
      harness.sidecar.releaseGate();
      await pending;
    });

    test('无实例时 session.setWorkspace 只落库；首次发送的上下文用该值', () async {
      final created = await harness.ws.request('session.create', {
        'title': '还没有实例',
        'workspace': workspaceA.path,
      });
      final sessionId =
          ((created['result'] as Map)['session'] as Map)['id'] as String;
      // 没有实例：不碰 sidecar，直接落库。
      final ok = await harness.ws.request('session.setWorkspace', {
        'sessionId': sessionId,
        'workspace': workspaceB.path,
      });
      _obs('无实例时的 setWorkspace', ok);
      expect(ok['error'], isNull);
      expect(harness.sidecar.ensureContextCalls, isNot(contains(sessionId)),
          reason: '没有实例就不该建上下文');

      harness.sidecar.queueChunk('首次发送');
      harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
      await harness.ws.request('agent.send', {'sessionId': sessionId, 'text': 'hi'});
      final read = harness.sidecar.getWorkspace(sessionId);
      _obs('首次发送后的上下文工作区', read);
      expect(read.ok, isTrue);
      expect(p.equals(read.workspace!, workspaceB.path), isTrue,
          reason: '首次发送创建的上下文必须用持久化值');
    });

    test('session.list 与 group.list 每项都有 workspace 键（null 与字符串都在）', () async {
      final withWorkspace = await harness.core.sessionRepo
          .create(title: '有工作区', workspace: workspaceA.path);
      final withoutWorkspace =
          await harness.core.sessionRepo.create(title: '无工作区');
      final group = await harness.ws.request('group.create', {
        'title': '带工作区组',
        'workspace': workspaceB.path,
      });
      expect(group['error'], isNull);
      final groupId = ((group['result'] as Map)['group'] as Map)['id'] as String;

      final sessions = ((await harness.ws.request('session.list'))['result']
          as Map)['sessions'] as List;
      for (final row in sessions.cast<Map>()) {
        expect(row.containsKey('workspace'), isTrue,
            reason: 'session.list 的每一项都必须带 workspace 键（null 也要在）');
      }
      final byId = {
        for (final row in sessions.cast<Map>()) row['id']: row['workspace'],
      };
      _obs('session.list 的 workspace 映射', byId);
      expect(byId[withWorkspace.id], workspaceA.path);
      expect(byId[withoutWorkspace.id], isNull);
      expect(byId[groupId], workspaceB.path);

      final groups = ((await harness.ws.request('group.list'))['result']
          as Map)['groups'] as List;
      for (final row in groups.cast<Map>()) {
        expect(row.containsKey('workspace'), isTrue,
            reason: 'group.list 的每一项都必须带 workspace 键');
      }
      final groupRow =
          groups.cast<Map>().singleWhere((row) => row['id'] == groupId);
      _obs('group.list 的组 workspace', groupRow['workspace']);
      expect(groupRow['workspace'], workspaceB.path);
    });

    test('方法清单：两个新方法在常量里且已注册（_registerMethods 不抛 StateError）', () async {
      _obs('常量里的方法数', kCoreRpcMethodNames.length);
      expect(kCoreRpcMethodNames, containsAll(<String>[
        'session.setWorkspace',
        'group.setWorkspace',
      ]));
      final registered = harness.core.rpcMethods;
      _obs('核心已注册方法（工作路径相关）',
          registered.where((m) => m.contains('etWorkspace')).toList());
      expect(registered, containsAll(<String>[
        'session.setWorkspace',
        'group.setWorkspace',
      ]));
    });
  });

  // ---------------------------------------------------------------------------
  // 返工 12.1：文件夹选择对话框的列目录 RPC（`workspace.listDirs`）
  //
  // 判据：**只列子目录**（文件不得混进来）、省略 `path` 用注入的主目录、
  // `parent` 是上级绝对路径（根为 null）、非法路径 `-32602` 且消息可归因。
  // 夹具全在临时目录里（`homeDir` 注入），不列举用户真实主目录。
  // ---------------------------------------------------------------------------
  group('workspace.listDirs（文件夹选择）', () {
    late _Harness harness;
    late Directory base;
    late Directory home;
    late Directory target;
    late List<File> files;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('workspace_dirs_');
      home = Directory(p.join(base.path, 'home'))..createSync(recursive: true);
      target = Directory(p.join(base.path, 'target'))..createSync(recursive: true);
      Directory(p.join(target.path, 'alpha')).createSync(recursive: true);
      Directory(p.join(target.path, 'beta')).createSync(recursive: true);
      Directory(p.join(target.path, 'zed-empty')).createSync(recursive: true);
      files = [
        for (final name in ['a-file.txt', 'b-file.txt'])
          File(p.join(target.path, name))..writeAsStringSync('x'),
      ];
      harness = await _Harness.start(homeDir: home.path);
    });

    tearDown(() async {
      await harness.stop();
      if (base.existsSync()) {
        try {
          base.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('省略 path（与只有空白）⇒ 起点是注入的主目录；回包 exists / isDirectory 为真', () async {
      final omitted = await harness.ws.request('workspace.listDirs');
      _obs('省略 path 的回包', omitted);
      expect(omitted['error'], isNull);
      final result = omitted['result'] as Map;
      expect(p.equals(result['path'] as String, home.path), isTrue,
          reason: '省略 path 必须用注入的主目录当起点，实测 ${result['path']}');
      expect(result['exists'], isTrue);
      expect(result['isDirectory'], isTrue);
      expect(result['directories'], isEmpty);
      expect(result['parent'], isNotNull,
          reason: '临时主目录的上级（临时根）必须给出来，不是 null');

      final blank = await harness.ws.request('workspace.listDirs', {'path': '   '});
      _obs('只有空白的 path 的回包', blank);
      expect(blank['error'], isNull);
      expect(p.equals((blank['result'] as Map)['path'] as String, home.path), isTrue,
          reason: '只有空白 = 省略（起点仍是主目录）');
    });

    test('只列子目录（不含文件）、按名字排序、每项 path 是绝对路径、parent 是上级', () async {
      final response = await harness.ws.request('workspace.listDirs', {
        'path': target.path,
      });
      _obs('列举夹具目录的回包', response);
      expect(response['error'], isNull);
      final result = response['result'] as Map;
      final directories = (result['directories'] as List).cast<Map>();
      _obs('子目录（名字）', [for (final entry in directories) entry['name']]);
      expect(
        [for (final entry in directories) entry['name']],
        ['alpha', 'beta', 'zed-empty'],
        reason: '只列子目录且按名字排序：两个文件不得混进来',
      );
      for (final entry in directories) {
        final path = entry['path'] as String;
        expect(p.isAbsolute(path), isTrue, reason: '子目录 path 必须是绝对路径：$path');
        expect(p.equals(path, p.join(target.path, entry['name'] as String)), isTrue,
            reason: '子目录 path 必须是父目录 + 名字：$path');
        expect(p.isWithin(target.path, path), isTrue);
      }
      expect(result['exists'], isTrue);
      expect(result['isDirectory'], isTrue);
      expect(p.equals(result['parent'] as String, base.path), isTrue,
          reason: 'parent 必须是上级绝对路径，实测 ${result['parent']}');
    });

    test('文件系统根：Windows 盘符根 parent 是「此电脑」；POSIX 根仍为 null', () async {
      final root = p.rootPrefix(target.path);
      final response = await harness.ws.request('workspace.listDirs', {'path': root});
      final result = response['result'] as Map;
      _obs('列举根目录 $root 的 parent（只读目录项，不写入）', result['parent']);
      expect(response['error'], isNull,
          reason: '根目录必须可列举（不是"不存在"）：${response['error']}');
      if (Platform.isWindows) {
        expect(result['parent'], kWorkspaceDrivesRoot,
            reason: '盘符根的上一级必须是「此电脑」虚拟根，否则其它盘不可达');
      } else {
        expect(result['parent'], isNull);
      }
      expect(result['isDirectory'], isTrue);
    });

    test('「此电脑」drives 根：Windows 列出本机盘且含当前盘；POSIX 可归因拒绝', () async {
      final response = await harness.ws.request('workspace.listDirs', {
        'path': kWorkspaceDrivesRoot,
      });
      _obs('drives 根回包', response);
      if (Platform.isWindows) {
        expect(response['error'], isNull,
            reason: 'Windows 必须支持「此电脑」：${response['error']}');
        final result = response['result'] as Map;
        final directories = (result['directories'] as List).cast<Map>();
        _obs('本机盘符', [for (final entry in directories) entry['name']]);
        expect(result['path'], kWorkspaceDrivesRoot);
        expect(result['parent'], isNull);
        expect(result['isDirectory'], isFalse,
            reason: '「此电脑」不是目录：界面据此禁用确认，不能被选成工作路径');
        expect(directories, isNotEmpty, reason: '至少应枚举到当前盘');
        final paths = [for (final entry in directories) entry['path'] as String];
        final currentRoot = p.rootPrefix(Directory.current.path);
        expect(paths.any((path) => p.equals(path, currentRoot)), isTrue,
            reason: '盘符列表必须含当前盘 $currentRoot，实测 $paths');
        for (final entry in directories) {
          final path = entry['path'] as String;
          expect(p.isAbsolute(path), isTrue, reason: '盘符 path 必须绝对：$path');
          expect(RegExp(r'^[A-Za-z]:\\$').hasMatch(path), isTrue,
              reason: '盘符 path 必须是 `X:\\`：$path');
          expect(entry['name'], path.substring(0, 2));
        }
      } else {
        expect((response['error'] as Map)['code'], -32602,
            reason: 'POSIX 没有盘符层，drives 根必须可归因拒绝');
        expect('${(response['error'] as Map)['message']}', contains('此电脑'));
      }
    });

    test('不存在 / 指向文件 / 相对路径 / 类型不对 ⇒ -32602，消息含路径与原因', () async {
      final cases = <String, ({String path, String reason})>{
        '不存在': (path: p.join(base.path, 'no-such-dir-9f1'), reason: '不存在'),
        '指向文件': (path: files.first.path, reason: '不是目录'),
        '相对': (path: p.join('relative', 'dir'), reason: '绝对路径'),
      };
      for (final entry in cases.entries) {
        final response = await harness.ws.request('workspace.listDirs', {
          'path': entry.value.path,
        });
        _obs('非法 path（${entry.key}）', response);
        expect((response['error'] as Map)['code'], -32602,
            reason: '${entry.key} 必须被拒绝');
        final message = '${(response['error'] as Map)['message']}';
        expect(message, contains(entry.value.path), reason: '错误消息必须点名该路径');
        expect(message, contains(entry.value.reason), reason: '错误消息必须含原因');
      }

      final wrongType = await harness.ws.request('workspace.listDirs', {'path': 42});
      _obs('非字符串 path', wrongType);
      expect((wrongType['error'] as Map)['code'], -32602);
      expect('${(wrongType['error'] as Map)['message']}', contains('path'));
    });

    test('方法清单含 workspace.listDirs 且已注册（_registerMethods 不抛 StateError）', () async {
      _obs('方法清单长度', kCoreRpcMethodNames.length);
      expect(kCoreRpcMethodNames, contains('workspace.listDirs'));
      final registered = harness.core.rpcMethods;
      _obs('已注册的 workspace.* 方法',
          registered.where((name) => name.startsWith('workspace.')).toList());
      expect(registered, contains('workspace.listDirs'));
    });
  });
}
