// 「配置零改动」的边界用例（change `add-skill-mechanism` 任务 6.3）。
//
// 钉三件事：
//   ① **上一版默认形状**（模板 tools == 当前 `ToolCatalog.kBaseToolNames` 的 11 项）
//      加载后清单不变、且**不含** `load_skill`；
//   ② **旧两项形状**（`read_file` + `list_dir`）仍按既有 `ToolListMigration` 升到
//      11 项基础清单 —— 不升到 12，也就是迁移不会把 `load_skill` 写进配置；
//   ③ 同一模板的一轮请求 tools 数组**含** `load_skill`（装配层无条件追加，与配置
//      内容无关），且配置对象本身没有被这次请求改写。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../integration/helpers/fake_sidecar.dart';
import '../widget/helpers/fakes.dart';

void main() {
  late FakeSidecar sidecar;
  late AgentRegistry agents;

  Session session(String id) => Session(
        id: id,
        title: 'Session $id',
        agentType: 'general',
        createdAt: 1,
        updatedAt: 1,
      );

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  setUp(() {
    sidecar = FakeSidecar();
    agents = AgentRegistry();
    registry.clear();
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
    SkillCatalogService.instance.resetForTests();
  });

  test('上一版 11 项默认形状：加载后清单不变、不含 load_skill', () {
    final config = AppConfig(
      version: 1,
      providers: const {},
      agentTypes: {
        'general': AgentTypeConfig(
          name: 'general',
          provider: 'test',
          model: 'm',
          systemPrompt: '',
          tools: List<String>.unmodifiable(ToolCatalog.kBaseToolNames),
          maxContextTokens: 100000,
        ),
      },
    );
    final migrated = ToolListMigration.migrate(config);
    final tools = migrated.config.agentTypes['general']!.tools;
    // ignore: avoid_print
    print('[零配置] 11 项形状：migrated=${migrated.migratedTemplates} '
        'tools=${tools.length} 含 load_skill=${tools.contains('load_skill')}');
    expect(migrated.migratedTemplates, isEmpty, reason: '11 项不是旧默认形状，不许迁移');
    expect(tools, ToolCatalog.kBaseToolNames);
    expect(tools.length, 11);
    expect(tools, isNot(contains(kLoadSkillToolName)));
  });

  test('旧两项形状：按既有迁移升到 11 项基础清单，不升到 12', () {
    final config = AppConfig(
      version: 1,
      providers: const {},
      agentTypes: {
        'general': const AgentTypeConfig(
          name: 'general',
          provider: 'test',
          model: 'm',
          systemPrompt: '',
          tools: ['read_file', 'list_dir'],
          maxContextTokens: 100000,
        ),
      },
    );
    final migrated = ToolListMigration.migrate(config);
    final tools = migrated.config.agentTypes['general']!.tools;
    // ignore: avoid_print
    print('[零配置] 旧两项：migrated=${migrated.migratedTemplates} '
        'tools=${tools.length} 含 load_skill=${tools.contains('load_skill')}');
    expect(migrated.migratedTemplates, ['general']);
    expect(tools, ToolCatalog.kBaseToolNames);
    expect(tools.length, 11, reason: '迁移目标仍是 11 项，不因为 load_skill 变 12');
    expect(tools, isNot(contains(kLoadSkillToolName)),
        reason: '配置里永远不写 load_skill（它在装配层无条件交付）');
    expect(migrated.notices.single, contains('11'));
  });

  test('同一模板的一轮请求 tools 含 load_skill，且配置对象没有被改写', () async {
    registry.register(AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: '',
      tools: List<String>.unmodifiable(ToolCatalog.kBaseToolNames),
      maxContextTokens: 100000,
    ));
    ToolCatalog.instance.seed({
      for (final name in ToolCatalog.kBaseToolNames) name: def(name),
    });

    final factory = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: FakeSessionRepository([]),
      messageRepo: FakeMessageRepository(),
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
    final agent = await factory.create(session('s1'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await agent.send('你好');

    final names = [
      for (final t in jsonDecode(sidecar.lastToolsJson ?? '[]') as List<dynamic>)
        (t as Map<String, dynamic>)['name'] as String,
    ];
    // ignore: avoid_print
    print('[零配置] 一轮请求 tools（${names.length} 个）=$names');
    expect(names, contains(kLoadSkillToolName),
        reason: '装配层无条件追加，与模板清单无关');
    expect(names.length, 12, reason: '11 项模板工具 + 追加的 load_skill');
    expect(agent.config.tools.length, 11,
        reason: '请求多一项不等于配置被改写');
    expect(agent.config.tools, isNot(contains(kLoadSkillToolName)));
    expect(registry.lookup('general')!.tools, isNot(contains(kLoadSkillToolName)));
  });
}
