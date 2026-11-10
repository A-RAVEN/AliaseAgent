// 斜杠命令的**对话视图零痕迹**用例（change `add-slash-commands` 任务 3.1）。
//
// 钉一件事：输入框键入 `/edge-skill 正文` 并发送后，聊天气泡里显示的 user 文本
// **逐字是手打原文** —— 展开只发生在模型装配面（`_buildApiMessages`），对对话视图
// 不可见（spec「命中展开，对话视图零痕迹」）。
//
// 这里走真实 widget 现场（ChatScreen + 输入框 + 发送按钮），不是直接调 Agent；
// 技能根用 `setRootForTests(临时根)` 指到临时目录，夹具技能固定 `edge-skill`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/ui/message_bubble.dart';

import 'helpers/fakes.dart';
import 'helpers/test_utils.dart';
import '../integration/helpers/fake_sidecar.dart';

void main() {
  late Directory skillsRoot;

  setUp(() {
    skillsRoot = Directory.systemTemp.createTempSync('slash_cmd_widget_');
    SkillCatalogService.instance.resetForTests();
    SkillCatalogService.instance.setRootForTests(skillsRoot.path);

    // 夹具技能固定 `edge-skill`（frontmatter name + 非空 description）。
    final dir =
        Directory('${skillsRoot.path}${Platform.pathSeparator}edge-skill')
          ..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: edge-skill\ndescription: 斜杠命令 widget 用例夹具技能\n---\n# 正文\n');

    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokens: 100000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
  });

  tearDown(() {
    // 恢复默认根并清空单例，避免用例间串味。
    SkillCatalogService.instance.setRootForTests(null);
    SkillCatalogService.instance.resetForTests();
    if (skillsRoot.existsSync()) skillsRoot.deleteSync(recursive: true);
    registry.clear();
    resolver = null;
  });

  testWidgets('发送 `/edge-skill 正文`：聊天气泡显示的 user 文本逐字是手打原文',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sidecar = FakeSidecar()
      ..stubSearchProviders('[]')
      ..stubBrowserAvailable('{"ok":true,"available":false}')
      ..queueChunk('收到')
      ..queueDone();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: FakeSessionRepository(testSessions(1)),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    const raw = '/edge-skill 正文';
    await tester.enterText(find.byType(TextField), raw);
    await tester.tap(find.byTooltip('Send'));
    // 三次 pump 让"发送 → 落库 → 模型请求 → 回复"的异步链走完（与既有用例同节奏）。
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final userBubble = find.byWidgetPredicate(
        (widget) => widget is MessageBubble && widget.role == 'user');
    final bubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .map((b) => '${b.role}:${b.content}')
        .toList();
    // ignore: avoid_print
    print('[斜杠-widget] 发往模型 raw=${sidecar.lastMessagesJson != null} '
        '气泡清单=$bubbles');
    // ignore: avoid_print
    print('[斜杠-widget] 气泡里的 user 文本=${tester.widget<MessageBubble>(
      userBubble,
    ).content}');
    // ignore: avoid_print
    print('[斜杠-widget] 气泡里是否出现展开模板='
        '${find.descendant(of: userBubble, matching: find.textContaining('已按斜杠命令展开技能')).evaluate().isNotEmpty}');

    expect(userBubble, findsOneWidget, reason: '发送后对话视图里应有一条 user 气泡');
    final bubble = tester.widget<MessageBubble>(userBubble);
    expect(bubble.content, raw,
        reason: '聊天气泡的 user 文本必须逐字是手打原文（展开对对话视图不可见）');
    // 气泡真的把原文渲染出来（用户气泡是纯 Text，不走 Markdown）。
    expect(find.descendant(of: userBubble, matching: find.text(raw)),
        findsOneWidget,
        reason: '气泡里必须看得见原文');
    // 零痕迹：展开模板一个字都不许出现在这条气泡里。
    expect(
        find.descendant(
            of: userBubble, matching: find.textContaining('已按斜杠命令展开技能')),
        findsNothing,
        reason: '展开只发生在模型装配面，对话视图不许出现模板');
  });
}
