// 无头核心 + web 验证页的**真实模型**端到端测试（change `web-ui-core-shim` 任务 4.2）。
//
// 本文件只提供 `runWebCoreShimLiveSuite()`，由两个入口调用：
//   - `integration_test/web_core_shim_live_test.dart`（规范的 live 位置，设备态）；
//   - `test/live/web_core_shim_live_test.dart`（本机无窗口跑法：`flutter test` 把
//     `integration_test/` 下一律当设备测试、要求连设备并起窗口；任务 4.2 明确要求
//     无头通道，所以镜像入口放在 `test/` 下跑同一个 suite）。
//
// 被测对象是浏览器里的 web 页面：真 sidecar + 真模型 + 真 core + 无头 Edge
// （puppeteer-core 驱动，页面内截图）。`captureLiveShot` 只截 Flutter 场景、截不到
// 浏览器页，所以视觉验收走 `test/live_visual/web_core_shim_live.png`。
//
// 前置：`cd web && npm install && npm run build`（dist 由核心 serve）；
//       `%USERPROFILE%\.aliasagent\config.json` 有完整 general provider 配置；
//       仓库根有 `sidecar.dll`（CWD 必须是仓库根）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';

const String _shotName = 'web_core_shim_live';
const String _workspaceMarker = 'ALIASAGENT_WEB_LIVE_OK';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

String get _repoRoot => Directory.current.path;
String get _shotPath =>
    p.join(_repoRoot, 'test', 'live_visual', '$_shotName.png');

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

/// 严格的 live 配置门（与 live_file_tools_test 同口径）：API key / base_url / model
/// 三者都非空才算可用，避免空 base_url 回落到错误默认端点。
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

void runWebCoreShimLiveSuite() {
  final configGate = _gateConfig();

  test(
    '无头核心 + web 验证页：真实模型发一条消息 → 流式回复 → 工具卡片 → 页面截图',
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

      final tempRoot = Directory.systemTemp.createTempSync('web_core_live_');
      final dbDir = Directory(p.join(tempRoot.path, 'db'))..createSync();
      final workspace = Directory(p.join(tempRoot.path, 'workspace'))..createSync();
      File(p.join(workspace.path, 'README.md'))
          .writeAsStringSync('$_workspaceMarker\n这是 live 测试夹具的第二行。\n');
      final shotDir = Directory(p.dirname(_shotPath))..createSync(recursive: true);
      if (File(_shotPath).existsSync()) File(_shotPath).deleteSync();
      _obs('截图目标', _shotPath);
      _obs('工作区夹具', workspace.path);

      HeadlessCore? core;
      WebSocket? observer;
      final events = <Map<String, dynamic>>[];
      try {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        core = await HeadlessCoreRunner.start(
          configOverride: config,
          lockPath: p.join(tempRoot.path, 'core.lock'),
          openDatabaseOverride: () => DatabaseService.openAt(dbDir.path),
          webRoot: p.join(_repoRoot, 'web', 'dist'),
        );
        _obs('无头核心 URL', core.url);
        _obs('无头核心 WS', core.websocketUrl);
        _obs('RPC 方法', core.rpcMethods);

        final session = await core.sessionRepo.create(title: 'web live');
        _obs('会话 id', session.id);
        // 先 ensure 实例并把上下文工作区指向夹具目录（页面 send 会复用该实例）。
        await core.factory.ensure(session);
        final workspaceError =
            core.sidecar.setWorkspace(session.id, workspace.path);
        _obs('setWorkspace 结果', workspaceError);
        expect(workspaceError, isNull,
            reason: '不允许模型去碰用户 homeDir');

        observer = await WebSocket.connect(core.websocketUrl.toString());
        observer.listen((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          if (decoded['method'] == 'agent.event') {
            events.add(Map<String, dynamic>.from(decoded['params'] as Map));
          }
        });

        const prompt = '请务必先调用 read_file 工具读取当前工作区里的 README.md，'
            '然后把文件第一行的原文完整照抄到回答里（不要改写）。';
        final node = await Process.run(
          'node',
          ['e2e/smoke.mjs', core.url.toString(), _shotPath, prompt],
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
        final report = jsonDecode(lastLine) as Map<String, dynamic>;
        _obs('页面状态', report);
        _obs('WS 实际事件序列', [for (final event in events) event['type']]);
        final toolCalls = events.where((e) => e['type'] == 'tool.call').toList();
        final toolResults =
            events.where((e) => e['type'] == 'tool.result').toList();
        for (final event in [...toolCalls, ...toolResults]) {
          final data = event['data'] as Map;
          _obs('工具事件 ${event['type']}', {
            'toolName': data['toolName'],
            'input': data['input'],
            'status': data['status'],
            'resultPreview': data['resultPreview'],
            'result': data['result'],
          });
        }

        // --- 断言前现场已全部打印（TESTING.md §3.1） ---
        expect(report['error'], isNull, reason: '页面显示了错误横幅');
        expect('${report['status']}', contains('已连接'));
        expect(report['sessions'], isNotEmpty);
        expect('${report['userText']}', contains('read_file'));
        expect('${report['assistantText']}', contains(_workspaceMarker),
            reason: '助手回复必须包含夹具第一行原文（证明工具结果进入了回答）');
        expect(report['toolCards'], isNotEmpty,
            reason: '页面必须渲染工具卡片');
        expect('${report['snapshot']}', contains('上下文窗口'));

        // 自然贴底（change web-chat-screen 审查 TC-5）：完整屏自带贴底跟随，驱动
        // **不手动滚底**；这里断言列表自然停在底部——距底距离 ≤ bottomThresholdPx
        // （web/src/tokens.ts layoutConfig.bottomThresholdPx = 24px = 正文行高），
        // 且贴底时跳底按钮隐藏。证明是产品自动跟随，不是驱动滚出来的人造状态。
        final scroll = report['scroll'] as Map?;
        _obs('自然贴底度量', scroll);
        _obs('跳底按钮可见', report['jumpButtonVisible']);
        expect(scroll, isNotNull, reason: '页面须报告滚动度量');
        expect((scroll!['distanceFromBottom'] as num) <= 24, isTrue,
            reason: '完整屏应自动贴底（距底 ≤ 24px token），而非靠驱动手动滚底');
        expect(report['jumpButtonVisible'], false,
            reason: '贴底时跳底按钮应隐藏');

        final eventTypes = [for (final event in events) '${event['type']}'];
        expect(eventTypes, contains('assistant.chunk'), reason: '必须有流式文本事件');
        expect(eventTypes, contains('assistant.message'));
        expect(toolCalls, isNotEmpty, reason: '模型该轮必须调用工具');
        expect(toolResults, isNotEmpty);
        expect((toolResults.last['data'] as Map)['status'], 'done');
        expect((toolCalls.last['data'] as Map)['toolName'], 'read_file');
        expect(
          (toolCalls.last['data'] as Map).keys,
          containsAll(const ['id', 'toolName', 'input', 'status']),
        );

        final shot = File(_shotPath);
        _obs('截图存在 / 字节', '${shot.existsSync()} / '
            '${shot.existsSync() ? shot.lengthSync() : 0}');
        expect(shot.existsSync(), isTrue);
        expect(shot.lengthSync(), greaterThan(2048));
        _obs('截图路径', _shotPath);

        // 供主循环视觉验收：把页面关键文案再打一遍（图 + 文互相印证）。
        _obs('页面助手回复', report['assistantText']);
        _obs('页面工具卡片', report['toolCards']);
        _obs('页面会话列表', report['sessions']);
        _obs('页面快照行', report['snapshot']);
        _obs('页面技能失败提示', report['skillFailures']);
        expect(shotDir.existsSync(), isTrue);
      } finally {
        await observer?.close();
        await core?.stop();
        try {
          DatabaseService.reset();
          tempRoot.deleteSync(recursive: true);
        } catch (e) {
          _obs('清理临时目录失败（不影响断言）', e);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
