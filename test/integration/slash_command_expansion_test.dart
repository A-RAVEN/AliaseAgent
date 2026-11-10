// 斜杠命令展开的装配面端到端用例（change `add-slash-commands` 任务 2.2）。
//
// 四条，分别钉 design D1 / D2 的一句话：
//   ① 命中展开：发 `/edge-skill 把这段文字按技能要求处理` ⇒ **发往模型的 user 文本
//      逐字等于任务 1.2 的整段期望**（防接线截断后仍"含指示"而误绿），而 `messageRepo`
//      落库的 user 消息逐字是手打原文、会话标题也由原文生成；
//   ② 普通消息透传：模型收到的 user 文本 = 原文；
//   ③ 当轮集合语义（缺实现即红）：第一轮命中展开 ⇒ 轮间删掉技能 ⇒ 第二轮历史里那条
//      原样不展开；
//   ④ 技能未删时第二轮重新装配：历史那条仍是展开版，新消息逐字原文（spec「历史消息
//      逐条展开」场景）。
//
// 断言的是 FakeSidecar 记录的**真正发出去的 messagesJson**，不是内部变量；技能根用
// `setRootForTests(临时根)` 指到临时目录，夹具技能固定 `edge-skill`，不读用户主目录。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 把不可见字符写成可见形态，便于输出被人工核对（只用于打印，不参与断言）。
String _visible(String s) => s.replaceAll('\n', r'\n');

void main() {
  late FakeSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late Directory skillsRoot;
  late Directory edgeSkillDir;

  // ---- 期望串：测试自持的硬编码字面量（禁止引用实现常量拼期望）----
  // ① 的整段期望 = tasks 1.2 那条断言逐字相同。
  const expectedFull = '已按斜杠命令展开技能 "edge-skill"：请先调用 load_skill(skill: "edge-skill") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：\n\n把这段文字按技能要求处理';
  // 前缀句逐字副本：给 ③④ 的正文拼尾部用。
  const expectedPrefix = '已按斜杠命令展开技能 "edge-skill"：请先调用 load_skill(skill: "edge-skill") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：';

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  Session session(String id) => Session(
        id: id,
        // `New Chat` 才会走 updateTitleIfDefault ⇒ 能断言标题由原文生成。
        title: 'New Chat',
        agentType: 'general',
        createdAt: 1,
        updatedAt: 1,
      );

  setUp(() {
    ToolCatalog.instance.seed({'read_file': def('read_file')});
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: 'GENERAL-PROMPT',
      tools: ['read_file'],
      maxContextTokens: 100000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar()
      ..stubSearchProviders('[]')
      ..stubBrowserAvailable('{"ok":true,"available":false}');
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
    skillsRoot = Directory.systemTemp.createTempSync('slash_cmd_expansion_');
    SkillCatalogService.instance.resetForTests();
    // 每轮装配前的 scan 不传 rootPath ⇒ 把"缺省根"本身指到临时目录。
    SkillCatalogService.instance.setRootForTests(skillsRoot.path);

    // 夹具技能固定为 `edge-skill`（frontmatter name + 非空 description）。
    edgeSkillDir =
        Directory('${skillsRoot.path}${Platform.pathSeparator}edge-skill')
          ..createSync(recursive: true);
    File('${edgeSkillDir.path}${Platform.pathSeparator}SKILL.md')
        .writeAsStringSync('---\nname: edge-skill\n'
            'description: 斜杠命令集成测试夹具技能\n---\n# 正文\n');
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
    SkillCatalogService.instance.resetForTests();
    SkillCatalogService.instance.setRootForTests(null);
    if (skillsRoot.existsSync()) skillsRoot.deleteSync(recursive: true);
  });

  Future<Agent> buildAgent(String id) async {
    final s = session(id);
    // 会话先落进假仓库：`updateTitleIfDefault` 与 `get` 才看得到它（标题断言要用）。
    sessionRepo.sessions.add(s);
    final factory = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
    return factory.create(session(id));
  }

  void queueTurn({String chunk = 'ok'}) {
    sidecar.queueChunk(chunk);
    sidecar.queueDone();
  }

  /// 从真正发出去的 messagesJson 里按顺序抽出所有 `role == 'user'` 的文本块。
  List<String> sentUserTexts(String messagesJson) {
    final decoded = jsonDecode(messagesJson) as List<dynamic>;
    final texts = <String>[];
    for (final raw in decoded) {
      final m = raw as Map<String, dynamic>;
      if (m['role'] != 'user') continue;
      final content = m['content'];
      if (content is! List) continue;
      for (final block in content) {
        final b = block as Map<String, dynamic>;
        if (b['type'] == 'text') texts.add((b['text'] as String?) ?? '');
      }
    }
    return texts;
  }

  test('① 命中：发往模型的 user 文本逐字等于整段期望；落库与标题是原文', () async {
    const raw = '/edge-skill 把这段文字按技能要求处理';
    final agent = await buildAgent('s1');
    queueTurn(chunk: '回复一');
    await agent.send(raw);

    final sent = sentUserTexts(sidecar.lastMessagesJson!);
    final stored = msgRepo.messages.where((m) => m.role == 'user').toList();
    final loaded = await sessionRepo.get('s1');
    // ignore: avoid_print
    print('[斜杠-集成] ① 请求数=${sidecar.sendHandles.length} '
        'user 文本数=${sent.length}');
    // ignore: avoid_print
    print('[斜杠-集成] ① 模型收到=${_visible(sent.single)}');
    // ignore: avoid_print
    print('[斜杠-集成] ① 落库 user 原文=${_visible(stored.single.content)}');
    // ignore: avoid_print
    print('[斜杠-集成] ① 会话标题=${loaded?.title}');

    expect(sent.single, expectedFull,
        reason: '接线截断模板后只要还"含指示"就会误绿 —— 这里要求整段逐字相等');
    expect(stored.single.content, raw, reason: '落库必须是用户手打原文');
    expect(loaded?.title, raw, reason: '会话标题由原文生成，不含展开模板');
  });

  test('② 普通消息：模型收到的 user 文本逐字是原文', () async {
    const raw = '一条普通消息，没有斜杠';
    final agent = await buildAgent('s2');
    queueTurn(chunk: '回复二');
    await agent.send(raw);

    final sent = sentUserTexts(sidecar.lastMessagesJson!);
    // ignore: avoid_print
    print('[斜杠-集成] ② 模型收到=${_visible(sent.single)}');
    expect(sent.single, raw);
    expect(msgRepo.messages.where((m) => m.role == 'user').single.content, raw);
  });

  test('③ 轮间删掉技能：第二轮历史里那条不再展开（当轮集合语义）', () async {
    final agent = await buildAgent('s3');
    queueTurn(chunk: '第一轮回复');
    await agent.send('/edge-skill 干活');

    final first = sentUserTexts(sidecar.lastMessagesJson!);
    // ignore: avoid_print
    print('[斜杠-集成] ③ 第一轮模型收到=${_visible(first.single)}');
    expect(first.single, '$expectedPrefix\n\n干活',
        reason: '第一轮必须真的展开（这条前置断言是"缺实现即红"的一半）');

    // 轮间删掉技能目录：第二轮 scan 后生效集合为空。
    edgeSkillDir.deleteSync(recursive: true);
    // ignore: avoid_print
    print('[斜杠-集成] ③ 已删除技能目录，生效集合='
        '${SkillCatalogService.instance.activeSkillNames}（下一轮 scan 才更新）');

    queueTurn(chunk: '第二轮回复');
    await agent.send('第二条普通消息');

    final second = sentUserTexts(sidecar.lastMessagesJson!);
    // ignore: avoid_print
    print('[斜杠-集成] ③ 第二轮模型收到 ${second.length} 条 user 文本：'
        '${second.map(_visible).toList()}');
    expect(SkillCatalogService.instance.activeSkillNames, isEmpty,
        reason: '技能已删 ⇒ 当轮生效集合为空');
    expect(second.length, 2, reason: '第二轮装配带上历史那条 + 新消息');
    expect(second[0], '/edge-skill 干活',
        reason: '技能删掉后历史那条按当轮集合判定 ⇒ 原样出现，不再展开');
    expect(second[1], '第二条普通消息');
  });

  test('④ 技能未删：第二轮历史那条仍是展开版，新消息逐字原文', () async {
    final agent = await buildAgent('s4');
    queueTurn(chunk: '第一轮回复');
    await agent.send('/edge-skill 干活');

    final first = sentUserTexts(sidecar.lastMessagesJson!);
    // ignore: avoid_print
    print('[斜杠-集成] ④ 第一轮模型收到=${_visible(first.single)}');
    expect(first.single, '$expectedPrefix\n\n干活',
        reason: '第一轮必须真的展开（缺实现时这条先红）');

    queueTurn(chunk: '第二轮回复');
    await agent.send('第二条普通消息');

    final second = sentUserTexts(sidecar.lastMessagesJson!);
    // ignore: avoid_print
    print('[斜杠-集成] ④ 第二轮模型收到 ${second.length} 条 user 文本：'
        '${second.map(_visible).toList()}');
    expect(second.length, 2);
    expect(second[0], '$expectedPrefix\n\n干活',
        reason: '历史消息逐条展开：第二轮发给模型的历史那条仍是展开版');
    expect(second[1], '第二条普通消息',
        reason: '新消息逐字原文、不被误展开');
  });
}
