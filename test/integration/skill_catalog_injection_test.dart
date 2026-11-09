// 技能目录注入与 `load_skill` 无条件交付的集成用例（change
// `add-skill-mechanism` 任务 3.3，FakeSidecar，无窗口、无网络、无真实 DLL）。
//
// 断言的是**真正发出去的请求**（`sidecar.lastSystemPrompt` / `lastToolsJson` 与
// `contextSnapshot`），不是内部变量：
//   ① 2 个生效技能 + 任一模板（清单里含 / 不含 `load_skill` 两种）⇒ systemPrompt
//      都含两行目录（字典序）与使用说明句，tools 数组都含 `load_skill` 定义；
//   ② 无生效技能 ⇒ systemPrompt 不含目录标题与 `- ` 清单行，但**含创建技能简则**
//      （返工 5.1 新口径，design D6），tools 仍含定义（工具常驻、简则常驻）；
//   ③ 模板清单已手写 `load_skill` 时 tools 数组里**恰出现一次**（去重）；
//   ④ 注入前后 `fixedOverheadTokens` 的差值 == 整段系统提示词估算的差值，且提示词
//      长度差恰为**两侧注入的 `promptSection` 全段长度之差**（有技能=清单+简则，
//      无技能=只有简则；返工 5.3 按新口径改写，仍是逐字等值、不放松为约等于）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/context_estimator.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

void main() {
  late FakeSidecar sidecar;
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

  Session session(String id, {String agentType = 'general'}) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: 1,
        updatedAt: 1,
      );

  void writeSkill(String dirName, String description) {
    final dir = Directory(
        '${skillsRoot.path}${Platform.pathSeparator}$dirName')
      ..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: $dirName\ndescription: $description\n---\n# 正文\n');
  }

  setUp(() {
    ToolCatalog.instance.seed({
      'read_file': def('read_file'),
      'write_file': def('write_file'),
      'run_command': def('run_command'),
      // 模板手写 `load_skill` 时需要目录里有它（否则创建期 UnknownToolsException）。
      kLoadSkillToolName: kLoadSkillToolDefinition,
    });
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: 'GENERAL-PROMPT',
      tools: ['read_file', 'write_file'],
      maxContextTokens: 100000,
    ));
    registry.register(const AgentTypeConfig(
      name: 'explicit',
      provider: 'test',
      model: 'explicit-model',
      systemPrompt: 'EXPLICIT-PROMPT',
      tools: ['read_file', 'load_skill'],
      maxContextTokens: 100000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-hidden', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar()..stubBrowserAvailable('{"ok":true,"available":false}');
    sidecar.stubSearchProviders('[]');
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
    skillsRoot = Directory.systemTemp.createTempSync('skill_injection_');
    // change `refresh-skill-catalog-each-turn`：`scan()` 每轮装配前都会调用（design
    // D2），生产调用不传 rootPath —— 用例把"缺省根"指到临时目录，每轮都落在同一份
    // 夹具上，不会去读用户主目录的真实技能目录。
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

  AgentFactory factory() => AgentFactory(
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

  List<String> sentToolNames(String toolsJson) => [
        for (final t in jsonDecode(toolsJson) as List<dynamic>)
          (t as Map<String, dynamic>)['name'] as String,
      ];

  test('有 2 个生效技能：任一模板都收到目录段与 load_skill（含/不含在手写清单两种）',
      () async {
    writeSkill('pdf-tools', '处理 PDF：拆分与合并');
    writeSkill('alpha-skill', 'A 开头的技能描述');
    await SkillCatalogService.instance.scan(rootPath: skillsRoot.path);

    // ---- 模板清单里没有 load_skill ----
    final f = factory();
    final withoutListing = await f.create(session('s1'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await withoutListing.send('你好');

    final prompt1 = sidecar.lastSystemPrompt ?? '';
    final names1 = sentToolNames(sidecar.lastToolsJson ?? '[]');
    // ignore: avoid_print
    print('[注入] 不含 load_skill 的模板 systemPrompt=\n$prompt1');
    // ignore: avoid_print
    print('[注入] 不含 load_skill 的模板 tools=$names1');

    expect(prompt1, contains(instructionPrefix));
    expect(prompt1, contains('\n- alpha-skill: A 开头的技能描述'));
    expect(prompt1, contains('\n- pdf-tools: 处理 PDF：拆分与合并'));
    expect(prompt1.indexOf('- alpha-skill:'), lessThan(prompt1.indexOf('- pdf-tools:')),
        reason: '目录按 name 字典序');
    expect(names1, contains(kLoadSkillToolName),
        reason: '模板没列它也必须交付（无条件）');
    expect(names1.where((n) => n == kLoadSkillToolName).length, 1);

    // ---- 模板清单里手写了 load_skill ----
    final explicit = await f.create(session('s2', agentType: 'explicit'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await explicit.send('你好');

    final prompt2 = sidecar.lastSystemPrompt ?? '';
    final names2 = sentToolNames(sidecar.lastToolsJson ?? '[]');
    // ignore: avoid_print
    print('[注入] 手写 load_skill 的模板 systemPrompt=\n$prompt2');
    // ignore: avoid_print
    print('[注入] 手写 load_skill 的模板 tools=$names2');
    expect(prompt2, contains(instructionPrefix));
    expect(prompt2, contains('\n- alpha-skill: A 开头的技能描述'));
    expect(prompt2, contains('\n- pdf-tools: 处理 PDF：拆分与合并'));
    expect(names2.where((n) => n == kLoadSkillToolName).length, 1,
        reason: '清单已含 load_skill 时不许重复追加（恰出现一次）');
    expect(names2, ['read_file', kLoadSkillToolName],
        reason: '保持 resolve 原顺序，追加项在尾部（此例已在清单里，故就在原位）');
  });

  test('无生效技能：systemPrompt 只注入创建简则（无标题无清单行），tools 仍含 load_skill',
      () async {
    await SkillCatalogService.instance.scan(
        rootPath: '${skillsRoot.path}${Platform.pathSeparator}not-created');
    expect(SkillCatalogService.instance.activeSkills, isEmpty);

    final f = factory();
    final agent = await f.create(session('s3'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await agent.send('你好');

    final prompt = sidecar.lastSystemPrompt ?? '';
    final names = sentToolNames(sidecar.lastToolsJson ?? '[]');
    // 这一轮装配后的技能段（同一次 scan 的结果，逐字断言用）。
    final section = SkillCatalogService.instance.promptSection;
    final listLines =
        section.split('\n').where((line) => line.startsWith('- ')).toList();
    // ignore: avoid_print
    print('[注入] 无技能 systemPrompt=\n$prompt');
    // ignore: avoid_print
    print('[注入] 无技能 tools=$names；技能段长度=${section.length}；'
        '段里的 `- ` 清单行=$listLines');

    // 返工 5.3 新口径（design D6）：没有生效技能时不再返回空段，改为**只注简则**。
    expect(section, isNotEmpty, reason: '空技能也要注创建简则（不再返回空串）');
    expect(prompt, contains(section), reason: '注入系统提示词的正是这段技能段（逐字）');
    expect(section, contains('.aliasagent/skills/'), reason: '简则写明技能目录位置');
    expect(section, contains('takes effect on your next message'),
        reason: '简则写明写好下一条消息生效');
    expect(listLines, isEmpty, reason: '没有生效技能时不许有 `- ` 清单行');

    // 不留空悬句子：目录标题仍不许出现（旧口径的负向断言保留、不放松）。
    expect(prompt, isNot(contains(instructionPrefix)));
    expect(prompt, isNot(contains('Available skills')));
    expect(names, contains(kLoadSkillToolName),
        reason: '工具常驻：目录段随内容，工具定义不随内容');
    expect(names, ['read_file', 'write_file', kLoadSkillToolName],
        reason: '追加在尾部，保 resolve 原顺序');
  });

  test('注入前后 fixedOverheadTokens 的差值与两段 promptSection 长度差一致', () async {
    writeSkill('pdf-tools', '处理 PDF：拆分与合并');
    writeSkill('alpha-skill', 'A 开头的技能描述');

    final f = factory();
    // ① 有技能
    await SkillCatalogService.instance.scan(rootPath: skillsRoot.path);
    final withSkills = await f.create(session('s4'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await withSkills.send('你好');
    final promptWith = sidecar.lastSystemPrompt ?? '';
    final fixedWith =
        withSkills.contextSnapshot!.breakdown!.fixedOverheadTokens;
    // 有技能时注入的全段 = 标题 + 清单 + 简则。
    final sectionWith = SkillCatalogService.instance.promptSection;

    // ② 同一份模板、技能清空
    // 注意（change `refresh-skill-catalog-each-turn`）：`scan()` 现在每轮装配前都会
    // 跑，单靠 `resetForTests()` 已经清不空——下一轮会按"缺省根"重新扫出这两个技能。
    // 所以这里把缺省根指到一个**不存在**的目录，真正摆出"没有技能目录"的现场。
    SkillCatalogService.instance.resetForTests();
    SkillCatalogService.instance.setRootForTests(
        '${skillsRoot.path}${Platform.pathSeparator}not-created');
    final withoutSkills = await f.create(session('s5'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await withoutSkills.send('你好');
    final promptWithout = sidecar.lastSystemPrompt ?? '';
    final fixedWithout =
        withoutSkills.contextSnapshot!.breakdown!.fixedOverheadTokens;
    // 无技能时注入的全段 = 只有创建简则（返工 5.1 新口径）。
    final sectionWithout = SkillCatalogService.instance.promptSection;

    final lengthDelta = promptWith.length - promptWithout.length;
    final estimateDeltaWith = ContextEstimator.estimateTokens(promptWith);
    final estimateDeltaWithout = ContextEstimator.estimateTokens(promptWithout);
    // ignore: avoid_print
    print('[注入] 有技能段=${sectionWith.length} 字符 / 无技能段=${sectionWithout.length} '
        '字符；提示词长度差=$lengthDelta；'
        '固定开销 有技能=$fixedWith / 无技能=$fixedWithout；'
        '整段估算 有=$estimateDeltaWith / 无=$estimateDeltaWithout');
    expect(sectionWith, isNotEmpty, reason: '有技能时注入清单+简则');
    expect(sectionWithout, isNotEmpty, reason: '无技能时注入只有简则的一段（不为空）');
    // 返工 5.3：期望从"目录文本长度 + 1"改为**两侧 promptSection 全段长度之差** ——
    // 现在两侧都注入了技能段（有技能=清单+简则，无技能=只有简则），提示词长度的差
    // 恰好是两段之间的差，仍是逐字等值（不放松为约等于）。
    expect(lengthDelta, sectionWith.length - sectionWithout.length,
        reason: '提示词长度差 == 两侧注入的 promptSection 全段长度之差（逐字等值）');
    expect(fixedWith - fixedWithout, estimateDeltaWith - estimateDeltaWithout,
        reason: '技能段的 token 必须计入 fixedOverheadTokens（现状按整段系统提示词估算）');
    expect(fixedWith, greaterThan(fixedWithout));
  });
}
