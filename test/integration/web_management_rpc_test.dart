// 无头核心「管理 RPC 面」的端到端集成测试（change `web-management-ui`）。
//
// 覆盖任务：
//   0.1 组合根配置进程内同步（design D1）
//   0.2 启动门空配置支持（design D2）
//   0.3 AgentSessionController 接线（design D3）
//   0.4 管理 RPC 面骨架 + 隔离注入（design D5 / D14）
//   1.2 会话 RPC：新建/删除/重命名/切换 + deleting 阶段守卫（design D4）
//
// 隔离（血泪教训，design D14）：**每一个**用例都用 `$env:TEMP` 下新建的临时目录里的
// configPath + 临时数据库 + 假 sidecar + 假 probe，绝不写用户真实 `~/.aliasagent/`。
// 断言前打印实际 RPC 响应与事件序列（TESTING.md §3.1）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/user_profile.dart';
import 'package:alias_agent/services/agent_config_resolver.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/image_budget.dart';
import 'package:alias_agent/services/model_discovery_service.dart';

import 'helpers/fake_sidecar.dart';

const AgentTypeConfig _generalTemplate = AgentTypeConfig(
  name: 'general',
  provider: 'p',
  model: 'm',
  systemPrompt: '',
  tools: ['read_file'],
  maxContextTokens: 100000,
);

const AgentTypeConfig _altTemplate = AgentTypeConfig(
  name: 'alt',
  provider: 'q',
  model: 'm2',
  systemPrompt: '',
  tools: ['read_file'],
  maxContextTokens: 100000,
);

const ProviderConfig _providerP =
    ProviderConfig(apiKey: 'key-p', baseUrl: 'http://127.0.0.1:1');

const ProviderConfig _providerQ =
    ProviderConfig(apiKey: 'key-q', baseUrl: 'http://127.0.0.1:2');

final AppConfig _baseConfig = AppConfig(
  version: 1,
  providers: const {'p': _providerP},
  agentTypes: const {'general': _generalTemplate},
);

/// 加了一个 provider `q` 与用它的模板 `alt` 的下一版配置。
final AppConfig _configWithQ = _baseConfig.copyWith(
  providers: const {'p': _providerP, 'q': _providerQ},
  agentTypes: const {'general': _generalTemplate, 'alt': _altTemplate},
);

/// 会话 RPC 用例的配置：`broken` 指向一个**不存在**的 provider（预检失败用）。
final AppConfig _configForSessionRpc = _configWithQ.copyWith(
  agentTypes: const {
    'general': _generalTemplate,
    'alt': _altTemplate,
    'broken': AgentTypeConfig(
      name: 'broken',
      provider: 'no-such-provider',
      model: 'm3',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokens: 100000,
    ),
  },
);

/// 模板 RPC 用例的配置：`spare` 带两项**未开放编辑**的字段（保存必须原样保留）。
final AppConfig _configForTemplateRpc = _configWithQ.copyWith(
  agentTypes: const {
    'general': _generalTemplate,
    'alt': _altTemplate,
    'spare': AgentTypeConfig(
      name: 'spare',
      provider: 'p',
      model: 'm-spare',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokens: 100000,
      commandTimeoutMs: 999999,
      standingRequirements: ['keep-me'],
    ),
  },
);

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 一张只够判"是 PNG + 宽高"的最小字节串（probeImageBytes 只看文件头/IHDR）。
Uint8List _tinyPng({int width = 2, int height = 3}) {
  final bytes = BytesBuilder();
  bytes.add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  bytes.add(<int>[0, 0, 0, 13]);
  bytes.add(ascii.encode('IHDR'));
  bytes.add(<int>[
    (width >> 24) & 0xFF, (width >> 16) & 0xFF, (width >> 8) & 0xFF, width & 0xFF,
    (height >> 24) & 0xFF, (height >> 16) & 0xFF, (height >> 8) & 0xFF, height & 0xFF,
    8, 6, 0, 0, 0,
  ]);
  return bytes.toBytes();
}

/// 假 probe：按预置的 `fetch` 返回值驱动探测，绝不联网（design D14）。
class _FakeProbe implements ModelCatalogProbe {
  _FakeProbe(this.result);

  ModelCatalogProbeResult result;
  final List<Map<String, String>> calls = [];

  @override
  Future<ModelCatalogProbeResult> fetch({
    required String baseUrl,
    required String apiKey,
    required int previewChars,
  }) async {
    calls.add({'baseUrl': baseUrl, 'apiKey': apiKey, 'previewChars': '$previewChars'});
    return result;
  }
}

ModelCatalogProbeResult _catalogResult(List<String> ids) =>
    ModelCatalogProbeResult.success(
      [
        for (final id in ids)
          ModelCatalogEntry.fromJson({
            'id': id,
            'display_name': '模型 $id',
            'context_window': 100000,
            'modalities': {
              'input': ['text', 'image'],
            },
          })!,
      ],
      0,
    );

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
    return completer.future.timeout(const Duration(seconds: 20));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}

Future<void> _waitUntil(bool Function() predicate, String what,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等待 "$what" 超时');
}

/// 一套「临时目录 + 临时配置 + 临时库 + 无头核心 + 一条 WS」的隔离装置。
class _Harness {
  _Harness({
    required this.core,
    required this.ws,
    required this.dir,
    required this.configPath,
    required this.attachmentsDir,
    required this.sidecar,
    required this.probe,
  });

  final HeadlessCore core;
  final _WsClient ws;
  final Directory dir;
  final String configPath;
  final String attachmentsDir;
  final FakeSidecar sidecar;
  final _FakeProbe probe;

  static Future<_Harness> start({
    AppConfig? config,
    String? configText,
    bool writeConfig = true,
    FakeSidecar? sidecar,
    ModelCatalogProbeResult? probeResult,
    bool useRunner = true,
  }) async {
    final dir = Directory.systemTemp.createTempSync('web_management_rpc_');
    final configPath = p.join(dir.path, 'config.json');
    final attachmentsDir = p.join(dir.path, 'attachments');
    final dbDir = Directory(p.join(dir.path, 'db'))..createSync();
    if (writeConfig) {
      if (configText != null) {
        File(configPath).writeAsStringSync(configText);
      } else {
        ConfigService.save(config ?? _baseConfig, configPath: configPath);
      }
    }
    final fake = sidecar ?? FakeSidecar();
    final probe = _FakeProbe(probeResult ?? _catalogResult(['m', 'm2']));

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final HeadlessCore core;
    if (useRunner) {
      core = await HeadlessCoreRunner.start(
        configPath: configPath,
        lockPath: p.join(dir.path, 'core.lock'),
        webRoot: p.join(dir.path, 'no-such-web-root'),
        attachmentsDir: attachmentsDir,
        probe: probe,
        openDatabaseOverride: () => DatabaseService.openAt(dbDir.path),
        sidecarLoader: () => fake,
      );
    } else {
      core = await buildHeadlessCore(
        config: config ?? _baseConfig,
        sidecar: fake,
        configPath: configPath,
        attachmentsDir: attachmentsDir,
        probe: probe,
        openDatabase: () => DatabaseService.openAt(dbDir.path),
      );
      await core.start(webRoot: p.join(dir.path, 'no-such-web-root'));
    }
    final ws = await _WsClient.connect(core.websocketUrl);
    return _Harness(
      core: core,
      ws: ws,
      dir: dir,
      configPath: configPath,
      attachmentsDir: attachmentsDir,
      sidecar: fake,
      probe: probe,
    );
  }

  Future<void> stop() async {
    await ws.close();
    await core.stop();
    try {
      DatabaseService.reset();
    } catch (_) {}
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 文件锁：临时目录删不掉不影响结果。
    }
  }
}

void main() {
  // 说明：本文件是 `test()` + 真实 IO（HttpServer / WebSocket / sqlite）。**不要**
  // 初始化 TestWidgetsFlutterBinding（它会装 HttpOverrides，静态服务用例会失效）。

  group('0.1 组合根配置进程内同步（D1）', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start();
    });

    tearDown(() async {
      await harness.stop();
    });

    test('新增 provider 保存后（组合根同步）新会话 resolveCandidate 读到新 provider', () async {
      final core = harness.core;
      // 前提：模板可以先登记进来，但 provider 表还是旧快照 —— 运行中的核心读不到
      // 刚写盘的新 provider（design 现状 1）。
      core.templates.register(_altTemplate);
      Object? beforeSync;
      try {
        core.factory.resolveCandidate('alt');
      } catch (e) {
        beforeSync = e;
      }
      _obs('同步前 resolveCandidate("alt") 的结果', beforeSync);
      expect(beforeSync, isA<MissingAgentProviderException>(),
          reason: '前提：未同步时运行中核心仍拿着旧 ProviderResolver 快照');

      // 模拟「config.save 已写盘」然后触发组合根同步（D1 的等价物 _applyProviderConfig）。
      ConfigService.save(_configWithQ, configPath: harness.configPath);
      core.applyConfig(_configWithQ);

      Object? afterSync;
      try {
        final candidate = core.factory.resolveCandidate('alt');
        _obs('同步后 resolveCandidate("alt") 的 provider', candidate.provider.apiKey);
        expect(candidate.provider.apiKey, 'key-q');
      } catch (e) {
        afterSync = e;
      }
      _obs('同步后 resolveCandidate("alt") 的结果', afterSync);
      expect(afterSync, isNull,
          reason: '同步后必须能从新配置解析到新 provider，不抛 MissingAgentProviderException');
      expect(core.templates.contains('alt'), isTrue, reason: '模板必须重注册进运行中的注册表');
      expect(core.config.providers.keys, containsAll(['p', 'q']),
          reason: 'core.config 必须跟着同步（后续 RPC 读它）');
    });
  });

  group('0.2 启动门空配置支持（D2）', () {
    test('配置文件不存在：以空配置启动并 serve（不再拒启动）', () async {
      final harness = await _Harness.start(writeConfig: false);
      addTearDown(harness.stop);
      _obs('空配置启动 URL', harness.core.url);
      _obs('启动提示', harness.core.startupNotice);
      expect(harness.core.port, greaterThan(0));
      expect(harness.core.startupNotice, isNotNull,
          reason: '空配置启动必须给出可见提示（用户要知道为什么是空的）');
      expect(harness.core.startupNotice, contains('配置文件不存在'));

      // 核心确实在服务：RPC 可应答，HTTP 静态服务给可归因的 503（缺构建产物）。
      final list = await harness.ws.request('session.list');
      _obs('空配置 session.list', list['result']);
      expect((list['result'] as Map)['sessions'], isEmpty);

      final client = HttpClient();
      try {
        final request = await client.getUrl(harness.core.url.replace(path: '/'));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        _obs('空配置 GET / 状态 / 正文', '${response.statusCode} / $body');
        expect(response.statusCode, 503);
        expect(body, contains('web 客户端产物不存在'));
      } finally {
        client.close(force: true);
      }
    });

    test('配置文件 malformed：仍可归因失败，且不静默覆盖原文', () async {
      final dir = Directory.systemTemp.createTempSync('wm_malformed_');
      final configPath = p.join(dir.path, 'config.json');
      const broken = '{ "providers": ';
      File(configPath).writeAsStringSync(broken);
      HeadlessCoreStartupException? caught;
      try {
        await HeadlessCoreRunner.start(
          configPath: configPath,
          lockPath: p.join(dir.path, 'core.lock'),
          webRoot: p.join(dir.path, 'no-such-web-root'),
          openDatabaseOverride: () async {},
          sidecarLoader: () => FakeSidecar(),
        );
      } on HeadlessCoreStartupException catch (e) {
        caught = e;
      }
      _obs('malformed 配置的启动错误', caught?.message);
      expect(caught, isNotNull, reason: '坏配置必须拒启动，不能静默当空配置');
      expect(caught!.message, contains('配置文件无法解析'));
      expect(File(configPath).readAsStringSync(), broken,
          reason: '拒绝启动时不得改写用户的配置文件');
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  group('0.3 AgentSessionController 接线（D3）', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start(config: _configWithQ);
    });

    tearDown(() async {
      await harness.stop();
    });

    test('切换模板后事件发往当前 WS 订阅者（新实例带当前回调）', () async {
      final core = harness.core;
      final session = await core.sessionRepo.create();
      _obs('新会话默认模板', session.agentType);
      expect(session.agentType, 'general');

      final switched = await core.sessionController.switchTemplate(
        session,
        'alt',
        callbacks: core.callbacksFor(session.id),
      );
      _obs('切换后的实例模板', switched.agentTypeName);
      expect(switched.agentTypeName, 'alt');
      expect(core.sessionController.agentFor(session.id), same(switched));

      harness.sidecar
        ..queueChunk('切换后')
        ..queueDone();
      await switched.send('你好');
      _obs('切换后的事件序列', harness.ws.eventTypes);
      expect(harness.ws.eventTypes, contains('assistant.chunk'),
          reason: '组合根构造的控制器必须把当前 WS 回调交给新实例（默认空回调会让事件消失）');
      final chunk =
          harness.ws.events.lastWhere((e) => e['type'] == 'assistant.chunk');
      _obs('chunk 事件', chunk);
      expect(chunk['sessionId'], session.id);
      expect((chunk['data'] as Map)['text'], '切换后');

      final reread = await core.sessionRepo.get(session.id);
      expect(reread!.agentType, 'alt', reason: '切换必须持久化 agent_type');
    });
  });

  group('0.4 管理 RPC 面骨架 + 隔离注入（D5 / D14）', () {
    test('组合根暴露 configPath / attachmentsDir / probe 注入，RPC 表与常量一致', () async {
      final harness = await _Harness.start();
      addTearDown(harness.stop);
      final core = harness.core;
      _obs('注入的 configPath', core.configPath);
      _obs('注入的 attachmentsDir', core.attachmentsDir);
      _obs('注入的 probe 类型', core.probe.runtimeType);
      expect(core.configPath, harness.configPath,
          reason: '测试隔离：组合根必须用注入的临时 configPath，绝不写用户真实配置');
      expect(core.attachmentsDir, harness.attachmentsDir,
          reason: '测试隔离：附件目录必须可注入（临时目录）');
      expect(core.probe, same(harness.probe), reason: '假 probe 必须原样注入（不联网）');

      _obs('已注册 RPC 方法', core.rpcMethods);
      expect(core.rpcMethods, kCoreRpcMethodNames,
          reason: '注册表必须与 kCoreRpcMethodNames 完全一致（漏注册会在 start 抛 StateError）');
      expect(core.rpcMethods.toSet().length, core.rpcMethods.length,
          reason: 'RPC 方法名不得重复注册');

      // 隔离证据：临时配置里的 provider 就是测试写进去的那一份（组合根读写都指向它，
      // 因此后续 config.save / probe 的用例也不会碰到用户真实 ~/.aliasagent/）。
      final loaded = ConfigService.load(configPath: harness.configPath);
      _obs('临时配置状态 / provider 名', loaded.status);
      expect(loaded.status, ConfigStatus.ok);
      expect(loaded.config!.providers.keys, ['p']);
    });
  });

  group('1.2 会话 RPC（D4）', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start(config: _configForSessionRpc);
    });

    tearDown(() async {
      await harness.stop();
    });

    test('新建 / 重命名 / 切换模板 / 删除 全链路成功', () async {
      final core = harness.core;
      final created = await harness.ws.request('session.create', {'title': 'web 新建'});
      _obs('session.create 响应', created['result']);
      final session = (created['result'] as Map)['session'] as Map;
      expect(session['title'], 'web 新建');
      expect(session['agentType'], 'general');
      final sessionId = session['id'] as String;

      final renamed = await harness.ws
          .request('session.rename', {'sessionId': sessionId, 'title': '改过的标题'});
      _obs('session.rename 响应', renamed['result']);
      expect((renamed['result'] as Map)['session']['title'], '改过的标题');
      expect((await core.sessionRepo.get(sessionId))!.title, '改过的标题');

      final switched = await harness.ws.request(
          'session.switchTemplate', {'sessionId': sessionId, 'templateName': 'alt'});
      _obs('session.switchTemplate 响应', switched['result']);
      expect((switched['result'] as Map)['agentType'], 'alt');
      expect((await core.sessionRepo.get(sessionId))!.agentType, 'alt');
      expect(core.agents.lookup(sessionId)?.agentTypeName, 'alt');

      final deleted =
          await harness.ws.request('session.delete', {'sessionId': sessionId});
      _obs('session.delete 响应', deleted['result']);
      expect((deleted['result'] as Map)['deleted'], isTrue);
      expect(await core.sessionRepo.get(sessionId), isNull);
      expect(core.agents.lookup(sessionId), isNull, reason: '实例必须一起销毁并移出注册表');
    });

    test('切换模板预检失败可归因：显示阶段+候选名，旧实例与数据库不变', () async {
      final core = harness.core;
      final session = await core.sessionRepo.create();
      final before = await core.factory.ensure(session);
      final response = await harness.ws.request('session.switchTemplate',
          {'sessionId': session.id, 'templateName': 'broken'});
      _obs('预检失败的切换响应', response);
      final error = response['error'] as Map;
      expect(error['code'], -32602);
      expect('${error['message']}', contains('候选预检'));
      expect('${error['message']}', contains('broken'));
      expect(core.agents.lookup(session.id), same(before), reason: '旧实例必须原样保留');
      expect((await core.sessionRepo.get(session.id))!.agentType, 'general',
          reason: '数据库不得被改写，也不静默退回 general（本来就是 general）');
    });

    test('删除进行中切换 → deleting 阶段拒绝（RPC 守卫，变异①红靶）', () async {
      final core = harness.core;
      final session = await core.sessionRepo.create();
      await core.factory.ensure(session);

      // 把"删除进行中"的窗口摆出来：删除流程在 disposeContext 那一步被挡住，
      // 此时 beginDelete 已登记（_deleting 含该会话）、endDelete 还没执行。
      final gate = Completer<void>();
      harness.sidecar.disposeContextGate = gate;
      final deleteFuture =
          harness.ws.request('session.delete', {'sessionId': session.id});
      await _waitUntil(
          () => core.sessionController.isDeleting(session.id), '删除登记进行中');
      _waitUntil(() => harness.sidecar.disposeContextCalls.contains(session.id),
          '删除走到 disposeContext');
      _obs('删除进行中的状态',
          'isDeleting=${core.sessionController.isDeleting(session.id)}');

      // 关键断言：删除进行中的切换必须被 deleting 阶段拒绝，且删除不得先于它返回。
      final switchResponse = await harness.ws.request('session.switchTemplate',
          {'sessionId': session.id, 'templateName': 'alt'});
      _obs('删除进行中的切换响应', switchResponse);
      expect(switchResponse['result'], isNull, reason: '删除进行中的切换不得成功');
      final error = switchResponse['error'] as Map;
      expect(error['code'], -32602);
      expect('${error['message']}', contains('deleting'),
          reason: '必须指出阶段 deleting（可归因），不能只说"切换失败"');
      expect('${error['message']}', contains('会话正在删除'));
      expect('${error['message']}', contains('alt'), reason: '必须点名候选模板');
      expect((await core.sessionRepo.get(session.id))?.agentType, isNot('alt'),
          reason: '删除进行中的切换不得落库');

      // 收尾：放行销毁，删除完成。
      gate.complete();
      final deleteResponse = await deleteFuture;
      _obs('删除最终响应', deleteResponse['result']);
      expect((deleteResponse['result'] as Map)['deleted'], isTrue);
      expect(await core.sessionRepo.get(session.id), isNull);
      expect(core.sessionController.isDeleting(session.id), isFalse,
          reason: '删除结束必须解除守卫');
    });

    test('删除/重命名不存在的会话：可归因错误（不静默 no-op）', () async {
      final core = harness.core;
      for (final call in <({String method, Map<String, dynamic> params})>[
        (method: 'session.delete', params: {'sessionId': 'no-such-session'}),
        (
          method: 'session.rename',
          params: {'sessionId': 'no-such-session', 'title': 'x'}
        ),
        (
          method: 'session.switchTemplate',
          params: {'sessionId': 'no-such-session', 'templateName': 'alt'}
        ),
      ]) {
        final response = await harness.ws.request(call.method, call.params);
        _obs('${call.method} 不存在会话的响应', response);
        expect((response['error'] as Map)['code'], -32602, reason: call.method);
        expect('${(response['error'] as Map)['message']}', contains('不存在'),
            reason: '${call.method} 必须可归因');
      }
      expect(await core.sessionRepo.list(), isEmpty);
    });

    test('session.create 指定未定义模板 → 可归因拒绝', () async {
      final response = await harness.ws
          .request('session.create', {'agentType': 'no-such-template'});
      _obs('create 非法模板的响应', response);
      expect((response['error'] as Map)['code'], -32602);
      expect('${(response['error'] as Map)['message']}', contains('no-such-template'));
    });
  });

  group('2.1 附件 RPC（D12）', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start();
    });

    tearDown(() async {
      await harness.stop();
    });

    test('attachment.upload：图片落盘到注入的临时 attachmentsDir 并返回路径', () async {
      final png = _tinyPng(width: 7, height: 9);
      final response = await harness.ws.request('attachment.upload', {
        'filename': 'shot.png',
        'base64': base64Encode(png),
      });
      _obs('attachment.upload 响应', response['result']);
      final result = response['result'] as Map;
      final path = result['path'] as String;
      expect(path, startsWith(harness.attachmentsDir),
          reason: '必须落到注入的临时附件目录（不碰用户真实目录）');
      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), png);
      expect(result['bytes'], png.length);
      expect(result['format'], 'png');
      expect(result['mediaType'], 'image/png');
      _obs('落盘文件大小', File(path).lengthSync());
    });

    test('attachment.upload：超过 kMaxImageBytes 可归因拒绝（指明上限与出处）', () async {
      final oversized = Uint8List(kMaxImageBytes + 1);
      final response = await harness.ws.request('attachment.upload', {
        'filename': 'huge.png',
        'base64': base64Encode(oversized),
      });
      _obs('超限上传错误', response['error']);
      final error = response['error'] as Map;
      expect(error['code'], -32602);
      expect('${error['message']}', contains('$kMaxImageBytes'));
      expect('${error['message']}', contains('§6.4.3'));
      expect(Directory(harness.attachmentsDir).existsSync(), isFalse,
          reason: '被拒绝的上传不得落盘（也不静默截断）');
    });

    test('attachment.upload：非图片（文件头魔数不是 PNG/JPEG/GIF/WebP）拒绝', () async {
      final response = await harness.ws.request('attachment.upload', {
        'filename': 'not-an-image.txt',
        'base64': base64Encode(utf8.encode('hello, not an image')),
      });
      _obs('非图片上传错误', response['error']);
      final error = response['error'] as Map;
      expect(error['code'], -32602);
      expect('${error['message']}', contains('不是支持的图片格式'));
      expect('${error['message']}', contains('文件头'));
    });

    test('attachment.read：取回同一份字节；丢失与越界都可归因', () async {
      final png = _tinyPng();
      final uploaded = await harness.ws.request('attachment.upload', {
        'filename': 'roundtrip.png',
        'base64': base64Encode(png),
      });
      final path = (uploaded['result'] as Map)['path'] as String;

      final read = await harness.ws.request('attachment.read', {'path': path});
      _obs('attachment.read 响应 keys', (read['result'] as Map).keys.toList());
      final readResult = read['result'] as Map;
      expect(base64Decode(readResult['base64'] as String), png);
      expect(readResult['mediaType'], 'image/png');
      expect(readResult['bytes'], png.length);

      final missing = await harness.ws.request('attachment.read',
          {'path': p.join(harness.attachmentsDir, 'gone.png')});
      _obs('丢失文件的 read 错误', missing['error']);
      expect((missing['error'] as Map)['code'], -32602);
      expect('${(missing['error'] as Map)['message']}', contains('图片已丢失'));

      final outside = await harness.ws.request('attachment.read', {
        'path': p.join(harness.dir.path, 'not-in-attachments.png'),
      });
      _obs('越界的 read 错误', outside['error']);
      expect((outside['error'] as Map)['code'], -32602);
      expect('${(outside['error'] as Map)['message']}', contains('附件目录'));
    });
  });

  group('3.1 config / provider RPC（D6 / D7）', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start();
    });

    tearDown(() async {
      await harness.stop();
    });

    test('config.get 脱敏：api_key 明文绝不出现在响应里', () async {
      final response = await harness.ws.request('config.get');
      _obs('config.get 响应（截断）',
          jsonEncode(response['result']).substring(0, 200));
      final result = response['result'] as Map;
      expect(result['missing'], isFalse);
      final providers = result['providers'] as Map;
      final provider = providers['p'] as Map;
      expect(provider['baseUrl'], 'http://127.0.0.1:1');
      expect(provider['hasApiKey'], isTrue);
      expect(provider.containsKey('apiKey'), isFalse,
          reason: 'config.get 不许有 apiKey 字段（产品规范 SHALL NOT 回显明文）');
      final raw = jsonEncode(response['result']);
      expect(raw, isNot(contains('key-p')), reason: '明文密钥不得出现在任何字段里');
      expect((result['agentTypes'] as Map)['general'], isA<Map>());
      expect((result['tools'] as List), contains('read_file'));
    });

    test('config.save：新增 provider 写盘 + 组合根同步；留空密钥沿用原值', () async {
      final saved = await harness.ws.request('config.save', {
        'providers': {
          'p': {'base_url': 'http://127.0.0.1:1'}, // 不传 api_key ⇒ 沿用
          'q': {'base_url': 'http://127.0.0.1:9', 'api_key': 'key-q'},
        },
      });
      _obs('config.save 响应 keys', (saved['result'] as Map).keys.toList());
      expect(saved['error'], isNull);
      final disk = ConfigService.load(configPath: harness.configPath);
      _obs('落盘的 provider 名', disk.config!.providers.keys.toList());
      expect(disk.config!.providers.keys, containsAll(['p', 'q']));
      expect(disk.config!.providers['p']!.apiKey, 'key-p',
          reason: '留空 = 沿用原密钥（不静默丢密钥）');
      expect(disk.config!.providers['q']!.apiKey, 'key-q');
      expect(harness.core.config.providers.keys, containsAll(['p', 'q']),
          reason: '保存成功后组合根必须进程内同步（D1）');
      expect(harness.core.providerResolverRef.current.resolve('q'), isNotNull);
    });

    test('config.save：非标准端点 / 缺密钥 / 删除被引用 provider 都可归因拒绝', () async {
      Future<Map<String, dynamic>> attempt(Map<String, dynamic> providers) =>
          harness.ws.request('config.save', {'providers': providers});

      final badUrl = await attempt({
        'p': {'base_url': 'ftp://127.0.0.1:1'},
      });
      _obs('非 http 地址的错误', badUrl['error']);
      expect((badUrl['error'] as Map)['code'], -32602);
      expect('${(badUrl['error'] as Map)['message']}', contains('http://'));

      final noKey = await attempt({
        'p': {'base_url': 'http://127.0.0.1:1'},
        'newp': {'base_url': 'http://127.0.0.1:5'},
      });
      _obs('缺密钥的错误', noKey['error']);
      expect((noKey['error'] as Map)['code'], -32602);
      expect('${(noKey['error'] as Map)['message']}', contains('API Key'));

      final deleteReferenced = await attempt(<String, dynamic>{});
      _obs('删除被引用 provider 的错误', deleteReferenced['error']);
      expect((deleteReferenced['error'] as Map)['code'], -32602);
      expect('${(deleteReferenced['error'] as Map)['message']}', contains('引用'));
      expect('${(deleteReferenced['error'] as Map)['message']}', contains('general'));
      // 失败不得写盘：磁盘上原始 provider 仍在。
      expect(ConfigService.load(configPath: harness.configPath).config!.providers.keys,
          ['p']);
    });

    test('config.save：向导探测到的目录随同一次保存写盘（不联网二次探测）', () async {
      final saved = await harness.ws.request('config.save', {
        'providers': {
          'p': {
            'base_url': 'http://127.0.0.1:1',
            'models': [
              {'id': 'first-model', 'context_window': 1048576},
              {'id': 'second-model'},
            ],
          },
        },
      });
      _obs('带目录保存的错误', saved['error']);
      expect(saved['error'], isNull);
      final disk = ConfigService.load(configPath: harness.configPath).config!;
      _obs('落盘的目录 / discovered_at',
          '${[for (final m in disk.providers['p']!.models) m.id]} / '
          '${disk.providers['p']!.discoveredAt}');
      expect([for (final m in disk.providers['p']!.models) m.id],
          ['first-model', 'second-model']);
      expect(disk.providers['p']!.discoveredAt, isNotNull,
          reason: '带 models 保存时核心补 discovered_at（向导不需要自己编时间戳）');

      final badModels = await harness.ws.request('config.save', {
        'providers': {
          'p': {
            'base_url': 'http://127.0.0.1:1',
            'models': [
              {'display_name': '没有 id'},
            ],
          },
        },
      });
      _obs('目录条目缺 id 的错误', badModels['error']);
      expect((badModels['error'] as Map)['code'], -32602);
      expect('${(badModels['error'] as Map)['message']}', contains('models[0]'));
    });

    test('config.save：改名在同一保存级联改写引用模板', () async {
      final saved = await harness.ws.request('config.save', {
        'providers': {
          'p-renamed': {'base_url': 'http://127.0.0.1:1', 'rename_from': 'p'},
        },
      });
      _obs('改名保存的错误', saved['error']);
      expect(saved['error'], isNull);
      final disk = ConfigService.load(configPath: harness.configPath).config!;
      _obs('改名后的 provider / general.provider',
          '${disk.providers.keys.toList()} / ${disk.agentTypes['general']!.provider}');
      expect(disk.providers.keys, ['p-renamed']);
      expect(disk.providers['p-renamed']!.apiKey, 'key-p', reason: '改名不丢密钥');
      expect(disk.agentTypes['general']!.provider, 'p-renamed',
          reason: '同一保存动作里级联改写引用模板');
      expect(harness.core.config.agentTypes['general']!.provider, 'p-renamed',
          reason: '组合根同步后运行中的模板表也指向新名');
    });

    test('provider.probe = discover：写回 catalog + discovered_at 并同步', () async {
      harness.probe.result = _catalogResult(['m3', 'm4']);
      final response =
          await harness.ws.request('provider.probe', {'providerName': 'p'});
      final report = response['result'] as Map;
      _obs('provider.probe 报告', report);
      expect(report['ok'], isTrue);
      expect(
          [for (final entry in report['entries'] as List) (entry as Map)['id']],
          ['m3', 'm4']);
      expect(report['discoveredAt'], isNotNull);
      expect(harness.probe.calls.last['apiKey'], 'key-p',
          reason: '探测用的密钥取自配置（不回显、不落日志）');
      final disk = ConfigService.load(configPath: harness.configPath).config!;
      expect([for (final m in disk.providers['p']!.models) m.id], ['m3', 'm4'],
          reason: '成功探测必须写回磁盘');
      expect(disk.providers['p']!.discoveredAt, isNotNull);
      expect(harness.core.config.providers['p']!.models.length, 2,
          reason: '写回后组合根同步，运行中的核心读得到新目录');
    });

    test('provider.probe：provider 不存在可归因拒绝', () async {
      final response =
          await harness.ws.request('provider.probe', {'providerName': 'nope'});
      _obs('不存在 provider 的探测错误', response['error']);
      expect((response['error'] as Map)['code'], -32602);
      expect('${(response['error'] as Map)['message']}', contains('不存在'));
    });

    test('provider.probeFetch = fetch：只探测不写盘（向导不变量）', () async {
      final before = File(harness.configPath).readAsStringSync();
      harness.probe.result = _catalogResult(['first-model', 'second-model']);
      final response = await harness.ws.request('provider.probeFetch', {
        'providerName': 'wizard',
        'baseUrl': 'http://127.0.0.1:77',
        'apiKey': 'wizard-key',
      });
      final result = response['result'] as Map;
      _obs('probeFetch 结果 ids / 首项',
          [for (final entry in result['entries'] as List) (entry as Map)['id']]);
      expect(result['ok'], isTrue);
      expect([for (final entry in result['entries'] as List) (entry as Map)['id']],
          ['first-model', 'second-model']);
      expect(harness.probe.calls.last['baseUrl'], 'http://127.0.0.1:77');
      expect(harness.probe.calls.last['apiKey'], 'wizard-key');
      _obs('probeFetch 后配置原文是否变化',
          File(harness.configPath).readAsStringSync() == before);
      expect(File(harness.configPath).readAsStringSync(), before,
          reason: 'probeFetch 只探测：不写盘、不留半份配置');
      expect(harness.core.config.providers.containsKey('wizard'), isFalse);
    });

    test('provider.probeFetch：非标准端点可归因（错误落盘路径回显）', () async {
      harness.probe.result = ModelCatalogProbeResult.nonStandard(
        error: '该端点不是 magpie 标准目录：共 10 字符，已略去 4 字符，完整内容见 C:/tmp/x.txt',
        preview: 'head…tail',
        totalChars: 10,
        omittedChars: 4,
        errorFilePath: 'C:/tmp/x.txt',
      );
      final response = await harness.ws.request('provider.probeFetch', {
        'baseUrl': 'http://127.0.0.1:78',
        'apiKey': 'k',
      });
      final result = response['result'] as Map;
      _obs('非标准端点结果', result);
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('不是 magpie 标准目录'));
      expect(result['errorFilePath'], 'C:/tmp/x.txt');
      expect(result['preview'], 'head…tail');
    });
  });

  group('3.2 模板 RPC（D9 / D10）', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start(config: _configForTemplateRpc);
    });

    tearDown(() async {
      await harness.stop();
    });

    test('template.list：模板 + 工具 + provider 名 + 生效时机提示', () async {
      final response = await harness.ws.request('template.list');
      final result = response['result'] as Map;
      _obs('template.list 的模板名', [
        for (final template in result['templates'] as List) (template as Map)['name'],
      ]);
      expect([for (final template in result['templates'] as List) (template as Map)['name']],
          containsAll(['general', 'spare']));
      expect(result['tools'], contains('read_file'));
      expect(result['providers'], containsAll(['p', 'q']));
      expect(result['defaultTools'], containsAll(['read_file', 'list_dir']),
          reason: '新模板/向导的默认工具清单由核心给出（来源唯一：ToolCatalog）');
      // 下拉选项必须是 JSON 数组（Set 会让整个响应 jsonEncode 失败 —— 实测踩过一次）。
      expect(result['thinkingEfforts'], isA<List>());
      expect(result['thinkingEfforts'], contains('max'));
      expect(result['allowedModalities'], isA<List>());
      expect(result['allowedModalities'], containsAll(['text', 'image']));
      expect(result['effectiveNote'], kAgentTemplateEffectiveNote,
          reason: '生效时机提示必须与 Flutter 用同一个常量（单一口径）');
    });

    test('template.save 新增：input_modalities 与压缩阈值都落盘（含模态勾选）', () async {
      final response = await harness.ws.request('template.save', {
        'name': 'alt2',
        'provider': 'p',
        'model': 'm2',
        'thinkingEffort': 'max',
        'systemPrompt': '你是第二个模板',
        'tools': ['read_file'],
        'maxContextTokens': '200000',
        'inputModalities': ['text', 'image'],
        'compactionThresholdPercent': 40,
        'compactionWaitThresholdPercent': 80,
      });
      _obs('template.save 新增响应', response['error']);
      expect(response['error'], isNull);
      final saved = (response['result'] as Map)['template'] as Map;
      expect(saved['name'], 'alt2');
      expect(saved['input_modalities'], ['text', 'image']);
      expect(saved['compaction_threshold_percent'], 40);

      final disk = ConfigService.load(configPath: harness.configPath).config!;
      final alt2 = disk.agentTypes['alt2']!;
      _obs('落盘的 alt2 模态 / 阈值',
          '${alt2.inputModalities} / ${alt2.compactionThresholdPercent}');
      expect(alt2.inputModalities, ['text', 'image'],
          reason: '勾选 image 模态必须写进配置（解锁图片输入）');
      expect(alt2.compactionThresholdPercent, 40);
      expect(alt2.compactionWaitThresholdPercent, 80);
      expect(harness.core.templates.contains('alt2'), isTrue);
      expect(harness.core.config.agentTypes['alt2']!.inputModalities,
          ['text', 'image']);
    });

    test('template.save 修改：模板名不可改；未开放字段原样保留', () async {
      final response = await harness.ws.request('template.save', {
        'originalName': 'spare',
        'name': 'spare',
        'provider': 'p',
        'model': 'm-spare-v2',
        'thinkingEffort': 'high',
        'systemPrompt': '',
        'tools': ['read_file'],
        'maxContextTokens': '',
        'inputModalities': ['text'],
      });
      expect(response['error'], isNull);
      final disk = ConfigService.load(configPath: harness.configPath).config!;
      final spare = disk.agentTypes['spare']!;
      _obs('保存后的 spare 未开放字段',
          'commandTimeoutMs=${spare.commandTimeoutMs} standing=${spare.standingRequirements}');
      expect(spare.commandTimeoutMs, 999999,
          reason: '未开放编辑的受支持字段必须原样保留（不静默丢失）');
      expect(spare.standingRequirements, ['keep-me']);

      final renameAttempt = await harness.ws.request('template.save', {
        'originalName': 'spare',
        'name': 'spare-renamed',
        'provider': 'p',
        'model': 'm',
        'thinkingEffort': '',
        'systemPrompt': '',
        'tools': ['read_file'],
        'maxContextTokens': '',
      });
      _obs('改名的错误', renameAttempt['error']);
      expect((renameAttempt['error'] as Map)['code'], -32602);
      expect('${(renameAttempt['error'] as Map)['message']}', contains('不可修改'));
    });

    test('template.save 非法字段可归因（provider / 工具 / 窗口 / 压缩阈值）', () async {
      Future<Map<String, dynamic>> save(Map<String, dynamic> overrides) =>
          harness.ws.request('template.save', {
            'name': 'bad',
            'provider': 'p',
            'model': 'm',
            'thinkingEffort': '',
            'systemPrompt': '',
            'tools': ['read_file'],
            'maxContextTokens': '',
            ...overrides,
          });

      final badProvider = await save({'provider': 'nope'});
      _obs('非法 provider 的错误', badProvider['error']);
      expect((badProvider['error'] as Map)['code'], -32602);
      expect('${(badProvider['error'] as Map)['message']}', contains('nope'));

      final badTool = await save({'tools': ['no_such_tool']});
      _obs('未知工具的错误', badTool['error']);
      expect('${(badTool['error'] as Map)['message']}', contains('未知工具'));

      final badWindow = await save({'maxContextTokens': '-5'});
      _obs('非法窗口的错误', badWindow['error']);
      expect('${(badWindow['error'] as Map)['message']}', contains('正整数'));

      final badPercent = await save({'compactionThresholdPercent': 200});
      _obs('非法压缩阈值的错误', badPercent['error']);
      expect('${(badPercent['error'] as Map)['message']}', contains('压缩阈值'));
      expect(ConfigService.load(configPath: harness.configPath).config!.agentTypes
          .containsKey('bad'), isFalse, reason: '校验失败不得落盘');
    });

    test('template.delete：general 不可删 / 被会话引用拒删并点名 / 无引用成功', () async {
      final general = await harness.ws
          .request('template.delete', {'templateName': 'general'});
      _obs('删 general 的错误', general['error']);
      expect((general['error'] as Map)['code'], -32602);
      expect('${(general['error'] as Map)['message']}', contains('general'));
      expect(harness.core.templates.contains('general'), isTrue);

      // 建一个引用 spare 的会话 ⇒ 删 spare 必须被拒并点名该会话。
      final created =
          await harness.ws.request('session.create', {'agentType': 'spare'});
      final session = (created['result'] as Map)['session'] as Map;
      final referenced = await harness.ws
          .request('template.delete', {'templateName': 'spare'});
      _obs('删被引用模板的错误', referenced['error']);
      expect((referenced['error'] as Map)['code'], -32602);
      expect('${(referenced['error'] as Map)['message']}', contains('spare'));
      expect('${(referenced['error'] as Map)['message']}',
          contains(session['id'] as String),
          reason: '必须显示引用会话名单（防悬空引用）');
      expect(harness.core.templates.contains('spare'), isTrue);

      // 删掉引用会话后再删模板 ⇒ 成功。
      await harness.ws.request('session.delete', {'sessionId': session['id']});
      final removed =
          await harness.ws.request('template.delete', {'templateName': 'spare'});
      _obs('删无引用模板的响应', removed['result']);
      expect(removed['error'], isNull);
      expect(harness.core.templates.contains('spare'), isFalse);
      expect(
          ConfigService.load(configPath: harness.configPath)
              .config!
              .agentTypes
              .containsKey('spare'),
          isFalse,
          reason: '删除必须写回配置');
      expect(harness.core.config.agentTypes.containsKey('spare'), isFalse,
          reason: '组合根同步后运行中的模板表也不再含它');

      final missing = await harness.ws
          .request('template.delete', {'templateName': 'no-such'});
      _obs('删不存在模板的错误', missing['error']);
      expect((missing['error'] as Map)['code'], -32602);
      expect('${(missing['error'] as Map)['message']}', contains('不存在'));
    });
  });

  // ---------------------------------------------------------------------------
  // 3.3 头像字段经 RPC 落盘（change `chat-bubbles-avatars` 3.1 / design D2 / D3）
  //
  // 红靶：落盘才是判据 —— 每条既看返回值，也读 `config.json` 原文。只断言返回值的
  // 实现（例如把 avatarPath 塞进内存配置却不写盘）在这里红。
  // ---------------------------------------------------------------------------
  group('3.3 头像字段经 RPC 落盘（chat-bubbles-avatars）', () {
    late _Harness harness;
    late String pngPath;

    setUp(() async {
      harness = await _Harness.start(config: _configForTemplateRpc);
      Directory(harness.attachmentsDir).createSync(recursive: true);
      final uploaded = await harness.ws.request('attachment.upload', {
        'filename': 'face.png',
        'base64': base64Encode(_tinyPng(width: 4, height: 4)),
      });
      pngPath = (uploaded['result'] as Map)['path'] as String;
      _obs('测试头像已落盘', pngPath);
    });

    tearDown(() async {
      await harness.stop();
    });

    AppConfig diskConfig() => ConfigService.load(configPath: harness.configPath).config!;

    Map<String, dynamic> saveTemplate({
      required String name,
      String? originalName,
      Object? avatarPath,
      bool includeAvatar = true,
    }) {
      final params = <String, dynamic>{
        'name': name,
        'originalName': ?originalName,
        'provider': 'p',
        'model': name == 'general' ? 'm' : 'm-spare',
        'thinkingEffort': 'high',
        'systemPrompt': '',
        'tools': ['read_file'],
        'maxContextTokens': '',
        if (includeAvatar) 'avatarPath': avatarPath,
      };
      return params;
    }

    test('template.save 头像三态：设置写回 / 空串清除 / 省略与 null 不改（读盘判据）', () async {
      // ① 设置：先给 general 一个真头像。
      final setResponse = await harness.ws.request('template.save', saveTemplate(
        name: 'general',
        originalName: 'general',
        avatarPath: pngPath,
      ));
      _obs('设置头像的响应', setResponse['error']);
      expect(setResponse['error'], isNull);
      final afterSet = diskConfig().agentTypes['general']!;
      _obs('设置后落盘 avatarPath', afterSet.avatarPath);
      expect(afterSet.avatarPath, p.normalize(p.absolute(pngPath)));
      expect(harness.core.config.agentTypes['general']!.avatarPath, isNotNull,
          reason: '写盘后组合根也要同步（模板页/群聊立刻能读到）');

      final listed = await harness.ws.request('template.list');
      final generalRow = (listed['result'] as Map)['templates'] as List;
      final general = generalRow
          .cast<Map>()
          .firstWhere((template) => template['name'] == 'general');
      _obs('template.list 的 general.avatar_path', general['avatar_path']);
      expect(general['avatar_path'], p.normalize(p.absolute(pngPath)),
          reason: 'template.list 返回模板完整 JSON，头像键必须可读');

      // ② 省略 = 不改。
      final omitted = await harness.ws.request(
          'template.save', saveTemplate(name: 'general', originalName: 'general', includeAvatar: false));
      _obs('省略 avatarPath 的响应', omitted['error']);
      expect(omitted['error'], isNull);
      expect(diskConfig().agentTypes['general']!.avatarPath,
          p.normalize(p.absolute(pngPath)),
          reason: '省略 avatarPath = 不改（MUST NOT 清空既有头像）');

      // ③ 显式 null = 不改。
      final nulled = await harness.ws.request('template.save',
          saveTemplate(name: 'general', originalName: 'general', avatarPath: null));
      expect(nulled['error'], isNull);
      expect(diskConfig().agentTypes['general']!.avatarPath,
          p.normalize(p.absolute(pngPath)),
          reason: '显式 null = 不改');

      // ④ 空串 = 清除（写回里不再有该键）。
      final cleared = await harness.ws.request('template.save',
          saveTemplate(name: 'general', originalName: 'general', avatarPath: ''));
      _obs('清空头像的响应', cleared['error']);
      expect(cleared['error'], isNull);
      expect(diskConfig().agentTypes['general']!.avatarPath, isNull);
      final raw = jsonDecode(File(harness.configPath).readAsStringSync()) as Map<String, dynamic>;
      final rawGeneral =
          ((raw['agent_types'] as Map)['general'] as Map).cast<String, dynamic>();
      _obs('清除后配置原文 has avatar_path', rawGeneral.containsKey('avatar_path'));
      expect(rawGeneral.containsKey('avatar_path'), isFalse,
          reason: '清除 = 写回里不再有该键（不是写空串 / null）');
    });

    test('template.save 头像类型错 ⇒ -32602 且配置不变', () async {
      final before = File(harness.configPath).readAsStringSync();
      for (final illegal in <Object>[123, <String, dynamic>{'x': 1}, <Object>[1, 2]]) {
        final response = await harness.ws.request('template.save',
            saveTemplate(name: 'general', originalName: 'general', avatarPath: illegal));
        _obs('非法 avatarPath ${illegal.runtimeType} 的错误', response['error']);
        final error = response['error'] as Map;
        expect(error['code'], -32602);
        expect('${error['message']}', contains('avatarPath'));
        expect(File(harness.configPath).readAsStringSync(), before,
            reason: '类型错不得写盘');
      }
    });

    test('template.save 头像路径越界 / 不存在 / 是目录 ⇒ -32602 且既有头像不变', () async {
      // 先给 general 一个合法头像（后续非法请求不许把它清掉）。
      await harness.ws.request('template.save', saveTemplate(
        name: 'general',
        originalName: 'general',
        avatarPath: pngPath,
      ));
      final before = File(harness.configPath).readAsStringSync();
      final subdir = Directory(p.join(harness.attachmentsDir, 'subdir'))..createSync();
      final cases = <String, String>{
        '越界': p.join(harness.dir.path, 'outside.png'),
        '不存在': p.join(harness.attachmentsDir, 'gone.png'),
        '子目录': subdir.path,
      };
      for (final entry in cases.entries) {
        final response = await harness.ws.request('template.save',
            saveTemplate(name: 'general', originalName: 'general', avatarPath: entry.value));
        _obs('${entry.key}头像路径的错误', response['error']);
        final error = response['error'] as Map;
        expect(error['code'], -32602, reason: '${entry.key}必须被拒');
        expect('${error['message']}', contains('头像'), reason: '错误文本必须点名头像字段');
        expect('${error['message']}', contains(entry.value),
            reason: '错误文本必须点名出问题的路径');
        expect(File(harness.configPath).readAsStringSync(), before,
            reason: '${entry.key}被拒时不得改动配置（既有头像保持原值）');
      }
      // 目录边界用 isWithin 语义：`<dir>attacker` 这类前缀相同的兄弟目录不许误容。
      final sibling = p.join(harness.dir.path, 'attachments-x');
      final response = await harness.ws.request('template.save',
          saveTemplate(name: 'general', originalName: 'general', avatarPath: sibling));
      expect((response['error'] as Map)['code'], -32602,
          reason: '字符串前缀相同不算在目录内（isWithin 语义）');
    });

    test('profile.save 写 profile.avatar_path，config.get 返回路径与 identitySeed；空串清除', () async {
      final saved = await harness.ws.request('profile.save', {'avatarPath': pngPath});
      _obs('profile.save 响应', saved['error'] ?? saved['result']);
      expect(saved['error'], isNull);
      final afterSave = diskConfig().profile;
      _obs('落盘的 profile', afterSave?.toJson());
      expect(afterSave, isNotNull);
      expect(afterSave!.avatarPath, p.normalize(p.absolute(pngPath)));

      final got = await harness.ws.request('config.get');
      final profile = (got['result'] as Map)['profile'] as Map;
      _obs('config.get 的 profile', profile);
      expect(profile['avatarPath'], p.normalize(p.absolute(pngPath)));
      expect(profile['userId'], isNull);
      expect(profile['identitySeed'], 'local-user',
          reason: '没有 user_id 时实际生效种子必须回落到常量缺省值');

      // 用户显式写了 user_id 时 identitySeed 跟着变（系统不自动生成 userId）。
      final direct = diskConfig().copyWith(
        profile: UserProfile(avatarPath: afterSave.avatarPath, userId: 'alice'),
      );
      ConfigService.save(direct, configPath: harness.configPath);
      final gotWithUser = await harness.ws.request('config.get');
      final profileWithUser = (gotWithUser['result'] as Map)['profile'] as Map;
      _obs('带 user_id 的 config.get profile', profileWithUser);
      expect(profileWithUser['identitySeed'], 'alice');

      // 空串清除：写回里不再有 profile.avatar_path（user_id 仍在）。
      final cleared = await harness.ws.request('profile.save', {'avatarPath': ''});
      _obs('清除用户头像的响应', cleared['error'] ?? cleared['result']);
      expect(cleared['error'], isNull);
      final afterClear = diskConfig().profile;
      _obs('清除后的 profile', afterClear?.toJson());
      expect(afterClear, isNotNull);
      expect(afterClear!.avatarPath, isNull);
      expect(afterClear.userId, 'alice', reason: '清除头像不许顺手清掉 user_id');
      final raw = jsonDecode(File(harness.configPath).readAsStringSync()) as Map<String, dynamic>;
      final rawProfile = (raw['profile'] as Map).cast<String, dynamic>();
      expect(rawProfile.containsKey('avatar_path'), isFalse);
    });

    test('profile.save 的 avatarPath 必填：省略 / null / 数字 / 对象 ⇒ -32602', () async {
      final before = File(harness.configPath).readAsStringSync();
      final requests = <String, Future<Map<String, dynamic>>>{
        '省略': harness.ws.request('profile.save'),
        'null': harness.ws.request('profile.save', {'avatarPath': null}),
        '数字': harness.ws.request('profile.save', {'avatarPath': 7}),
        '对象': harness.ws.request('profile.save', {
          'avatarPath': {'path': pngPath},
        }),
      };
      for (final entry in requests.entries) {
        final response = await entry.value;
        _obs('${entry.key} avatarPath 的错误', response['error']);
        final error = response['error'] as Map;
        expect(error['code'], -32602, reason: '${entry.key}必须被拒（它是一次写操作）');
        expect('${error['message']}', contains('avatarPath'));
        expect(File(harness.configPath).readAsStringSync(), before,
            reason: '${entry.key}被拒时不得写盘');
      }
    });

    test('profile.save 路径校验：越界 / 不存在 / 是目录 ⇒ -32602', () async {
      final subdir = Directory(p.join(harness.attachmentsDir, 'sub'))..createSync();
      for (final path in [
        p.join(harness.dir.path, 'nope.png'),
        p.join(harness.attachmentsDir, 'missing.png'),
        subdir.path,
      ]) {
        final response = await harness.ws.request('profile.save', {'avatarPath': path});
        _obs('非法用户头像路径的错误', response['error']);
        final error = response['error'] as Map;
        expect(error['code'], -32602);
        expect('${error['message']}', contains('头像'));
        expect('${error['message']}', contains(path));
      }
    });

    test('已有 profile 时只提交 providers 的 config.save 不抹用户头像', () async {
      await harness.ws.request('profile.save', {'avatarPath': pngPath});
      final saved = await harness.ws.request('config.save', {
        'providers': {
          'p': {'base_url': 'http://127.0.0.1:1'},
          'q': {'base_url': 'http://127.0.0.1:2'},
        },
      });
      _obs('config.save 的响应错误', saved['error']);
      expect(saved['error'], isNull);
      final profile = diskConfig().profile;
      _obs('只提交 provider 后落盘的 profile', profile?.toJson());
      expect(profile?.avatarPath, p.normalize(p.absolute(pngPath)),
          reason: 'Profile 页保存只提交 providers，MUST NOT 抹掉 profile');
    });

    test('读盘不变量：先把 provider 直接写进磁盘，再 profile.save，写盘后该 provider 仍在', () async {
      // 模拟"别人刚写进磁盘"的新 provider —— 核心内存里没有它。
      final latest = diskConfig();
      ConfigService.save(
        latest.copyWith(providers: {
          ...latest.providers,
          'newly': const ProviderConfig(
              apiKey: 'key-new', baseUrl: 'http://127.0.0.1:9'),
        }),
        configPath: harness.configPath,
      );
      final response = await harness.ws.request('profile.save', {'avatarPath': pngPath});
      expect(response['error'], isNull);
      final after = diskConfig();
      _obs('profile.save 后盘上的 provider', after.providers.keys.toList());
      expect(after.providers.containsKey('newly'), isTrue,
          reason: 'profile.save 必须先读盘再 copyWith，不能拿内存旧快照整份覆盖');
      expect(after.profile?.avatarPath, p.normalize(p.absolute(pngPath)));
    });

    test('profile.save 进 kCoreRpcMethodNames 且注册表与常量一致', () async {
      _obs('kCoreRpcMethodNames 是否含 profile.save', kCoreRpcMethodNames.contains('profile.save'));
      expect(kCoreRpcMethodNames, contains('profile.save'));
      expect(harness.core.rpcMethods, kCoreRpcMethodNames,
          reason: '注册表必须与常量完全一致（漏注册会在 start 抛 StateError）');
    });
  });
}
