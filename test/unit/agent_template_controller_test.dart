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
            // change `chat-bubbles-avatars`：general 带头像，用来验「新模板不继承头像」。
            'avatar_path': r'C:\tmp\general-avatar.png',
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
    String? avatar,
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
        avatarPath: avatar,
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

    test('非法上下文窗口（零、负数、非整数）仍被拒绝', () {
      for (final window in ['0', '-1', 'abc']) {
        expectRejected(draft(window: window), '上下文窗口', '正整数');
      }
    });

    // change `model-truth-from-gateway` 1.3（D1/D3）：窗口覆盖**不再是必填**。
    // 缺席 = 合法状态（生效窗口取网关目录值；目录也缺时创建阶段显式失败），
    // 所以保存必须成功，且写回的配置里**不出现**这个键。
    test('窗口留空：保存成功，且写回的配置不带 max_context_tokens 键', () {
      final result = controller.save(draft(window: ''));
      final raw = reread();
      final writer = (raw['agent_types'] as Map)['writer'] as Map;
      // ignore: avoid_print
      print('  [OBS] 留空窗口保存后：配置里含键=${writer.containsKey('max_context_tokens')} '
          'registered=${result.template.name} '
          'model.maxContextTokens=${result.template.maxContextTokens}');
      expect(writer.containsKey('max_context_tokens'), isFalse,
          reason: '缺席是合法状态：不许写回一个 0 或任何缺省窗口数字');
      expect(result.template.maxContextTokens, isNull);
      expect(registry.lookup('writer')?.maxContextTokens, isNull);
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

  group('模板头像三态（change `chat-bubbles-avatars` 2.5 / design D3）', () {
    /// 修改 general（它本来带 `avatar_path`）用的草稿；头像三态由参数决定。
    AgentTemplateDraft generalDraft({String? avatar}) => draft(
          originalName: 'general',
          name: 'general',
          provider: 'anthropic',
          model: 'claude-sonnet-4-6',
          effort: 'high',
          prompt: '你是助手',
          tools: const ['read_file', 'write_file'],
          window: '200000',
          avatar: avatar,
        );

    test('avatarPath=null（省略）⇒ 修改既有模板沿用原头像，不清空', () {
      controller.save(generalDraft());
      final raw = reread();
      final general = (raw['agent_types'] as Map)['general'] as Map;
      // ignore: avoid_print
      print('  [OBS] 省略头像保存后 general.avatar_path=${general['avatar_path']}');
      expect(general['avatar_path'], r'C:\tmp\general-avatar.png',
          reason: '省略 = 不改（MUST NOT 静默清空既有头像）');
    });

    test("avatarPath='' ⇒ 清除该键（写回里不再有 avatar_path）", () {
      controller.save(generalDraft(avatar: ''));
      final raw = reread();
      final general = (raw['agent_types'] as Map)['general'] as Map;
      // ignore: avoid_print
      print('  [OBS] 清除头像后 general=$general');
      expect(general.containsKey('avatar_path'), isFalse,
          reason: '清除 = 写回里不再有该键（不是写空串）');
      expect(registry.lookup('general')?.avatarPath, isNull);
    });

    test('avatarPath=非空字符串 ⇒ 设为该路径', () {
      const next = r'C:\tmp\new-avatar.png';
      controller.save(generalDraft(avatar: next));
      final raw = reread();
      final general = (raw['agent_types'] as Map)['general'] as Map;
      // ignore: avoid_print
      print('  [OBS] 设置头像后 general.avatar_path=${general['avatar_path']}');
      expect(general['avatar_path'], next);
      expect(registry.lookup('general')?.avatarPath, next);
    });

    test('新增模板省略头像 ⇒ 没有该键，且不继承 general 的头像', () {
      final result = controller.save(draft());
      final raw = reread();
      final writer = (raw['agent_types'] as Map)['writer'] as Map;
      // ignore: avoid_print
      print('  [OBS] 新模板头像：配置 hasKey=${writer.containsKey('avatar_path')} '
          '模型=${result.template.avatarPath} general=${registry.lookup('general')?.avatarPath}');
      expect(writer.containsKey('avatar_path'), isFalse,
          reason: '新模板省略头像 ⇒ 没有头像，不许沿用 general 的');
      expect(result.template.avatarPath, isNull);
      expect(registry.lookup('general')?.avatarPath, r'C:\tmp\general-avatar.png',
          reason: 'general 自己的头像不受影响');
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
