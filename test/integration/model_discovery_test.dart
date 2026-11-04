import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/model_discovery_service.dart';
import 'package:alias_agent/ui/providers_page.dart';

/// 模型探测的端到端行为（change `add-provider-model-discovery` 任务 3.3）。
///
/// 用本机回环的假 magpie（`dart:io HttpServer`，随机端口）驱动真实的
/// `HttpModelCatalogProbe` + `ModelDiscoveryService`：探测协议头、成功落库与四类计数、
/// 401 不泄露密钥、非标准响应的旧目录保留与"截断可见可恢复"、解析丢弃与移除分账，
/// 以及写回时其它配置段不变。
void main() {
  late Directory tempDir;
  late String configPath;
  late String logsDir;

  setUp(() {
    // 本文件既有真回环 HTTP 用例、又有界面接线用例。TestWidgetsFlutterBinding 默认把
    // 所有 HttpClient 请求换成 400 假响应（实测 warning 原文："all HTTP requests will
    // return status code 400"），会让真 HTTP 用例全部误报；这里恢复真实 HttpClient。
    HttpOverrides.global = null;
    tempDir = Directory.systemTemp.createTempSync('model_discovery_test_');
    configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    logsDir = '${tempDir.path}${Platform.pathSeparator}logs';
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶尔还有句柄没放掉；临时目录由系统清理，不掩盖测试结论。
    }
  });

  test('成功探测：协议头正确（带 /v1 的地址不拼成 /v1/v1）、四类计数与写回正确', () async {
    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    server.body = jsonEncode({
      'data': [
        _entryJson('deepseek/deepseek-flash', contextWindow: 1048576),
        _entryJson('kimi/kimi-for-coding',
            contextWindow: 1048576,
            input: ['text', 'image', 'video'],
            efforts: ['none', 'low', 'high', 'max']),
      ],
    });

    final config =
        _baseConfig(port: server.port, withCatalog: true);
    ConfigService.save(config, configPath: configPath);

    final report = await _service(configPath, logsDir).discover(
        ConfigService.load(configPath: configPath).config!, 'magpie');

    // ignore: avoid_print
    print('  [OBS] 请求次数=${server.requests} 路径=${server.lastPath} '
        'x-api-key=${server.lastHeaders?['x-api-key']} '
        'anthropic-version=${server.lastHeaders?['anthropic-version']}');
    // ignore: avoid_print
    print('  [OBS] 探测结果 ok=${report.success} summary=${report.summary} '
        '目录=${report.entries.map((e) => e.id).toList()} '
        'discoveredAt=${report.discoveredAt}');

    expect(server.requests, 1);
    expect(server.lastPath, '/v1/models',
        reason: '地址尾部 /v1 必须先剥掉，否则会拼成 /v1/v1/models');
    expect(server.lastHeaders?['x-api-key'], 'sk-secret-key');
    expect(server.lastHeaders?['anthropic-version'], '2023-06-01');

    expect(report.success, isTrue);
    expect(report.added, 1, reason: 'kimi 是新增');
    expect(report.updated, 1, reason: 'deepseek 窗口从 1000 变 1048576');
    expect(report.removed, 1, reason: 'gone/model 本次不再出现');
    expect(report.dropped, 0);

    final saved = ConfigService.load(configPath: configPath).config!;
    final magpie = saved.providers['magpie']!;
    // ignore: avoid_print
    print('  [OBS] 写回：models=${magpie.models.map((m) => m.id).toList()} '
        'discoveredAt=${magpie.discoveredAt}');
    expect(magpie.models.map((m) => m.id).toList(),
        ['deepseek/deepseek-flash', 'kimi/kimi-for-coding']);
    expect(magpie.models.first.contextWindow, 1048576);
    expect(magpie.models.last.inputModalities, ['text', 'image', 'video'],
        reason: '目录照录 video，过滤只发生在回填模板时');
    expect(magpie.discoveredAt, report.discoveredAt);
    expect(report.discoveredAt, '2026-11-04T02:00:00.000Z');
  });

  test('401：错误只带状态码，密钥不进入错误消息，失败不写盘', () async {
    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    server.status = 401;
    server.body = 'invalid key: sk-secret-key';

    final config =
        _baseConfig(port: server.port, withCatalog: true);
    ConfigService.save(config, configPath: configPath);
    final before = File(configPath).readAsStringSync();

    final report = await _service(configPath, logsDir)
        .discover(ConfigService.load(configPath: configPath).config!, 'magpie');

    // ignore: avoid_print
    print('  [OBS] 401 结果：success=${report.success} error=${report.error}');

    expect(report.success, isFalse);
    expect(report.error, contains('HTTP 401'));
    expect(report.error, isNot(contains('sk-secret-key')),
        reason: '密钥不得出现在错误展示里');
    expect(report.entries.map((e) => e.id).toList(),
        ['deepseek/deepseek-flash', 'gone/model'],
        reason: '失败时旧目录原样返回');
    expect(File(configPath).readAsStringSync(), before,
        reason: '失败不写盘，旧目录与其它配置原样保留');
  });

  test('非标准响应：旧目录保留、总字符数与略去数可见、完整原文逐字节落盘、预览长度取自 spill.preview_chars',
      () async {
    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    final raw = 'this is not a magpie catalog ${'x' * 500}';
    server.body = raw;

    final config =
        _baseConfig(port: server.port, withCatalog: true, previewChars: 40);
    ConfigService.save(config, configPath: configPath);
    final before = File(configPath).readAsStringSync();

    final report = await _service(configPath, logsDir)
        .discover(ConfigService.load(configPath: configPath).config!, 'magpie');

    // ignore: avoid_print
    print('  [OBS] 非标准响应：success=${report.success} error=${report.error}');
    // ignore: avoid_print
    print('  [OBS] totalChars=${report.totalChars} omittedChars=${report.omittedChars} '
        '预览长度=${report.preview?.length} 文件=${report.errorFilePath}');

    expect(report.success, isFalse);
    expect(report.entries.map((e) => e.id).toList(),
        ['deepseek/deepseek-flash', 'gone/model']);
    expect(report.totalChars, raw.length);
    expect(report.omittedChars, raw.length - 40);
    expect(report.error, contains('已略去 ${raw.length - 40} 字符'));
    expect(report.error, contains(report.errorFilePath!));
    expect(report.preview, hasLength(40),
        reason: '预览长度取自 spill.preview_chars=40');
    expect(report.preview, contains('…'));
    expect(File(configPath).readAsStringSync(), before,
        reason: '非标准响应整体作废，旧目录不变');

    expect(report.errorFilePath, isNotNull);
    final file = File(report.errorFilePath!);
    // ignore: avoid_print
    print('  [OBS] 落盘文件存在=${file.existsSync()} '
        '字节=${file.existsSync() ? file.lengthSync() : -1} 原始字节=${utf8.encode(raw).length}');
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), utf8.encode(raw),
        reason: '完整响应必须与网关返回逐字节相同，才能按路径取回全文');
    expect(file.path, contains('model_discovery_error_'));
  });

  test('顶层是数组同样判非标准目录', () async {
    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    server.body = '[{"id":"x"}]';

    final config = _baseConfig(port: server.port);
    ConfigService.save(config, configPath: configPath);
    final report = await _service(configPath, logsDir)
        .discover(ConfigService.load(configPath: configPath).config!, 'magpie');

    // ignore: avoid_print
    print('  [OBS] 顶层数组：success=${report.success} '
        'error=${report.error} total=${report.totalChars}');
    expect(report.success, isFalse);
    expect(report.error, contains('不是 magpie 标准目录'));
    expect(report.totalChars, server.body.length);
  });

  test('响应缺某模型：移除计数为 1，已保存模板不被回改', () async {
    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    server.body = jsonEncode({
      'data': [_entryJson('deepseek/deepseek-flash', contextWindow: 1048576)],
    });

    final config =
        _baseConfig(port: server.port, withCatalog: true);
    ConfigService.save(config, configPath: configPath);
    final report = await _service(configPath, logsDir)
        .discover(ConfigService.load(configPath: configPath).config!, 'magpie');
    final saved = ConfigService.load(configPath: configPath).config!;

    // ignore: avoid_print
    print('  [OBS] 缺模型：added=${report.added} updated=${report.updated} '
        'removed=${report.removed} dropped=${report.dropped} '
        '目录=${saved.providers['magpie']!.models.map((m) => m.id).toList()} '
        'general.model=${saved.agentTypes['general']!.model}');
    expect(report.removed, 1);
    expect(saved.providers['magpie']!.models.map((m) => m.id).toList(),
        ['deepseek/deepseek-flash']);
    expect(saved.agentTypes['general']!.model, 'claude-sonnet-4-6',
        reason: '目录刷新不回改已保存模板的字段');
  });

  test('响应含缺 id 的条目：丢弃 1，不计入移除', () async {
    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    server.body = jsonEncode({
      'data': [
        _entryJson('deepseek/deepseek-flash', contextWindow: 1048576),
        {'display_name': '没有 id 的坏条目', 'context_window': 123},
      ],
    });

    final config = _baseConfig(port: server.port);
    ConfigService.save(config, configPath: configPath);
    final report = await _service(configPath, logsDir)
        .discover(ConfigService.load(configPath: configPath).config!, 'magpie');

    // ignore: avoid_print
    print('  [OBS] 坏条目：dropped=${report.dropped} removed=${report.removed} '
        'added=${report.added} updated=${report.updated}');
    expect(report.dropped, 1);
    expect(report.removed, 0,
        reason: '解析丢弃不得计入移除：那是解析失败，不是网关下架');
    expect(report.added, 1);
  });

  test('写回只动被探测的 Provider：version / 其它 Provider / agent_types / search / spill 原样',
      () async {    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    server.body = jsonEncode({
      'data': [_entryJson('deepseek/deepseek-flash', contextWindow: 1048576)],
    });

    final config = _baseConfig(port: server.port);
    ConfigService.save(config, configPath: configPath);
    final beforeJson =
        jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;

    await _service(configPath, logsDir)
        .discover(ConfigService.load(configPath: configPath).config!, 'magpie');

    final afterJson =
        jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
    // ignore: avoid_print
    print('  [OBS] 写回前后：version=${afterJson['version']} '
        'providers=${(afterJson['providers'] as Map).keys.toList()} '
        'anthropic=${jsonEncode((afterJson['providers'] as Map)['anthropic'])} '
        'agent_types 字节相同=${jsonEncode(beforeJson['agent_types']) == jsonEncode(afterJson['agent_types'])} '
        'search 字节相同=${jsonEncode(beforeJson['search']) == jsonEncode(afterJson['search'])} '
        'spill 字节相同=${jsonEncode(beforeJson['spill']) == jsonEncode(afterJson['spill'])}');

    expect(afterJson['version'], beforeJson['version']);
    expect(
        jsonEncode((afterJson['providers'] as Map)['anthropic']),
        jsonEncode((beforeJson['providers'] as Map)['anthropic']),
        reason: '其它 Provider 段必须逐字节不变（连新增的目录键都不该出现）');
    for (final section in const ['agent_types', 'search', 'spill']) {
      expect(jsonEncode(afterJson[section]), jsonEncode(beforeJson[section]),
          reason: '$section 段必须逐字节不变');
    }
  });

  // ── 两条服务层守卫（任务 3.3）：启动零探测 / 保存后自动探测恰一次 ──────────

  test('启动路径不探测：ConfigService.load 与构造探测服务都不发请求；一次探测恰发一次',
      () async {
    final server = await _FakeMagpieServer.start();
    addTearDown(() async => server.close());
    server.body = jsonEncode({'data': []});
    ConfigService.save(_baseConfig(port: server.port), configPath: configPath);

    final loaded = ConfigService.load(configPath: configPath).config!;
    final service = _service(configPath, logsDir);
    // ignore: avoid_print
    print('  [OBS] load + 构造服务后请求计数=${server.requests} '
        '（旧目录条数=${loaded.providers['magpie']!.models.length}）');
    expect(server.requests, 0, reason: '启动/初始化路径上不允许有任何探测请求');

    await service.discover(loaded, 'magpie');
    // ignore: avoid_print
    print('  [OBS] 手动探测一次后请求计数=${server.requests}');
    expect(server.requests, 1, reason: '一次探测动作只发一个请求');
  });

  testWidgets('界面初始化不探测；保存 Provider 后自动探测恰一次', (tester) async {
    final counting = _CountingDiscovery();
    ConfigService.save(_baseConfig(port: 3425), configPath: configPath);
    final loaded = ConfigService.load(configPath: configPath).config!;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProvidersPage(
          config: loaded,
          discovery: counting,
          configPath: configPath,
        ),
      ),
    ));
    await tester.pump();
    // ignore: avoid_print
    print('  [OBS] Provider 页初始化后探测计数=${counting.calls}');
    expect(counting.calls, 0, reason: '界面初始化（启动路径）不得自动探测');

    await tester.tap(find.byKey(const ValueKey('add-provider')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('provider-name')), 'second');
    await tester.enterText(
        find.byKey(const ValueKey('provider-base-url')), 'https://second.example');
    await tester.enterText(find.byKey(const ValueKey('provider-api-key')), 'sk-second');
    await tester.tap(find.byKey(const ValueKey('provider-form-save')));
    await tester.pumpAndSettle();

    // ignore: avoid_print
    print('  [OBS] 保存 Provider 后探测计数=${counting.calls} '
        '探测对象=${counting.probed}');
    expect(counting.calls, 1, reason: '保存 Provider 成功后自动探测恰一次');
    expect(counting.probed, ['second']);
  });
}

ModelDiscoveryService _service(String configPath, String logsDir) =>
    ModelDiscoveryService(
      configPath: configPath,
      clock: () => DateTime.utc(2026, 11, 4, 2, 0, 0),
      probe: HttpModelCatalogProbe(
        logsDir: logsDir,
        clock: () => DateTime.utc(2026, 11, 4, 2, 0, 0),
      ),
    );

/// 假配置：一个 magpie Provider（地址带 `/v1`）+ 一个不对外请求的其它 Provider。
AppConfig _baseConfig({
  required int port,
  bool withCatalog = false,
  int previewChars = 1000,
}) {
  final oldCatalog = withCatalog
      ? const [
          ModelCatalogEntry(
            id: 'deepseek/deepseek-flash',
            displayName: 'DeepSeek-V4.1-Flash',
            contextWindow: 1000,
            inputModalities: ['text'],
          ),
          ModelCatalogEntry(
            id: 'gone/model',
            displayName: '将被下架',
            contextWindow: 2000,
          ),
        ]
      : const <ModelCatalogEntry>[];
  return AppConfig.fromJson({
    'version': 3,
    'providers': {
      'magpie': {
        'api_key': 'sk-secret-key',
        'base_url': 'http://127.0.0.1:$port/v1',
        if (withCatalog) 'models': [for (final m in oldCatalog) m.toJson()],
      },
      'anthropic': {
        'api_key': 'sk-anthropic',
        'base_url': 'https://api.anthropic.com',
      },
    },
    'agent_types': {
      'general': {
        'provider': 'magpie',
        'model': 'claude-sonnet-4-6',
        'system_prompt': 'You are helpful.',
        'tools': ['read_file'],
        'max_context_tokens': 200000,
        'input_modalities': ['text'],
      },
    },
    'search': {
      'deepseek': {'enabled': true, 'k': 4},
    },
    'spill': {'preview_chars': previewChars},
  });
}

Map<String, dynamic> _entryJson(
  String id, {
  int? contextWindow,
  List<String> input = const ['text'],
  List<String>? efforts,
}) {
  final json = <String, dynamic>{
    'id': id,
    'display_name': id,
    'modalities': {'input': input, 'output': ['text']},
  };
  if (contextWindow != null) json['context_window'] = contextWindow;
  if (efforts != null) {
    json['supported_reasoning_levels'] = [
      for (final e in efforts) {'effort': e},
    ];
  }
  return json;
}

/// 只计数的假探测服务：验"界面初始化 0 次 / 保存后恰 1 次"的接线，不碰网络。
class _CountingDiscovery implements ProviderCatalogDiscovery {
  int calls = 0;
  final List<String> probed = [];

  @override
  Future<ModelDiscoveryReport> discover(
      AppConfig config, String providerName) async {
    calls++;
    probed.add(providerName);
    return ModelDiscoveryReport(
      success: true,
      providerName: providerName,
      entries: config.providers[providerName]?.models ?? const [],
      added: 0,
      updated: 0,
      removed: 0,
      dropped: 0,
      discoveredAt: '2026-11-04T02:00:00.000Z',
      config: config,
    );
  }
}

class _FakeMagpieServer {
  final HttpServer _server;
  int requests = 0;
  int status = 200;
  String body = '{"data":[]}';
  String? lastPath;
  Map<String, String>? lastHeaders;

  _FakeMagpieServer._(this._server) {
    _server.listen((request) async {
      requests++;
      lastPath = request.uri.path;
      lastHeaders = {
        for (final name in ['x-api-key', 'anthropic-version'])
          name: request.headers.value(name) ?? '',
      };
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
  }

  static Future<_FakeMagpieServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeMagpieServer._(server);
  }

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}
