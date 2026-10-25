// 「粘贴图片」按钮与待发缩略图条（add-image-input 任务 8.2 / 8.4 / 8.5）。
//
// 这一组用例走真实的 ChatScreen（不是单独 pump InputBar），因为"贴图"这件事
// 由 ChatScreen 持有状态：按钮 → 调 sidecar → 把返回的**路径**加进待发列表 →
// 缩略图出现 → 移除或发送后消失。sidecar 用 FakeSidecar，剪贴板内容由
// `stubReadClipboardImage` 伪造，不碰真实剪贴板。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../integration/helpers/fake_sidecar.dart';

/// 1×1 的合法 PNG（透明像素）。缩略图要真的能解码，所以写一份真文件。
const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

void _setupAgentRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    tools: ['read_file', 'list_dir'],
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

Widget _buildApp({
  required FakeSessionRepository sessionRepo,
  required FakeMessageRepository msgRepo,
  required FakeSidecar sidecar,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ),
    ),
  );
}

/// 造一张真的图片文件，并把它的路径塞进 sidecar 的假返回值里。
String _writePngAndStub(FakeSidecar sidecar, Directory dir, {String name = 'pasted.png'}) {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  file.writeAsBytesSync(base64Decode(_onePixelPngBase64));
  sidecar.stubReadClipboardImage(jsonEncode({
    'ok': true,
    'path': file.path,
    'media_type': 'image/png',
    'width': 1,
    'height': 1,
    'bytes': file.lengthSync(),
  }));
  return file.path;
}

void main() {
  late Directory tempDir;

  setUp(() {
    _setupAgentRegistry();
    tempDir = Directory.systemTemp.createTempSync('paste_test_');
  });

  tearDown(() {
    registry.clear();
    resolver = null;
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('「粘贴图片」按钮', () {
    testWidgets('贴一张图后出现缩略图，点移除后缩略图消失', (tester) async {
      final sidecar = FakeSidecar();
      final msgRepo = FakeMessageRepository();
      _writePngAndStub(sidecar, tempDir);

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository([]),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pumpAndSettle();

      // 贴之前没有缩略图
      expect(find.byTooltip('移除这张图'), findsNothing);
      expect(find.byTooltip('粘贴图片'), findsOneWidget);

      await tester.tap(find.byTooltip('粘贴图片'));
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('  [OBS] sidecar 被调用次数=${sidecar.readClipboardImageCallCount} '
          '入参=${sidecar.lastReadClipboardImageRequest}');
      expect(sidecar.readClipboardImageCallCount, 1);
      expect(find.byTooltip('移除这张图'), findsOneWidget,
          reason: '贴图成功后待发缩略图条必须出现');
      expect(find.byType(Image), findsWidgets);

      // 移除
      await tester.tap(find.byTooltip('移除这张图'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除这张图'), findsNothing,
          reason: '点移除后缩略图必须消失');
    });

    testWidgets('贴图失败时给出可见提示，且不出现缩略图', (tester) async {
      final sidecar = FakeSidecar();
      sidecar.stubReadClipboardImage(
          '{"ok":false,"error":"clipboard has no image"}');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository([]),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('粘贴图片'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('移除这张图'), findsNothing);
      expect(find.textContaining('剪贴板里没有图片'), findsOneWidget,
          reason: '失败必须留下看得见的一句话，不能只写日志');
    });

    // 18.3（2026-10-25）：工具还没就绪时按 Ctrl+V 贴图，**不许静默无反应**。
    // 用 `browserAvailableGate` 把"动态工具还没探完"那段窗口撑住（这个门是既有夹具给
    // fix-silent-truncation 6.3 用的，正好是同一个状态）。
    testWidgets('工具还没就绪时按 Ctrl+V：必须有可见提示，不许静默', (tester) async {
      final sidecar = FakeSidecar();
      final gate = Completer<void>();
      sidecar.browserAvailableGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
        sidecar.browserAvailableGate = null;
      });

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository([]),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      // 只推几帧，不 settle（settle 会一直等那个永远不会完成的门）。
      await tester.pump();
      await tester.pump();

      final ready = tester
          .state<ChatScreenState>(find.byType(ChatScreen))
          .toolsReady;
      // ignore: avoid_print
      print('  [OBS] 门撑住时 toolsReady=$ready；'
          '输入框存在=${find.byType(TextField).evaluate().isNotEmpty}');
      expect(ready, isFalse, reason: '门没放行时工具就必须是未就绪状态');

      // Ctrl+V 是输入框上的快捷键 —— 必须先让输入框拿到焦点，否则按键事件没人接。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.textContaining('工具还在准备'), findsOneWidget,
          reason: '未就绪时按 Ctrl+V 必须留一句看得见的话；静默就是 18.3 要修的缺陷');
    });
  });

  group('Ctrl+V', () {
    /// 按 Ctrl+V（先按下 Ctrl，再按 V，最后都松开）。
    Future<void> pressCtrlV(WidgetTester tester) async {
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    String currentText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    testWidgets('剪贴板里有图：贴图，输入框文字不变', (tester) async {
      final sidecar = FakeSidecar();
      _writePngAndStub(sidecar, tempDir);

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository([]),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pumpAndSettle();

      await pressCtrlV(tester);

      expect(sidecar.readClipboardImageCallCount, 1);
      expect(find.byTooltip('移除这张图'), findsOneWidget,
          reason: 'Ctrl+V 有图时必须贴图');
      expect(currentText(tester), '',
          reason: '贴图这条路不该往输入框里塞文字');
    });

    testWidgets('剪贴板里没有图：退回普通文本粘贴', (tester) async {
      final sidecar = FakeSidecar();
      sidecar.stubReadClipboardImage(
          '{"ok":false,"error":"clipboard has no image"}');

      // 剪贴板文本走平台通道；widget 测试里用 mock 顶掉真实剪贴板
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': '从剪贴板来的字'};
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository([]),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pumpAndSettle();

      await pressCtrlV(tester);

      expect(currentText(tester), '从剪贴板来的字',
          reason: '没贴到图时必须退回普通文本粘贴，Ctrl+V 不能失效');
      expect(find.byTooltip('移除这张图'), findsNothing);
    });
  });

  group('发送后清空', () {
    testWidgets('发出去之后待发缩略图清空，且路径进了这条消息', (tester) async {
      final sidecar = FakeSidecar();
      final msgRepo = FakeMessageRepository();
      final path = _writePngAndStub(sidecar, tempDir);

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository([]),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pumpAndSettle();

      // 贴一张图，不写文字（这条路 8.1 已经允许）
      await tester.tap(find.byTooltip('粘贴图片'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除这张图'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('  [OBS] 发出去的消息 => '
          '${msgRepo.messages.map((m) => '${m.role}:${m.content} 附件=${m.attachments}').join(' | ')}');

      expect(find.byTooltip('移除这张图'), findsNothing,
          reason: '发出去之后待发条必须清空，不然下一句会重复带这张图');

      final userMessages = msgRepo.messages.where((m) => m.role == 'user').toList();
      expect(userMessages, hasLength(1));
      expect(userMessages.single.attachments, [path],
          reason: '路径必须跟着这条消息一起落库');
    });
  });
}
