// 技能热更新的端到端用例（change `refresh-skill-catalog-each-turn` 任务 2.2，
// FakeSidecar，无窗口、无网络、无真实 DLL）。
//
// 三条，分别钉本 change 的一句话：
//   ① **轮间刷新**：第一轮发出后往夹具目录里加一个技能、并改掉已有技能的
//      description ⇒ 第二轮的 systemPrompt 目录反映新内容，而第一轮那份请求里
//      一个字都没有（改动只从下一轮生效，需求"下一条消息就生效"）；
//   ② **未变文件不被重读**：两轮之间磁盘不动 ⇒ 第二轮装配时的
//      `lastScanReReadCount = 0`（经服务单例读，design D4），目录文本与第一轮相同；
//   ③ **一轮内视图一致**：同一轮的两次模型请求（工具循环里的第二次 sendMessage）
//      之间改文件 ⇒ 第二次请求的 systemPrompt 仍是本轮装配时的快照，改动到**下一轮**
//      才反映（design D2；这条用例是"一轮内一致"语义的专属用例，缺实现即红 ——
//      若实现改成"每次工具调用/每次请求都扫"，第二条请求就会带上新内容）。
//
// 断言的是**真正发出去的请求**（FakeSidecar 记录的 systemPrompt），不是内部变量。
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
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 按顺序记录每一次模型请求（FakeSidecar 只留最后一次）—— 一轮内一致性用例必须
/// 同时看到同一轮的第一次与第二次请求。
class _RecordingSidecar extends FakeSidecar {
  final List<({String handle, String systemPrompt, String toolsJson})> requests =
      [];

  @override
  Future<void> sendMessage({
    required String handle,
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required String thinkingMode,
    required String thinkingEffort,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  }) {
    requests
        .add((handle: handle, systemPrompt: systemPrompt, toolsJson: toolsJson));
    return super.sendMessage(
      handle: handle,
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      systemPrompt: systemPrompt,
      messagesJson: messagesJson,
      toolsJson: toolsJson,
      thinkingMode: thinkingMode,
      thinkingEffort: thinkingEffort,
      onChunk: onChunk,
      onToolCall: onToolCall,
      onThinking: onThinking,
      onDone: onDone,
    );
  }
}

/// 轮询等待（真实事件循环里让 Agent 的 Future 链推进到某个可观测状态）。
Future<void> _waitUntil(bool Function() condition, String what) async {
  for (var i = 0; i < 20000; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('等待超时：$what');
}

void main() {
  late _RecordingSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late Directory skillsRoot;

  const instructionPrefix = 'Available skills (load one with load_skill(skill)';

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
        title: 'Session $id',
        agentType: 'general',
        createdAt: 1,
        updatedAt: 1,
      );

  void writeSkill(String dirName, String description) {
    final dir = Directory('${skillsRoot.path}${Platform.pathSeparator}$dirName')
      ..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: $dirName\ndescription: $description\n---\n# 正文\n');
  }

  /// 提示词里的技能目录行（`- <name>: <description>`），便于观察与断言。
  List<String> skillLines(String prompt) => prompt
      .split('\n')
      .where((line) => line.startsWith('- '))
      .toList(growable: false);

  setUp(() {
    ToolCatalog.instance.seed({
      'read_file': def('read_file'),
    });
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
    sidecar = _RecordingSidecar()
      ..stubSearchProviders('[]')
      ..stubBrowserAvailable('{"ok":true,"available":false}');
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
    skillsRoot = Directory.systemTemp.createTempSync('skill_hot_refresh_');
    SkillCatalogService.instance.resetForTests();
    // 每轮装配前的 scan（design D2）不传 rootPath ⇒ 把"缺省根"本身指到临时目录。
    SkillCatalogService.instance.setRootForTests(skillsRoot.path);
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

  test('轮间刷新：第一轮后新增/改动技能 ⇒ 第二轮 systemPrompt 反映，第一轮不含', () async {
    writeSkill('alpha-skill', 'A 的旧描述');
    final agent = await buildAgent('s1');

    queueTurn(chunk: '第一轮回复');
    await agent.send('第一问');
    final prompt1 = sidecar.requests.single.systemPrompt;
    // ignore: avoid_print
    print('[热更] 第一轮请求数=${sidecar.requests.length} 目录行=${skillLines(prompt1)}');
    expect(skillLines(prompt1), ['- alpha-skill: A 的旧描述'],
        reason: '第一轮只看见夹具里当时那一个技能');
    expect(prompt1, isNot(contains('beta-skill')),
        reason: '这一轮之后才放进来的技能不许出现在第一轮');

    // 轮间改盘：新增第二个技能 + 改第一个技能的 description。
    // 注意 description 的**长度也变了**（不是等长的同义改写）：Windows 上 Dart 的
    // `FileStat.modified` 截断到整秒（实测同一秒内两次写盘 mtime 完全相同），等长
    // 覆盖写如果又落在同一秒，就正好命中 spec 登记的检测盲区（同 mtime 同 size）——
    // 那种情形由 `test/unit/skill_catalog_service_test.dart` 的盲区用例负责如实测，
    // 这里要测的是"改了就生效"，所以让 size 也变。
    writeSkill('beta-skill', 'B 的描述');
    writeSkill('alpha-skill', 'A 的新描述（第二轮改的）');

    queueTurn(chunk: '第二轮回复');
    await agent.send('第二问');
    final prompt2 = sidecar.requests.last.systemPrompt;
    // ignore: avoid_print
    print('[热更] 第二轮请求数=${sidecar.requests.length} 目录行=${skillLines(prompt2)} '
        '单例生效集合=${SkillCatalogService.instance.activeSkills}');

    expect(sidecar.requests.length, 2, reason: '两轮 = 两次模型请求（每轮都没工具调用）');
    expect(skillLines(prompt2), [
      '- alpha-skill: A 的新描述（第二轮改的）',
      '- beta-skill: B 的描述',
    ], reason: '下一条消息就生效：新增与改动都反映在第二轮（且按名字字典序）');
    expect(prompt2, contains(instructionPrefix));
    expect(prompt2, isNot(contains('A 的旧描述')), reason: '旧 description 必须被换掉');
    expect(SkillCatalogService.instance.activeSkills.keys,
        ['alpha-skill', 'beta-skill'],
        reason: '生效集合是同一份单例（load_skill 闸门读的就是它）');
  });

  test('两轮之间磁盘不动 ⇒ 第二轮装配时重读计数=0、目录文本不变', () async {
    writeSkill('alpha-skill', 'A 的描述');
    writeSkill('beta-skill', 'B 的描述');
    final agent = await buildAgent('s2');

    queueTurn(chunk: '第一轮回复');
    await agent.send('第一问');
    final prompt1 = sidecar.requests.single.systemPrompt;
    final reRead1 = SkillCatalogService.instance.lastScanReReadCount;
    // ignore: avoid_print
    print('[热更] 第一轮：重读=$reRead1 个文件 目录行=${skillLines(prompt1)}');
    expect(reRead1, 2, reason: '首次装配没有缓存，两个文件都要读');

    queueTurn(chunk: '第二轮回复');
    await agent.send('第二问');
    final prompt2 = sidecar.requests.last.systemPrompt;
    final reRead2 = SkillCatalogService.instance.lastScanReReadCount;
    // ignore: avoid_print
    print('[热更] 第二轮：重读=$reRead2 个文件 目录行=${skillLines(prompt2)}');

    expect(reRead2, 0, reason: '磁盘没变 ⇒ 第二个轮次一个文件都不许重读（design D1/D4）');
    expect(prompt2, contains('\n- alpha-skill: A 的描述'));
    expect(prompt2, contains('\n- beta-skill: B 的描述'));
    expect(skillLines(prompt2), skillLines(prompt1), reason: '目录与第一轮逐字相同');
  });

  test('一轮内一致：工具轮中途改文件 ⇒ 该轮第二次请求仍是装配时快照，下一轮才反映',
      () async {
    writeSkill('alpha-skill', 'A 的旧描述');
    final agent = await buildAgent('s3');

    sidecar.stubReadFile(
        '{"ok":true,"content":"file body","total_lines":1,"start_line":1,"end_line":1}');
    // 这一轮两次模型请求：第一次返回一个 read_file 工具调用，第二次给最终回复。
    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'read-1',
      'name': 'read_file',
      'input': {'path': 'E:/workspace/a.txt'},
    }));
    sidecar.queueDone(stopReason: 'tool_use');
    sidecar.queueDone(stopReason: 'end_turn');

    // 两道闸门：第一次请求、同一轮的第二次请求各卡一道，用例好在两者之间改盘。
    sidecar.gateNextSend();
    sidecar.gateNextSend();

    final turn = agent.send('走一次工具轮');
    await _waitUntil(() => sidecar.sendHandles.length == 1, '第一次模型请求发出');
    final prompt1 = sidecar.requests.single.systemPrompt;
    // ignore: avoid_print
    print('[热更] 一轮内：第一请求目录行=${skillLines(prompt1)}（已装配，闸门卡住）');
    expect(skillLines(prompt1), ['- alpha-skill: A 的旧描述']);

    // **轮内**改盘：这是"该轮工具还在执行时用户改了 SKILL.md"的现场。
    // 与第一条用例同样的理由：新 description 比旧的长（size 变了），这样"下一轮
    // 反映"才不依赖 platform 的 mtime 精度（Windows 上 Dart 的 FileStat.modified
    // 只有整秒）。
    writeSkill('alpha-skill', 'A 的新描述（轮内改的）');
    // ignore: avoid_print
    print('[热更] 一轮内：已把磁盘改成新描述，放行第一次请求');

    sidecar.releaseGate();
    await _waitUntil(() => sidecar.sendHandles.length == 2, '同一轮的第二次模型请求发出');
    final prompt2 = sidecar.requests.last.systemPrompt;
    // ignore: avoid_print
    print('[热更] 一轮内：第二请求目录行=${skillLines(prompt2)} '
        '（磁盘已是新描述，但本轮装配快照不变）');
    expect(prompt2, contains('\n- alpha-skill: A 的旧描述'),
        reason: '一轮内视图一致：装配之后的中途改动本轮不反映（design D2）');
    expect(prompt2, isNot(contains('A 的新描述')));

    sidecar.releaseGate();
    await turn;
    expect(sidecar.sendHandles.length, 2, reason: '整轮只有这两次模型请求');

    // 下一轮装配才反映 —— 证明上面那条不是"永远不刷新"。
    queueTurn(chunk: '第三轮回复');
    await agent.send('下一轮');
    final prompt3 = sidecar.requests.last.systemPrompt;
    // ignore: avoid_print
    print('[热更] 下一轮：目录行=${skillLines(prompt3)}');
    expect(prompt3, contains('\n- alpha-skill: A 的新描述（轮内改的）'));
    expect(prompt3, isNot(contains('A 的旧描述')));
  });
}
