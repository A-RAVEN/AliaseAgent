import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/config_service.dart';

/// 模板保存路径（change `add-agent-object-and-templates` 任务 1.2）。
///
/// 固定的是"保存 = 校验 + 在现有配置上换掉模板 + 写回完整配置 + 更新模板注册表"，
/// 而 providers / search / spill / 其它模板 / 模板内未开放编辑字段一个都不许丢。
void main() {
  late Directory tempDir;
  late String configPath;
  late AppConfig config;
  late AgentTypeRegistry registry;
  late AgentTemplateController controller;

  const knownTools = {'read_file', 'list_dir', 'write_file', 'edit_file'};

  Map<String, dynamic> baseJson() => {
        'version': 1,
        'providers': {
          'anthropic': {
            'api_key': 'sk-ant-secret',
            'base_url': 'https://api.anthropic.com',
          },
          'deepseek': {
            'api_key': 'sk-ds-secret',
            'base_url': 'https://api.deepseek.com',
          },
        },
        'search': {
          'deepseek': {'enabled': true, 'k': 3},
        },
        'spill': {'preview_chars': 1234},
        'agent_types': {
          'general': {
            'provider': 'anthropic',
            'model': 'claude-sonnet-4-6',
            'system_prompt': '你是助手',
            'tools': ['read_file', 'write_file'],
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
            'system_prompt': '你是评审',
            'tools': ['read_file'],
            'max_context_tokens': 128000,
            'input_modalities': ['text'],
          },
        },
      };

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('agent_template_test_');
    configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    File(configPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(baseJson()));
    final loaded = ConfigService.load(configPath: configPath);
    expect(loaded.status, ConfigStatus.ok);
    config = loaded.config!;
    registry = AgentTypeRegistry();
    config.agentTypes.values.forEach(registry.register);
    controller = AgentTemplateController(
      registry: registry,
      config: config,
      configPath: configPath,
      knownTools: () => knownTools,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  AgentTemplateDraft draft({
    String? originalName,
    String name = 'writer',
    String provider = 'deepseek',
    String model = 'deepseek-v4',
    String effort = 'max',
    String prompt = '你是写作者',
    List<String> tools = const ['read_file', 'write_file'],
    String window = '640000',
  }) =>
      AgentTemplateDraft(
        originalName: originalName,
        name: name,
        provider: provider,
        model: model,
        thinkingEffort: effort,
        systemPrompt: prompt,
        tools: tools,
        maxContextTokensText: window,
      );

  Map<String, dynamic> reread() {
    final text = File(configPath).readAsStringSync();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  test('添加模板：写回完整配置，providers/search/spill/其它模板原样保留', () {
    final result = controller.save(draft());
    final raw = reread();

    // ignore: avoid_print
    print('  [OBS] 添加后注册表=${registry.listNames()} '
        '配置里的模板=${(raw['agent_types'] as Map).keys.toList()} '
        'spill=${raw['spill']} search=${raw['search']} '
        'providers=${(raw['providers'] as Map).keys.toList()}');

    expect(result.created, isTrue);
    expect(registry.lookup('writer')?.model, 'deepseek-v4');
    expect((raw['providers'] as Map).keys.toSet(), {'anthropic', 'deepseek'});
    expect(raw['search'], baseJson()['search']);
    expect(raw['spill'], {'preview_chars': 1234});
    expect((raw['agent_types'] as Map).keys.toSet(),
        {'general', 'reviewer', 'writer'});
    // 新模板未开放编辑的字段沿用 general 的当前取值，而不是产品缺省值。
    final writer = (raw['agent_types'] as Map)['writer'] as Map;
    // ignore: avoid_print
    print('  [OBS] 新模板未编辑字段：input_modalities=${writer['input_modalities']} '
        'command_timeout_ms=${writer['command_timeout_ms']} '
        'compaction_threshold_percent=${writer['compaction_threshold_percent']} '
        'standing_requirements=${writer['standing_requirements']}');
    expect(writer['input_modalities'], ['text', 'image']);
    expect(writer['command_timeout_ms'], 15000);
    expect(writer['compaction_threshold_percent'], 40);
    expect(writer['standing_requirements'], ['不许删除用户文件']);
  });

  test('修改模板：只有被编辑字段变化，其它字段与其它模板都不变', () {
    controller.save(draft(
      originalName: 'reviewer',
      name: 'reviewer',
      provider: 'deepseek',
      model: 'deepseek-v4-pro',
      effort: 'low',
      prompt: '你是新评审',
      tools: const ['read_file', 'list_dir'],
      window: '300000',
    ));
    final raw = reread();
    final types = raw['agent_types'] as Map;
    final reviewer = types['reviewer'] as Map;
    final general = types['general'] as Map;
    // ignore: avoid_print
    print('  [OBS] 修改后 reviewer=$reviewer');
    // ignore: avoid_print
    print('  [OBS] general 未被编辑字段：input_modalities=${general['input_modalities']} '
        'command_timeout_ms=${general['command_timeout_ms']} '
        'standing=${general['standing_requirements']}');

    expect(reviewer['model'], 'deepseek-v4-pro');
    expect(reviewer['system_prompt'], '你是新评审');
    expect(reviewer['tools'], ['read_file', 'list_dir']);
    expect(reviewer['max_context_tokens'], 300000);
    expect(reviewer['thinking_effort'], 'low');
    // reviewer 原来只有 text 模态，保存后仍保持原值（未开放编辑）。
    expect(reviewer['input_modalities'], ['text']);
    expect(reviewer['compaction_threshold_percent'], 25,
        reason: '未编辑的压缩参数必须沿用该模板自己的原值');
    expect(general, baseJson()['agent_types']['general']);
    expect((raw['providers'] as Map).keys.toSet(), {'anthropic', 'deepseek'});
  });

  group('保存前校验（失败不写坏配置、保留既有定义）', () {
    void expectRejected(AgentTemplateDraft d, String field, String messagePart) {
      final before = File(configPath).readAsStringSync();
      final beforeNames = registry.listNames();
      var message = '';
      try {
        controller.save(d);
        fail('这次保存必须被拒绝');
      } on AgentTemplateValidationException catch (e) {
        expect(e.field, field);
        message = e.message;
      }
      // ignore: avoid_print
      print('  [OBS] 拒绝字段=$field 消息=$message');
      expect(message, contains(messagePart));
      expect(File(configPath).readAsStringSync(), before,
          reason: '校验失败不许改动配置文件');
      expect(registry.listNames(), beforeNames);
    }

    test('空模板名', () {
      expectRejected(draft(name: '  '), '模板名', '不能为空');
    });

    test('空模型', () {
      expectRejected(draft(model: ' '), '模型', '不能为空');
    });

    test('重复模板名（不覆盖既有同名模板）', () {
      expectRejected(draft(name: 'general'), '模板名', '已存在');
      expect(registry.lookup('general')?.model, 'claude-sonnet-4-6');
    });

    test('未知 provider', () {
      expectRejected(draft(provider: 'nope'), 'provider', '未定义');
    });

    test('非法上下文窗口（零、负数、非整数）', () {
      for (final window in ['0', '-1', 'abc', '']) {
        expectRejected(draft(window: window), '上下文窗口', '正整数');
      }
    });

    test('未知工具名必须列出来，不许静默删除', () {
      expectRejected(
          draft(tools: const ['read_file', 'rm_rf']), '工具', 'rm_rf');
    });

    test('非法推理强度', () {
      expectRejected(draft(effort: 'turbo'), '推理强度', 'turbo');
    });

    test('修改时不允许改模板名', () {
      expectRejected(draft(originalName: 'reviewer', name: 'reviewer2'),
          '模板名', '创建后不可修改');
    });

    test('修改不存在的模板被拒绝', () {
      expectRejected(draft(originalName: 'ghost', name: 'ghost'),
          '模板名', '不存在');
    });
  });

  test('运行实例不会被当成模板：注册表只返回 AgentTypeConfig，且只含配置里的模板', () {
    controller.save(draft());
    final listed = registry.list();
    // ignore: avoid_print
    print('  [OBS] 注册表条目类型=${listed.map((t) => t.runtimeType).toSet()} '
        '名字=${listed.map((t) => t.name).toList()}');
    expect(registry.listNames().toSet(), {'general', 'reviewer', 'writer'});
  });
}
