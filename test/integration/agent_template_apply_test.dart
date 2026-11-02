import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/ui/agent_template_menu.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 模板保存 → 注册表 → 之后创建 / 恢复的实例（change `add-agent-object-and-templates`
/// 任务 3.3）。
///
/// 固定的是：保存后新实例用新配置、既有实例一个字段都不变；保存写回完整配置；
/// 界面菜单真的接到控制器与注册表，并明确说明生效时机。
void main() {
  const baseJson = {
    'version': 1,
    'providers': {
      'anthropic': {'api_key': 'sk-ant-keep', 'base_url': 'https://api.anthropic.com'},
      'deepseek': {'api_key': 'sk-ds-keep', 'base_url': 'https://api.deepseek.com'},
    },
    'search': {
      'deepseek': {'enabled': true, 'k': 4},
    },
    'spill': {'preview_chars': 1234},
    'agent_types': {
      'general': {
        'provider': 'anthropic',
        'model': 'old-model',
        'system_prompt': '老提示词',
        'tools': ['read_file'],
        'thinking_effort': 'high',
        'max_context_tokens': 200000,
        'compaction_threshold_percent': 40,
        'compaction_wait_threshold_percent': 80,
        'input_modalities': ['text', 'image'],
        'command_timeout_ms': 15000,
        'command_max_timeout_ms': 45000,
        'standing_requirements': ['不许删除用户文件'],
      },
      'reviewer': {
        'provider': 'deepseek',
        'model': 'deepseek-v4',
        'system_prompt': '评审',
        'tools': ['read_file'],
        'max_context_tokens': 64000,
      },
    },
  };

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

  late Directory tempDir;
  late String configPath;
  late AppConfig config;
  late AgentTypeRegistry templates;
  late FakeSidecar sidecar;
  late AgentRegistry agents;
  late AgentTemplateController controller;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('template_apply_');
    configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    File(configPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(baseJson));
    config = ConfigService.load(configPath: configPath).config!;
    templates = AgentTypeRegistry();
    for (final t in config.agentTypes.values) {
      templates.register(t);
    }
    resolver = ProviderResolver(config);
    sidecar = FakeSidecar();
    agents = AgentRegistry();
    ToolCatalog.instance.seed({
      for (final n in ['read_file', 'write_file', 'run_command', 'list_dir'])
        n: def(n),
    });
    controller = AgentTemplateController(
      registry: templates,
      config: config,
      configPath: configPath,
      knownTools: () => ToolCatalog.instance.nameSet,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  AgentFactory factory() {
    final factory = AgentFactory(
      templates: templates,
      providerResolver: () => resolver,
      config: config,
      sidecar: sidecar,
      sessionRepo: FakeSessionRepository([]),
      messageRepo: FakeMessageRepository(),
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
    return factory;
  }

  test('保存后新实例用新配置；运行中的实例保持旧配置；完整配置可读回', () async {
    final f = factory();
    final running = await f.create(session('s1'));
    final before = running.config;
    sidecar.queueChunk('旧回复');
    sidecar.queueDone();
    await running.send('改之前');

    controller.save(const AgentTemplateDraft(
      originalName: 'general',
      name: 'general',
      provider: 'anthropic',
      model: 'new-model',
      thinkingEffort: 'low',
      systemPrompt: '新提示词',
      tools: ['read_file', 'write_file'],
      maxContextTokensText: '300000',
    ));

    // 1）运行中的实例一个字段都不许变。
    expect(running.config.model, 'old-model');
    expect(running.config.thinkingMode, 'adaptive');
    expect(running.config.thinkingEffort, 'high');
    expect(running.config.maxContextTokens, 200000);
    expect(running.config.inputModalities, ['text', 'image']);
    expect(running.config.commandTimeoutMs, 15000);
    expect(running.config.commandMaxTimeoutMs, 45000);
    expect(running.config.standingRequirements, ['不许删除用户文件']);
    expect(running.config.compactionThresholdPercent, 40);
    expect(identical(running.config, before), isTrue,
        reason: '生效配置是不可变对象，保存模板不许替换运行实例持用的那一份');

    sidecar.queueChunk('旧模型回复');
    sidecar.queueDone();
    await running.send('改之后');
    expect(sidecar.lastModel, 'old-model',
        reason: '运行中的实例继续用创建时的模型，保存不是热更新');
    expect(sidecar.lastThinkingEffort, 'high');

    // 2）之后创建的实例用新配置，未编辑字段仍保留原值。
    final later = await f.create(session('s2'));
    // ignore: avoid_print
    print('  [OBS] 保存后新实例：model=${later.config.model} '
        'effort=${later.config.thinkingEffort} window=${later.config.maxContextTokens} '
        'modalities=${later.config.inputModalities} '
        'timeout=${later.config.commandTimeoutMs}/${later.config.commandMaxTimeoutMs} '
        'standing=${later.config.standingRequirements} '
        'compaction=${later.config.compactionThresholdPercent}/'
        '${later.config.compactionWaitThresholdPercent}');
    expect(later.config.model, 'new-model');
    expect(later.config.thinkingEffort, 'low');
    expect(later.config.maxContextTokens, 300000);
    expect(later.config.systemPrompt, '新提示词');
    expect(later.config.tools, ['read_file', 'write_file']);
    expect(later.config.inputModalities, ['text', 'image'],
        reason: '未开放编辑的字段不许复位');
    expect(later.config.commandTimeoutMs, 15000);
    expect(later.config.standingRequirements, ['不许删除用户文件']);
    expect(later.config.compactionThresholdPercent, 40);

    sidecar.queueChunk('新模型回复');
    sidecar.queueDone();
    await later.send('新实例');
    expect(sidecar.lastModel, 'new-model');

    // 3）模板注册表更新了，运行实例没有混进去。
    expect(templates.lookup('general')!.model, 'new-model');
    expect(templates.lookup('general')!.inputModalities, ['text', 'image']);
    expect(templates.listNames().toSet(), {'general', 'reviewer'},
        reason: '注册表只装模板，不许出现运行实例的会话 id');

    // 4）完整配置可读回：providers / search / spill / 其它模板不变。
    final raw = jsonDecode(File(configPath).readAsStringSync())
        as Map<String, dynamic>;
    final reread = ConfigService.load(configPath: configPath).config!;
    // ignore: avoid_print
    print('  [OBS] 读回配置：providers=${reread.providers.keys.toList()} '
        'search=${reread.search} spill=${reread.spillPreviewChars} '
        'general.model=${reread.agentTypes['general']!.model} '
        'reviewer.model=${reread.agentTypes['reviewer']!.model}');
    expect((raw['providers'] as Map).keys.toSet(), {'anthropic', 'deepseek'});
    expect(reread.search, {
      'deepseek': {'enabled': true, 'k': 4},
    });
    expect(reread.spillPreviewChars, 1234);
    expect(reread.providers['anthropic']!.apiKey, 'sk-ant-keep');
    expect(reread.agentTypes['reviewer']!.model, 'deepseek-v4');
    expect(reread.agentTypes['general']!.model, 'new-model');
    expect(reread.agentTypes['general']!.inputModalities, ['text', 'image']);
  });

  testWidgets('界面：侧栏 Agents → 菜单 → 添加模板 → 保存写回配置与注册表', (tester) async {
    // 界面里的模板注册表用全局 `registry`（ChatScreen 从这里读）。
    registry.clear();
    for (final t in templates.list()) {
      registry.register(t);
    }
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sessionRepo = FakeSessionRepository([session('s-ui')]);
    // 界面里的模板注册表与保存控制器必须是**同一个**对象（生产就是这样：
    // ChatScreen 默认用全局 registry 创建 controller）。这里注入的 controller
    // 也绑定到它，否则测的就不是产品接线。
    final uiController = AgentTemplateController(
      registry: registry,
      config: config,
      configPath: configPath,
      knownTools: () => ToolCatalog.instance.nameSet,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: config,
          sessionRepo: sessionRepo,
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
          summaryProvider: FakeSummaryProvider(),
          backgroundFoldEnabled: false,
          agentTemplateController: uiController,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // 侧栏的 Agents 入口。
    expect(find.text('Agents'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agents-entry')));
    await tester.pumpAndSettle();
    expect(find.text('general'), findsWidgets);
    expect(find.text('reviewer'), findsWidgets);
    expect(find.text(kAgentTemplateEffectiveNote), findsOneWidget,
        reason: '菜单必须明确说明生效时机');
    // ignore: avoid_print
    print('  [OBS] 菜单文本：${find.textContaining('模型：').evaluate().length} 行模型说明；'
        '含生效时机说明=1');

    // 添加一个新模板并保存。
    await tester.tap(find.byKey(const ValueKey('add-template')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('template-name')), 'writer');
    await tester.enterText(
        find.byKey(const ValueKey('template-model')), 'deepseek-v4');
    await tester.enterText(
        find.byKey(const ValueKey('template-window')), '640000');
    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();

    // 注册表与配置文件都更新了。
    // ignore: avoid_print
    print('  [OBS] 保存后注册表=${registry.listNames()}；'
        'SnackBar=${find.textContaining('之后创建或恢复的实例').evaluate().length} 处；'
        '配置文件含 writer=${File(configPath).readAsStringSync().contains('"writer"')}');
    expect(registry.listNames().toSet(), {'general', 'reviewer', 'writer'});
    final fileText = File(configPath).readAsStringSync();
    expect(fileText, contains('"writer"'));
    expect(fileText, contains('sk-ant-keep'), reason: '其它 provider 配置不许丢');
    expect(fileText, contains('"preview_chars": 1234'));
    expect(find.textContaining('之后创建或恢复的实例'), findsOneWidget,
        reason: '保存成功后要明确告诉用户：运行中的实例不会被热更新');

    // 重新打开菜单：新模板出现在列表里。
    await tester.tap(find.byKey(const ValueKey('agents-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-template-writer')), findsOneWidget);
    // ignore: avoid_print
    print('  [OBS] 重新打开菜单后 writer 行=${find.byKey(const ValueKey('agent-template-writer')).evaluate().length}');
  });
}
