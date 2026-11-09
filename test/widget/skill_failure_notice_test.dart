// 技能校验失败的**上屏提示**用例（change `add-skill-mechanism` 任务 6.4）。
//
// 钉两件事（规范「SKILL.md 元数据校验」的可见性要求）：
//   ① 有失败技能时，界面上确实出现一条提示，字符串里含**技能名**与**失败原因**；
//   ② 没有任何技能目录（首次用户的默认状态）时，界面**不产生任何**技能提示。
//
// 扫描根用 `SkillCatalogService.rootPathOverrideForTests` 指到临时目录 —— 用例绝不
// 读用户主目录里的真实技能目录，结果与机器无关。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';

import 'helpers/fakes.dart';
import 'helpers/test_utils.dart';
import '../integration/helpers/fake_sidecar.dart';

void main() {
  late Directory skillsRoot;

  setUp(() {
    skillsRoot = Directory.systemTemp.createTempSync('skill_notice_');
    SkillCatalogService.instance.resetForTests();
  });

  tearDown(() {
    SkillCatalogService.rootPathOverrideForTests = null;
    SkillCatalogService.instance.resetForTests();
    if (skillsRoot.existsSync()) skillsRoot.deleteSync(recursive: true);
    registry.clear();
    resolver = null;
  });

  void setupRegistry() {
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
  }

  Widget buildApp(FakeSidecar sidecar) => MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            config: const AppConfig(version: 1),
            sessionRepo: FakeSessionRepository(testSessions(1)),
            msgRepo: FakeMessageRepository(),
            sidecar: sidecar,
          ),
        ),
      );

  testWidgets('有失败技能时界面出现提示，字符串含技能名与原因', (tester) async {
    setupRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    // 目录名合法、frontmatter 的 name 65 字符 ⇒ 校验失败。
    final broken = Directory(
        '${skillsRoot.path}${Platform.pathSeparator}broken-skill')
      ..createSync(recursive: true);
    File('${broken.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: ${'a' * 65}\ndescription: 坏技能\n---\n# 正文\n');
    SkillCatalogService.rootPathOverrideForTests = skillsRoot.path;

    final sidecar = FakeSidecar()
      ..stubSearchProviders('[]')
      ..stubBrowserAvailable('{"ok":true,"available":false}')
      ..queueDone();

    await tester.pumpWidget(buildApp(sidecar));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // ignore: avoid_print
    print('[技能提示] 扫描结果：hasScanned=${SkillCatalogService.instance.hasScanned} '
        'notice=${SkillCatalogService.instance.failureNotice}');
    expect(SkillCatalogService.instance.hasScanned, isTrue);

    final noticeFinder = find.byKey(const ValueKey('skill-failure-notice'));
    expect(noticeFinder, findsOneWidget, reason: '失败技能必须上屏，不许静默跳过');
    final text = tester.widget<Text>(
        find.descendant(of: noticeFinder, matching: find.byType(Text)));
    // ignore: avoid_print
    print('[技能提示] 界面文本=${text.data}');
    expect(text.data, contains('broken-skill'), reason: '提示里要有技能名');
    expect(text.data, contains('name 超过 64 字符'), reason: '提示里要有失败原因');
    expect(text.data, contains('未生效'));
  });

  testWidgets('没有技能目录时不产生任何技能提示', (tester) async {
    setupRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    SkillCatalogService.rootPathOverrideForTests =
        '${skillsRoot.path}${Platform.pathSeparator}not-created';

    final sidecar = FakeSidecar()
      ..stubSearchProviders('[]')
      ..stubBrowserAvailable('{"ok":true,"available":false}')
      ..queueDone();

    await tester.pumpWidget(buildApp(sidecar));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // ignore: avoid_print
    print('[技能提示] 无目录：hasScanned=${SkillCatalogService.instance.hasScanned} '
        'notice=${SkillCatalogService.instance.failureNotice} '
        '提示组件=${find.byKey(const ValueKey('skill-failure-notice')).evaluate().length}');
    expect(SkillCatalogService.instance.hasScanned, isTrue);
    expect(SkillCatalogService.instance.failureNotice, isNull);
    expect(find.byKey(const ValueKey('skill-failure-notice')), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // change `refresh-skill-catalog-each-turn` 任务 2.3 新增的两条：
  //
  // 既有两条只覆盖"**启动**扫描那一次"的提示。下面这两条覆盖"应用已经在跑"的
  // 场景：提示必须跟着**每轮装配前的重扫**更新，而不是冻结在启动快照。
  // 它们在本 change 之前必须**红**（当时 `_skillFailureNotice` 只在启动扫描里赋值）。
  // ---------------------------------------------------------------------------

  /// 发一条消息并把这一轮跑完（三次 pump 让异步链走完，与既有用例同节奏）。
  Future<void> sendTurn(WidgetTester tester, String text,
      FakeSidecar sidecar) async {
    sidecar.queueChunk('reply');
    sidecar.queueDone();
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  void writeBrokenSkill() {
    // 目录名合法、frontmatter 的 name 65 字符 ⇒ 校验失败。
    final broken = Directory(
        '${skillsRoot.path}${Platform.pathSeparator}broken-skill')
      ..createSync(recursive: true);
    File('${broken.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: ${'a' * 65}\ndescription: 坏技能\n---\n# 正文\n');
  }

  void fixBrokenSkill() {
    // 修好：name 与目录名一致、长度合法（内容长度也变了 ⇒ 指纹变化可被探测）。
    final dir = Directory(
        '${skillsRoot.path}${Platform.pathSeparator}broken-skill');
    File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: broken-skill\ndescription: 修好了\n---\n# 正文\n');
  }

  testWidgets('启动时没坏文件、跑过一轮后再放入坏技能 ⇒ 下一条消息后提示出现', (tester) async {
    setupRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    // 空技能根：启动扫描什么都不报（首条消息前没有提示，这是默认状态）。
    SkillCatalogService.instance.setRootForTests(skillsRoot.path);

    final sidecar = FakeSidecar()
      ..stubSearchProviders('[]')
      ..stubBrowserAvailable('{"ok":true,"available":false}');

    await tester.pumpWidget(buildApp(sidecar));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final noticeFinder = find.byKey(const ValueKey('skill-failure-notice'));
    // ignore: avoid_print
    print('[技能提示-热更] 启动后：hasScanned=${SkillCatalogService.instance.hasScanned} '
        'notice=${SkillCatalogService.instance.failureNotice} '
        '提示组件=${noticeFinder.evaluate().length}');
    expect(noticeFinder, findsNothing, reason: '启动时没有坏文件 ⇒ 不该有提示');

    // 第一条消息走完一轮（此时仍没有坏文件）。
    await sendTurn(tester, '第一问', sidecar);
    expect(noticeFinder, findsNothing);

    // 应用运行中放入坏技能：只有下一轮装配前的重扫才知道它。
    writeBrokenSkill();
    // ignore: avoid_print
    print('[技能提示-热更] 已放入坏技能：notice=${SkillCatalogService.instance.failureNotice}');

    // 下一条消息：本轮装配重扫 → 提示必须出现。
    await sendTurn(tester, '第二问', sidecar);
    // ignore: avoid_print
    print('[技能提示-热更] 重建后：notice=${SkillCatalogService.instance.failureNotice} '
        '提示组件=${noticeFinder.evaluate().length}');

    expect(noticeFinder, findsOneWidget,
        reason: '技能提示必须跟着每轮装配刷新，不许冻结在启动快照');
    final text = tester.widget<Text>(
        find.descendant(of: noticeFinder, matching: find.byType(Text)));
    // ignore: avoid_print
    print('[技能提示-热更] 界面文本=${text.data}');
    expect(text.data, contains('broken-skill'), reason: '提示里要有技能名');
    expect(text.data, contains('name 超过 64 字符'), reason: '提示里要有失败原因');
    expect(text.data, contains('未生效'));
  });

  testWidgets('修好坏技能后下一条消息 ⇒ 原有提示消失', (tester) async {
    setupRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    writeBrokenSkill();
    SkillCatalogService.instance.setRootForTests(skillsRoot.path);

    final sidecar = FakeSidecar()
      ..stubSearchProviders('[]')
      ..stubBrowserAvailable('{"ok":true,"available":false}');

    await tester.pumpWidget(buildApp(sidecar));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final noticeFinder = find.byKey(const ValueKey('skill-failure-notice'));
    // ignore: avoid_print
    print('[技能提示-热更] 启动即坏文件：notice=${SkillCatalogService.instance.failureNotice} '
        '提示组件=${noticeFinder.evaluate().length}');
    expect(noticeFinder, findsOneWidget, reason: '启动扫描那一次的首次提示保留');

    // 跑一轮（此时仍是坏的，提示应在）。
    await sendTurn(tester, '第一问', sidecar);
    expect(noticeFinder, findsOneWidget);

    // 修好文件：下一轮装配重扫后提示必须消失。
    fixBrokenSkill();
    await sendTurn(tester, '第二问', sidecar);
    // ignore: avoid_print
    print('[技能提示-热更] 修好后：notice=${SkillCatalogService.instance.failureNotice} '
        '提示组件=${noticeFinder.evaluate().length}');
    expect(SkillCatalogService.instance.failureNotice, isNull);
    expect(noticeFinder, findsNothing,
        reason: '修好之后提示必须随每轮装配刷新而消失，不许一直挂着旧提示');
  });
}
