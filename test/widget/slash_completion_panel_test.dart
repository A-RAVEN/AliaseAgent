// 斜杠命令**输入补全**的现场用例（change `slash-command-completion` 任务 2.1）。
//
// 全部走真实 widget 现场（ChatScreen + 输入行 + 真实的技能目录扫描），不是直接调
// 面板组件 —— 因为要钉的正是"按键先被输入行截住、再轮到既有 Enter→发送分支"这条
// 接线（design D2）。
//
// 每条用例都先断**正事实**（候选行真的出现、焦点真的在输入框 / 面板真的可见），再断
// 负事实（没发送、面板消失）。否则"面板消失"可能只是从来没出现过。
//
// 夹具技能根用 `setRootForTests(临时根)` 指向临时目录，绝不读用户主目录的真实技能。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 面板根标记（实现侧挂在面板最外层，用来断"面板在/不在"，与行文本分开）。
const _panelKey = ValueKey<String>('slash-completion-panel');

/// 空目录空态提示的**精确串**（spec「空目录空态提示」）。
///
/// 这里硬编码、**不引用实现常量**：引用的话改文案时断言会跟着实现一起漂移，
/// 守卫就废了（`test/unit/slash_commands_test.dart` 同款纪律）。
const _emptyCatalogHint = '装一个技能后这里会自动出现候选（详见 skills.md）';

/// 无命中提示的精确串（spec「无命中」）。
const _noMatchHint = '无匹配技能';

/// 把空格写成可见形态，便于输出被人工核对（只用于打印，不参与断言）。
String _visible(String s) => s.replaceAll(' ', '␣');

void main() {
  late Directory skillsRoot;

  setUp(() {
    skillsRoot = Directory.systemTemp.createTempSync('slash_completion_panel_');
    SkillCatalogService.instance.resetForTests();
    SkillCatalogService.instance.setRootForTests(skillsRoot.path);
    _writeSkill(skillsRoot, 'edge-skill');
    _setupRegistry();
  });

  tearDown(() {
    // 恢复默认根并清空单例，避免用例间串味。
    SkillCatalogService.instance.setRootForTests(null);
    SkillCatalogService.instance.resetForTests();
    if (skillsRoot.existsSync()) skillsRoot.deleteSync(recursive: true);
    registry.clear();
    resolver = null;
  });

  // ── ① 键入 `/ed` 弹候选，Tab 接受 ──────────────────────────────────────
  testWidgets('① /ed 弹候选；Tab 接受成 /edge-skill␣、面板关闭、焦点留在输入框、未发送',
      (tester) async {
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/ed');
    await tester.pump();

    // 先断正事实：候选行真的出现、焦点真的在输入框（否则 Tab 到不了输入行的 Focus）。
    expect(find.text('edge-skill'), findsOneWidget,
        reason: '键入 /ed 后必须出现 edge-skill 候选行');
    expect(_field(tester).focusNode!.hasFocus, isTrue,
        reason: '焦点必须在输入框，Tab 才会经过输入行的 Focus.onKeyEvent');
    _printState('①面板可见', tester, sidecar);
    // 面板真的浮在输入框上方（不是零尺寸、也不是叠在输入框上）。
    final fieldRect = tester.getRect(find.byType(TextField));
    final panelRect = tester.getRect(find.byKey(_panelKey));
    // ignore: avoid_print
    print('[斜杠补全] ①几何：输入框=$fieldRect 面板=$panelRect');
    expect(panelRect.height, greaterThan(0), reason: '面板必须真的占出高度');
    expect(panelRect.bottom, lessThanOrEqualTo(fieldRect.top),
        reason: '面板必须浮在输入框上方（design D5）');
    expect(panelRect.width, closeTo(fieldRect.width, 1),
        reason: '面板宽度对齐输入框（design D5）');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump();

    _printState('①Tab 后', tester, sidecar);
    expect(_field(tester).controller!.text, '/edge-skill ',
        reason: '接受 = 首段替换为 /完整技能名 + 一个空格（尾部空格）');
    expect(_field(tester).controller!.selection,
        const TextSelection.collapsed(offset: 12),
        reason: '光标必须落在插入文本之后（design D4），才能接着打正文');
    expect(_field(tester).focusNode!.hasFocus, isTrue,
        reason: '接受补全不许把焦点挪走');
    expect(find.byKey(_panelKey), findsNothing, reason: '接受后面板必须消失');
    expect(_userBubbles, findsNothing, reason: '接受补全不是发送，不许出现 user 气泡');
    expect(sidecar.sendHandles, isEmpty, reason: '接受补全不许触发 sidecar 请求');
  });

  // ── ② 回车同 Tab ──────────────────────────────────────────────────────
  testWidgets('② 回车同 Tab：接受补全、不发送', (tester) async {
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/ed');
    await tester.pump();
    expect(find.text('edge-skill'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();

    _printState('②回车后', tester, sidecar);
    expect(_field(tester).controller!.text, '/edge-skill ',
        reason: '面板可见且有高亮行时回车是"接受补全"，不是发送（design D4）');
    expect(find.byKey(_panelKey), findsNothing);
    expect(_userBubbles, findsNothing, reason: '回车被改道成接受，不许发送');
    expect(sidecar.sendHandles, isEmpty);
  });

  // ── ③ Esc 关闭不改写 ──────────────────────────────────────────────────
  testWidgets('③ Esc 关闭面板、文本不变、焦点仍在输入框', (tester) async {
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/ed');
    await tester.pump();
    expect(find.text('edge-skill'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();

    _printState('③Esc 后', tester, sidecar);
    expect(_field(tester).controller!.text, '/ed', reason: 'Esc 只关闭、不改写文本');
    expect(find.byKey(_panelKey), findsNothing, reason: 'Esc 后面板必须消失');
    expect(_field(tester).focusNode!.hasFocus, isTrue, reason: 'Esc 归还焦点给输入框');
    expect(_userBubbles, findsNothing);
    expect(sidecar.sendHandles, isEmpty);
  });

  // ── ④ 打出空白面板即关，输入行为回到原样 ───────────────────────────────
  testWidgets('④ 继续打空格（/ed ）面板消失、文本保持、回车回到发送原行为',
      (tester) async {
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/ed');
    await tester.pump();
    expect(find.text('edge-skill'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/ed ');
    await tester.pump();

    _printState('④空格后', tester, sidecar);
    expect(find.byKey(_panelKey), findsNothing,
        reason: '打出第一个空白后关闭条件成立（design D1）');
    expect(find.text('edge-skill'), findsNothing);
    expect(_field(tester).controller!.text, '/ed ', reason: '关闭不改写已经打出的文本');

    // 面板关掉之后回车回到"发送"（既有行为，逐字节不变）。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    _printState('④回车后', tester, sidecar);
    expect(sidecar.sendHandles, isNotEmpty,
        reason: '面板不可见时回车必须走既有发送分支（这一步是对照，证明 ①③ 的"未发送"不是恒真）');
    expect(_userBubbles, findsOneWidget);
  });

  // ── ⑤ 大写非相邻子序列命中；零候选不吞键 ───────────────────────────────
  testWidgets('⑤ /EGK 子序列命中；/zzz 显示"无匹配技能"且零候选不吞键（Enter 仍发送、Tab 仍焦点遍历）',
      (tester) async {
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/EGK');
    await tester.pump();
    _printState('⑤/EGK', tester, sidecar);
    expect(find.text('edge-skill'), findsOneWidget,
        reason: '大写、按序不必相邻的子序列（E…G…K）也必须命中');

    await tester.enterText(find.byType(TextField), '/zzz');
    await tester.pump();
    _printState('⑤/zzz', tester, sidecar);
    expect(find.text(_noMatchHint), findsOneWidget,
        reason: '无命中要显示一行"无匹配技能"提示（可见性），不是让面板消失');
    expect(find.text('edge-skill'), findsNothing);

    // 零候选：Tab 不许被吞，必须继续走 WidgetsApp 的默认焦点遍历。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    _printState('⑤Tab', tester, sidecar);
    expect(_field(tester).focusNode!.hasFocus, isFalse,
        reason: '零候选时 Tab 必须交给默认焦点遍历（design D2）');
    expect(_field(tester).controller!.text, '/zzz',
        reason: '零候选时 Tab 不许改写文本');

    // 零候选：Enter 仍是发送（这条同时是对照：同一 pump 节奏下发送真的会发生）。
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '/zzz');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    _printState('⑤Enter', tester, sidecar);
    expect(sidecar.sendHandles, isNotEmpty,
        reason: '零候选时 Enter 仍发送（面板只是提示层，不吞键）');
    expect(_userBubbles, findsOneWidget, reason: '发送后对话视图出现 user 气泡');
  });

  // ── ⑥ ↑↓ 移动高亮后 Tab 接受对应行 ─────────────────────────────────────
  testWidgets('⑥ ↓ 移动高亮后 Tab 接受第二行（夹具两个技能）', (tester) async {
    _writeSkill(skillsRoot, 'other-skill');
    // 新目录要让下一轮扫描看见：清掉启动前的状态，让 pump 里的扫描重读。
    SkillCatalogService.instance.resetForTests();
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    _printState('⑥/ 后', tester, sidecar);
    expect(find.text('edge-skill'), findsOneWidget);
    expect(find.text('other-skill'), findsOneWidget,
        reason: '空查询按输入顺序全量列出（activeSkillNames 本身按字典序）');
    expect(find.text(_noMatchHint), findsNothing);
    expect(find.text(_emptyCatalogHint), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    _printState('⑥↓ 后', tester, sidecar);
    expect(_field(tester).controller!.text, '/', reason: '↓ 只移动高亮，不许改动输入文本');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump();
    _printState('⑥Tab 后', tester, sidecar);
    expect(_field(tester).controller!.text, '/other-skill ',
        reason: '↓ 之后高亮第二行，Tab 必须接受它');
    expect(find.byKey(_panelKey), findsNothing);
  });

  // ── ⑦ 空技能目录的空态提示 ────────────────────────────────────────────
  testWidgets('⑦ 空技能目录：键入 / 显示精确空态行、无候选行、不报错', (tester) async {
    Directory('${skillsRoot.path}${Platform.pathSeparator}edge-skill')
        .deleteSync(recursive: true);
    SkillCatalogService.instance.resetForTests();
    final sidecar = await _pumpChat(tester);
    expect(SkillCatalogService.instance.activeSkillNames, isEmpty,
        reason: '现场必须是空技能目录');

    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();

    _printState('⑦空目录', tester, sidecar);
    final panel = find.byKey(_panelKey);
    expect(panel, findsOneWidget, reason: '空目录也要有面板（给一行空态提示，不是消失）');
    expect(
      find.descendant(of: panel, matching: find.text(_emptyCatalogHint)),
      findsOneWidget,
      reason: '空目录必须显示精确串「$_emptyCatalogHint」',
    );
    expect(find.text('edge-skill'), findsNothing, reason: '空目录不许出现任何候选行');
    expect(find.text(_noMatchHint), findsNothing,
        reason: '空目录用空态文案，不用"无匹配技能"（那是查询无命中的口径）');
    expect(tester.takeException(), isNull, reason: '空目录只提示、不报错');
  });

  // ── ⑧ 首段后有文本：光标回到首段也不弹 ────────────────────────────────
  testWidgets('⑧ /ed 正文（首段后已有文本）光标移回首段：面板不显示、正文不受影响',
      (tester) async {
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/ed 正文');
    await tester.pump();
    expect(find.byKey(_panelKey), findsNothing,
        reason: '光标在末尾（首段之外）时本来就不该弹');

    final controller = _field(tester).controller!;
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    _printState('⑧光标回首段', tester, sidecar);
    expect(controller.text, '/ed 正文', reason: '移动光标不许改写文本');
    expect(find.byKey(_panelKey), findsNothing,
        reason: '首段后已有文本（design D1 条件④）—— 光标回到首段也不弹，'
            '否则接受补全会吃掉正文');
    expect(find.text('edge-skill'), findsNothing);
  });

  // ── ⑨ 鼠标点击=接受 ───────────────────────────────────────────────────
  testWidgets('⑨ 鼠标点击候选行=接受（不发送、焦点仍在输入框）', (tester) async {
    final sidecar = await _pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/ed');
    await tester.pump();
    expect(find.text('edge-skill'), findsOneWidget);

    await tester.tap(find.text('edge-skill'));
    await tester.pump();
    await tester.pump();

    _printState('⑨点击后', tester, sidecar);
    expect(_field(tester).controller!.text, '/edge-skill ', reason: '点击候选 = 接受该行');
    expect(find.byKey(_panelKey), findsNothing);
    expect(_field(tester).focusNode!.hasFocus, isTrue,
        reason: '面板 never request focus（design D1）：点它不许把焦点抢走');
    expect(_userBubbles, findsNothing);
    expect(sidecar.sendHandles, isEmpty);
  });
}

// ---------------------------------------------------------------------------
// 现场与输出
// ---------------------------------------------------------------------------

/// 写一个夹具技能：目录名 = frontmatter 的 name，description 非空。
void _writeSkill(Directory root, String name) {
  final dir = Directory('${root.path}${Platform.pathSeparator}$name')
    ..createSync(recursive: true);
  File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
      '---\nname: $name\ndescription: 斜杠补全 widget 用例夹具技能 $name\n---\n# 正文\n');
}

/// 模板注册表与 provider 解析器（`lib/main.dart` 的两个全局变量，与既有
/// `slash_command_display_test` / `skill_failure_notice_test` 同一套配方）。
void _setupRegistry() {
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

/// pump 出 ChatScreen 并等启动链走完（三次 pump：扫描 → 工具 → 首帧渲染）。
///
/// 每次都给 sidecar 排一条正常回复：⑤ 真的要发一条消息，其余用例不发（排着不影响）。
Future<FakeSidecar> _pumpChat(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

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
  expect(SkillCatalogService.instance.hasScanned, isTrue,
      reason: '启动扫描必须已完成，否则候选表天然为空、用例失去意义');
  return sidecar;
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));

Finder get _userBubbles => find.byWidgetPredicate(
    (widget) => widget is MessageBubble && widget.role == 'user');

/// 打印现场：文本（空格可见）、焦点、面板在不在、气泡清单、sidecar 发送句柄。
void _printState(String tag, WidgetTester tester, FakeSidecar sidecar) {
  final field = _field(tester);
  final bubbles = tester
      .widgetList<MessageBubble>(find.byType(MessageBubble))
      .map((b) => '${b.role}:${b.content}')
      .toList();
  // ignore: avoid_print
  print('[斜杠补全] $tag：文本="${_visible(field.controller!.text)}" '
      '焦点=${field.focusNode!.hasFocus} '
      '面板=${find.byKey(_panelKey).evaluate().length} '
      '气泡=$bubbles sendHandles=${sidecar.sendHandles}');
}
