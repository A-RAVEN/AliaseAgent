@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/model_discovery_service.dart';
import 'package:alias_agent/ui/agent_template_editor.dart';
import 'live_observability.dart';

/// 真机验证（change `add-provider-model-discovery` 任务 7.1）：真连本机 magpie 网关
/// `http://127.0.0.1:3425`，用真实目录驱动模板编辑器的回填。
///
/// 断言前打印实际目录条目与回填值。跳过条款是收紧的：**只有连接被拒、且
/// `magpie-windows-amd64.exe` 不在进程表里**才允许跳过，并打印 `SKIPPED: 网关未运行`；
/// 进程在跑但端口不通、HTTP 非 200、解析失败、任何断言不符都必须红。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(clearLiveVisualDir);

  testWidgets('真连 magpie：目录落库 + 模板回填不含 video', (tester) async {
    // live 用例要发真实回环 HTTP；TestWidgets 绑定默认把 HttpClient 换成 400 假响应。
    HttpOverrides.global = null;

    if (!await _gatewayPortOpen()) {
      final running = await _magpieProcessRunning();
      // ignore: avoid_print
      print('  [OBS] 网关端口可达=false；magpie 进程在跑=$running');
      if (!running) {
        // ignore: avoid_print
        print('SKIPPED: 网关未运行');
        markTestSkipped('SKIPPED: 网关未运行');
        return;
      }
      fail('magpie 进程在运行，但 http://127.0.0.1:3425 连接被拒：'
          '这是真障碍，不能按"网关未运行"跳过。');
    }

    final tempDir = Directory.systemTemp.createTempSync('provider_discovery_live_');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 句柄偶尔没放掉；临时目录交给系统清理。
      }
    });
    final configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    final logsDir = '${tempDir.path}${Platform.pathSeparator}logs';

    final config = AppConfig.fromJson({
      'version': 1,
      'providers': {
        'magpie': {
          'api_key': 'magpie-live-key',
          'base_url': 'http://127.0.0.1:3425/v1',
        },
      },
      'agent_types': {
        'general': {
          'provider': 'magpie',
          'model': 'deepseek/deepseek-flash',
          'system_prompt': '你是助手',
          'tools': ['read_file'],
          'max_context_tokens': 1048576,
        },
      },
    });
    ConfigService.save(config, configPath: configPath);
    final loaded = ConfigService.load(configPath: configPath).config!;
    final service = ModelDiscoveryService(
      configPath: configPath,
      probe: HttpModelCatalogProbe(logsDir: logsDir),
    );

    final captureKey = GlobalKey();
    try {
      final result =
          (await tester.runAsync(() => service.discover(loaded, 'magpie')))!;
      // ignore: avoid_print
      print('  [OBS] 探测结果 success=${result.success} '
          'summary=${result.summary} 条目数=${result.entries.length}');
      for (final e in result.entries) {
        // ignore: avoid_print
        print('  [OBS] 目录条目 id=${e.id} display=${e.displayName} '
            'window=${e.contextWindow} input=${e.inputModalities} '
            'efforts=${e.reasoningEfforts} native=${e.nativeEndpoints} '
            'pricing=${e.pricing}');
      }
      expect(result.success, isTrue,
          reason: '真连网关探测失败：${result.error}（HTTP 非 200 / 连接失败必须红）');
      expect(result.entries, isNotEmpty);

      final flash = result.entries.where((e) => e.id == 'deepseek/deepseek-flash');
      expect(flash, hasLength(1), reason: '实测目录必须含 deepseek/deepseek-flash');
      // ignore: avoid_print
      print('  [OBS] deepseek/deepseek-flash: window=${flash.first.contextWindow} '
          'input=${flash.first.inputModalities}');
      expect(flash.first.contextWindow, 1048576);
      expect(flash.first.inputModalities, contains('image'));

      final kimi =
          result.entries.where((e) => e.id == 'kimi/kimi-for-coding');
      expect(kimi, hasLength(1), reason: '实测目录必须含 kimi/kimi-for-coding');
      // ignore: avoid_print
      print('  [OBS] kimi/kimi-for-coding: window=${kimi.first.contextWindow} '
          'input=${kimi.first.inputModalities}');
      expect(kimi.first.inputModalities, contains('video'));

      // 用真实目录驱动模板编辑器：选 kimi，回填值不得含 video。
      AgentTemplateDraft? saved;
      await tester.pumpWidget(RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          home: Scaffold(
            body: AgentTemplateEditor(
              providers: const ['magpie'],
              catalogs: {'magpie': result.entries},
              availableTools: const ['read_file'],
              onSave: (draft) async => saved = draft,
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.ensureVisible(
          find.byKey(const ValueKey('template-model-picker')));
      await tester.tap(find.byKey(const ValueKey('template-model-picker')));
      await tester.pumpAndSettle();
      final kimiDisplay = kimi.first.displayName ?? kimi.first.id;
      await tester.tap(find.text(kimiDisplay).last);
      await tester.pumpAndSettle();

      final window = tester
          .widget<TextField>(find.byKey(const ValueKey('template-window')))
          .controller!
          .text;
      final textSelected = tester
          .widget<FilterChip>(find.byKey(const ValueKey('modality-chip-text')))
          .selected;
      final imageSelected = tester
          .widget<FilterChip>(find.byKey(const ValueKey('modality-chip-image')))
          .selected;
      final videoChip =
          find.byKey(const ValueKey('modality-chip-video')).evaluate().length;
      final omitted = tester
          .widget<Text>(find.byKey(const ValueKey('template-omitted-modalities')))
          .data;
      // ignore: avoid_print
      print('  [OBS] 模板回填（kimi）：window="$window" '
          'text=$textSelected image=$imageSelected videoChip=$videoChip '
          '略去说明=$omitted');
      expect(window, '1048576');
      expect(textSelected, isTrue);
      expect(imageSelected, isTrue);
      expect(videoChip, 0, reason: '模板输入模态只能 text/image，video 不得出现');
      expect(omitted, contains('video'));

      await tester.enterText(
          find.byKey(const ValueKey('template-name')), 'live-template');
      await tester.ensureVisible(find.byKey(const ValueKey('save-template')));
      await tester.tap(find.byKey(const ValueKey('save-template')));
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('  [OBS] 保存草稿：model=${saved?.model} '
          'modalities=${saved?.inputModalities} window=${saved?.maxContextTokensText}');
      expect(saved, isNotNull);
      expect(saved!.inputModalities, isNot(contains('video')));
      expect(saved!.inputModalities, containsAll(<String>['text', 'image']));
    } finally {
      await captureLiveShot(tester, captureKey, 'provider_discovery');
    }
  });
}

Future<bool> _gatewayPortOpen() async {
  try {
    final socket = await Socket.connect('127.0.0.1', 3425,
        timeout: const Duration(seconds: 2));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _magpieProcessRunning() async {
  try {
    final result = await Process.run(
      'tasklist',
      ['/FI', 'IMAGENAME eq magpie-windows-amd64.exe', '/NH'],
    );
    final out = '${result.stdout}'.toLowerCase();
    return out.contains('magpie-windows-amd64');
  } catch (_) {
    return false;
  }
}
