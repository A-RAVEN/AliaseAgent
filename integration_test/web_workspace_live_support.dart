// 工作路径 + **真实模型**的端到端（change `custom-workspace` 任务 10.1）。
//
// 本文件只提供 `runWebWorkspaceLiveSuite()`，由两个入口调用：
//   - `integration_test/web_workspace_live_test.dart`（规范的 live 位置，设备态）；
//   - `test/live/web_workspace_live_test.dart`（无窗口镜像入口：`flutter test` 把
//     `integration_test/` 下一律当设备测试，要求 `-d` 并起窗口）。
//
// 形态（照 `web_core_shim_live_support.dart`）：
//   临时库 + 临时锁 + 临时 configPath/attachmentsDir + **本机真实配置只读**
//   （`configOverride`）→ 起无头核心 → 经 `session.create {workspace: A}` 建会话 →
//   用 `web/e2e/smoke.mjs` 驱动无头 Edge 发一条真模型消息 → 观察 WS 的
//   `context.snapshot` 事件 → `session.setWorkspace` 切到 B → 再发一轮 → 比较两轮
//   快照的 `system` → 两张截图。
//
// 断言按**规范化路径**比较：sidecar 读回的是 `GetFullPathNameA` 之后把 `\` 换成 `/`
// 的形式，直接拿盘符原串 `contains` 会假红。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/workspace.dart';

const String _shotA = 'web_workspace_live_a';
const String _shotB = 'web_workspace_live_b';
const String _markerA = 'ALIASAGENT_WORKSPACE_A_8f2c';
const String _markerB = 'ALIASAGENT_WORKSPACE_B_4d71';
const String _prompt = '请务必先调用 read_file 工具读取当前工作区里的 README.md，'
    '然后把文件第一行的原文完整照抄到回答里（不要改写）。';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

String get _repoRoot => Directory.current.path;

String _shotPath(String name) =>
    p.join(_repoRoot, 'test', 'live_visual', '$name.png');

/// 路径断言的**规范化口径**：反斜杠 → 正斜杠（不抹大小写、不折叠别的东西）。
String _norm(String value) => value.replaceAll('\\', '/');

String? _findEdge() {
  final candidates = <String>[
    Platform.environment['EDGE_PATH'] ?? '',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
  ];
  for (final candidate in candidates) {
    if (candidate.isNotEmpty && File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// 严格的 live 配置门（与 `web_core_shim_live_test` 同口径）：api_key / base_url /
/// model 三者都非空才算可用，避免空 base_url 回落到错误默认端点。
({AppConfig? config, String? reason}) _gateConfig() {
  final result = ConfigService.load();
  if (result.status != ConfigStatus.ok) {
    return (config: null, reason: '配置文件不可用：${result.status.name}');
  }
  final config = result.config!;
  final general = config.agentTypes['general'];
  if (general == null) return (config: null, reason: '配置里没有 general 模板');
  final provider = config.providers[general.provider];
  if (provider == null) {
    return (config: null, reason: 'provider "${general.provider}" 未定义');
  }
  if (provider.apiKey.isEmpty ||
      provider.baseUrl.isEmpty ||
      general.model.isEmpty) {
    return (
      config: null,
      reason: 'general 的 provider 缺 api_key/base_url/model（不回落默认端点）',
    );
  }
  return (config: config, reason: null);
}

/// 一条最小的 Dart 侧 WS JSON-RPC 客户端：建会话 / 切工作区都经**产品 RPC**。
class _WsRpc {
  _WsRpc._(this._socket) {
    _subscription = _socket.listen((message) {
      final decoded = jsonDecode(message as String) as Map<String, dynamic>;
      final id = decoded['id'];
      if (id is int && !decoded.containsKey('method')) {
        _pending.remove(id)?.complete(decoded);
      }
    });
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;

  static Future<_WsRpc> connect(Uri uri) async {
    final socket = await WebSocket.connect(uri.toString());
    return _WsRpc._(socket);
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
    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}

/// 跑一次无头 Edge 驱动（复用 `web/e2e/smoke.mjs`），返回页面报告。
Future<Map<String, dynamic>> _drive({
  required String edge,
  required Uri url,
  required String screenshot,
  required String prompt,
}) async {
  final node = await Process.run(
    'node',
    ['e2e/smoke.mjs', url.toString(), screenshot, prompt],
    workingDirectory: p.join(_repoRoot, 'web'),
    environment: {'EDGE_PATH': edge},
    includeParentEnvironment: true,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(minutes: 5));
  _obs('node exitCode', node.exitCode);
  _obs('node stdout', node.stdout);
  _obs('node stderr', node.stderr);
  expect(node.exitCode, 0, reason: '无头浏览器驱动失败：${node.stderr}');
  final stdoutText = (node.stdout as String).trim();
  final lastLine = stdoutText.split('\n').last;
  return jsonDecode(lastLine) as Map<String, dynamic>;
}

void runWebWorkspaceLiveSuite() {
  final configGate = _gateConfig();

  test(
    '工作路径 live：session.create{workspace:A} → 真模型读 A → session.setWorkspace(B) → '
    '真模型读 B；两轮快照 system 各含自己的路径与标题；两张截图',
    () async {
      if (configGate.config == null) {
        markTestSkipped('live 跳过：${configGate.reason}');
        return;
      }
      final config = configGate.config!;
      final edge = _findEdge();
      if (edge == null) {
        markTestSkipped('live 跳过：本机没有可用的 Edge（设置 EDGE_PATH）');
        return;
      }
      final webIndex = File(p.join(_repoRoot, 'web', 'dist', 'index.html'));
      if (!webIndex.existsSync()) {
        fail('web 构建产物不存在：${webIndex.path}\n先跑：cd web && npm run build');
      }

      final tempRoot = Directory.systemTemp.createTempSync('web_workspace_live_');
      final dbDir = Directory(p.join(tempRoot.path, 'db'))..createSync();
      // 真实配置**只读**：拷一份到临时目录当核心的 configPath（`config.get` 的
      // `missing` 按文件存在性判断，用不存在的空路径会让 web 端进首启向导、没有输入框）。
      final configCopy = File(p.join(tempRoot.path, 'config.json'));
      final realConfig = File(ConfigService.configPath);
      if (!realConfig.existsSync()) {
        fail('真实配置文件不存在：${realConfig.path}（live 需要它）');
      }
      realConfig.copySync(configCopy.path);
      final workspaceA = Directory(p.join(tempRoot.path, 'workspace-a'))
        ..createSync();
      final workspaceB = Directory(p.join(tempRoot.path, 'workspace-b'))
        ..createSync();
      // 两个目录各放一份带独特标记的 README：模型读到的内容能区分在哪干活。
      File(p.join(workspaceA.path, 'README.md'))
          .writeAsStringSync('$_markerA\n这是工作区 A 的夹具第二行。\n');
      File(p.join(workspaceB.path, 'README.md'))
          .writeAsStringSync('$_markerB\n这是工作区 B 的夹具第二行。\n');
      final shotDir = Directory(p.join(_repoRoot, 'test', 'live_visual'))
        ..createSync(recursive: true);
      for (final name in [_shotA, _shotB]) {
        final file = File(_shotPath(name));
        if (file.existsSync()) file.deleteSync();
      }
      _obs('夹具目录 A', workspaceA.path);
      _obs('夹具目录 B', workspaceB.path);
      _obs('截图 A', _shotPath(_shotA));
      _obs('截图 B', _shotPath(_shotB));

      HeadlessCore? core;
      _WsRpc? rpc;
      WebSocket? observer;
      final events = <Map<String, dynamic>>[];
      try {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        core = await HeadlessCoreRunner.start(
          configOverride: config,
          // 配置用**真实配置的临时副本**（只读来源；核心若写盘只写到副本）/ 附件 / 锁 /
          // 库全部落在临时目录：live 不碰用户真实 db / config / core.lock。
          configPath: configCopy.path,
          attachmentsDir: p.join(tempRoot.path, 'attachments'),
          lockPath: p.join(tempRoot.path, 'core.lock'),
          openDatabaseOverride: () => DatabaseService.openAt(dbDir.path),
          webRoot: p.join(_repoRoot, 'web', 'dist'),
        );
        _obs('无头核心 URL', core.url);
        _obs('无头核心 WS', core.websocketUrl);

        rpc = await _WsRpc.connect(core.websocketUrl);
        // ① 经产品 RPC 建会话并指定工作区 A。
        final created = await rpc.request('session.create', {
          'title': 'workspace live',
          'workspace': workspaceA.path,
        });
        _obs('session.create 回包', created);
        expect(created['error'], isNull,
            reason: 'session.create{workspace} 不该失败：${created['error']}');
        final session = (created['result'] as Map)['session'] as Map;
        final sessionId = session['id'] as String;
        expect(session['workspace'], workspaceA.path);
        _obs('会话 id', sessionId);

        // 独立观察通道：只收 agent.event（不参与请求，避免抢响应）。
        observer = await WebSocket.connect(core.websocketUrl.toString());
        observer.listen((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          if (decoded['method'] == 'agent.event') {
            events.add(Map<String, dynamic>.from(decoded['params'] as Map));
          }
        });

        List<Map<String, dynamic>> snapshotsSince(int index) => [
              for (final event in events.skip(index))
                if (event['type'] == 'context.snapshot' &&
                    event['sessionId'] == sessionId)
                  event,
            ];

        // ② 第一轮：真实模型在 A 里读 README.md。
        final firstStart = events.length;
        final reportA = await _drive(
          edge: edge,
          url: core.url,
          screenshot: _shotPath(_shotA),
          prompt: _prompt,
        );
        _obs('第一轮页面状态', reportA);
        final snapshotsA = snapshotsSince(firstStart);
        _obs('第一轮快照数', snapshotsA.length);
        expect(reportA['error'], isNull, reason: '第一轮页面出现了错误横幅');
        expect('${reportA['assistantText']}', contains(_markerA),
            reason: '第一轮回复必须含 A 目录 README 的第一行（证明模型在 A 里读文件）');
        expect(snapshotsA, isNotEmpty,
            reason: '必须观察到第一轮的 context.snapshot 事件（注入没验到）');
        for (final snapshot in snapshotsA) {
          final data = snapshot['data'] as Map;
          final system = '${data['system']}';
          _obs('第一轮快照 system（片段）', _excerpt(system));
          expect('${data['sessionId']}', sessionId,
              reason: '快照事件的 sessionId 必须是新建会话');
          expect(system, contains(kWorkspacePromptHeading),
              reason: '系统提示词必须含工作区段标题');
          expect(_norm(system), contains(_norm(workspaceA.path)),
              reason: '第一轮 system 必须含 A 的**规范化**路径');
          expect(_norm(system), isNot(contains(_norm(workspaceB.path))),
              reason: '第一轮不该出现 B 的路径');
        }

        // ③ 经产品 RPC 切到 B。
        final switched = await rpc.request('session.setWorkspace', {
          'sessionId': sessionId,
          'workspace': workspaceB.path,
        });
        _obs('session.setWorkspace 回包', switched);
        expect(switched['error'], isNull,
            reason: 'session.setWorkspace 不该失败：${switched['error']}');
        expect(
            ((switched['result'] as Map)['session'] as Map)['workspace'],
            workspaceB.path);

        // ④ 第二轮：真实模型在 B 里读 README.md。
        final secondStart = events.length;
        final reportB = await _drive(
          edge: edge,
          url: core.url,
          screenshot: _shotPath(_shotB),
          prompt: _prompt,
        );
        _obs('第二轮页面状态', reportB);
        final snapshotsB = snapshotsSince(secondStart);
        _obs('第二轮快照数', snapshotsB.length);
        expect(reportB['error'], isNull, reason: '第二轮页面出现了错误横幅');
        expect('${reportB['assistantText']}', contains(_markerB),
            reason: '第二轮回复必须含 B 目录 README 的第一行（证明切换真的生效）');
        expect(snapshotsB, isNotEmpty,
            reason: '必须观察到第二轮的 context.snapshot 事件（切换没验到）');
        for (final snapshot in snapshotsB) {
          final data = snapshot['data'] as Map;
          final system = '${data['system']}';
          _obs('第二轮快照 system（片段）', _excerpt(system));
          expect('${data['sessionId']}', sessionId);
          expect(system, contains(kWorkspacePromptHeading));
          expect(_norm(system), contains(_norm(workspaceB.path)),
              reason: '第二轮 system 必须含 B 的**规范化**路径');
          expect(_norm(system), isNot(contains(_norm(workspaceA.path))),
              reason: '切换后的轮次不得残留 A 的路径');
        }

        // ⑤ 截图（视觉验收由主循环 read_image 判读）。
        for (final name in [_shotA, _shotB]) {
          final path = _shotPath(name);
          final shot = File(path);
          _obs('[SHOT] 截图', '$path 存在=${shot.existsSync()} 字节='
              '${shot.existsSync() ? shot.lengthSync() : 0}');
          expect(shot.existsSync(), isTrue, reason: '缺少截图 $path');
          expect(shot.lengthSync(), greaterThan(2048),
              reason: '截图 $path 太小（可能是空帧）');
        }
        expect(shotDir.existsSync(), isTrue);
      } finally {
        await observer?.close();
        await rpc?.close();
        await core?.stop();
        try {
          DatabaseService.reset();
          tempRoot.deleteSync(recursive: true);
        } catch (error) {
          _obs('清理临时目录失败（不影响断言）', error);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

/// 打一段 system 提示词现场（观察用；不截断关键信息 —— 带前 400 + 后 200 字符）。
String _excerpt(String text) {
  if (text.length <= 600) return text;
  return '${text.substring(0, 400)} …（中略 ${text.length - 600} 字符）… '
      '${text.substring(text.length - 200)}';
}
