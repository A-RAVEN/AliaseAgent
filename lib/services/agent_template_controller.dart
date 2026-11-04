import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import 'agent_config_resolver.dart';
import 'agent_type_registry.dart';
import 'config_service.dart';

/// 模板编辑器提交的一份草稿。
///
/// 窗口用文本传进来（界面上就是一个输入框），因为"非整数"本身要作为一条可显示的
/// 校验错误，而不是在界面层被 `int.tryParse` 悄悄吞掉。
class AgentTemplateDraft {
  /// `null` 表示**添加**；非空表示修改该名字的既有模板。
  final String? originalName;

  final String name;
  final String provider;
  final String model;

  /// 空串表示推理已关闭；其余必须是 [AgentConfigResolver.kThinkingEfforts] 之一。
  final String thinkingEffort;

  final String systemPrompt;
  final List<String> tools;
  final String maxContextTokensText;

  /// 编辑器里勾选的输入模态。null = 旧调用方（未经过编辑器），沿用模板既有值。
  /// 取值只能是 `text` / `image`；目录里的 `video` 等由编辑器回填时剔除，不进这里。
  final List<String>? inputModalities;

  const AgentTemplateDraft({
    this.originalName,
    required this.name,
    required this.provider,
    required this.model,
    required this.thinkingEffort,
    required this.systemPrompt,
    required this.tools,
    required this.maxContextTokensText,
    this.inputModalities,
  });

  bool get isNew => originalName == null;
}

/// 模板保存成功后的结果（新的完整配置 + 注册后的模板）。
class AgentTemplateSaveResult {
  final AppConfig config;
  final AgentTypeConfig template;
  final bool created;

  const AgentTemplateSaveResult({
    required this.config,
    required this.template,
    required this.created,
  });
}

/// 模板字段校验失败。`field` 是用户能看懂的那一项名字，界面据此指出哪个输入框错了。
class AgentTemplateValidationException implements Exception {
  final String field;
  final String message;

  const AgentTemplateValidationException(this.field, this.message);

  @override
  String toString() => message;
}

/// 协调一次模板保存：校验 → 改 `AppConfig.agentTypes` → 写回完整配置 → 更新模板注册表。
///
/// 它**不管理运行中的 Agent**：保存只影响之后创建或恢复的实例（运行实例持有自己的
/// 不可变生效配置），所以这里没有任何热更新入口。
class AgentTemplateController {
  final AgentTypeRegistry registry;
  final Set<String> Function() knownTools;

  /// 保存写到哪份配置；`null` = 产品默认的 `~/.aliasagent/config.json`。
  /// 单元测试注入临时路径，避免碰用户的真实配置。
  final String? configPath;

  AppConfig _config;

  AgentTemplateController({
    required this.registry,
    required AppConfig config,
    required this.knownTools,
    this.configPath,
  }) : _config = config;

  AppConfig get config => _config;

  /// Providers 管理页改动配置后同步：下次打开模板编辑器时，provider 下拉与目录
  /// 必须来自新的配置，不能还拿着打开页面时的旧快照。
  void replaceConfig(AppConfig config) {
    _config = config;
  }

  /// 只校验，不落盘。编辑器在保存前调它，失败时保留用户输入。
  AgentTypeConfig validate(AgentTemplateDraft draft) {
    final name = draft.name.trim();
    if (name.isEmpty) {
      throw const AgentTemplateValidationException('模板名', '模板名不能为空');
    }
    final existing = registry.lookup(name);
    if (draft.isNew) {
      if (existing != null || _config.agentTypes.containsKey(name)) {
        throw AgentTemplateValidationException(
            '模板名', '模板名 "$name" 已存在：添加被拒绝，既有同名模板保持不变');
      }
    } else {
      if (draft.originalName!.trim() != name) {
        throw const AgentTemplateValidationException(
            '模板名', '模板名创建后不可修改：只允许在添加时确定');
      }
      if (existing == null || !_config.agentTypes.containsKey(name)) {
        throw AgentTemplateValidationException(
            '模板名', '模板 "$name" 不存在：修改被拒绝，不会新建同名模板');
      }
    }

    final model = draft.model.trim();
    if (model.isEmpty) {
      throw const AgentTemplateValidationException('模型', '模型不能为空');
    }

    final provider = draft.provider.trim();
    if (provider.isEmpty || !_config.providers.containsKey(provider)) {
      throw AgentTemplateValidationException(
          'provider', 'provider "$provider" 未定义：请从已配置的 provider 中选择');
    }

    final effort = draft.thinkingEffort.trim();
    if (effort.isNotEmpty &&
        !AgentConfigResolver.kThinkingEfforts.contains(effort)) {
      throw AgentTemplateValidationException(
          '推理强度',
          '推理强度 "$effort" 不合法：只能是 '
              '${AgentConfigResolver.kThinkingEfforts.join(" / ")} 或关闭');
    }

    final windowText = draft.maxContextTokensText.trim();
    final window = int.tryParse(windowText);
    if (window == null || window <= 0) {
      throw const AgentTemplateValidationException(
          '上下文窗口', '上下文窗口必须是正整数（当前输入不合法）');
    }

    final unknownTools = <String>[
      for (final t in draft.tools)
        if (!knownTools().contains(t)) t,
    ];
    if (unknownTools.isNotEmpty) {
      throw AgentTemplateValidationException(
          '工具', '未知工具：${unknownTools.join("、")}（不在工具目录中，不会被静默删除）');
    }

    // 未开放编辑的受支持字段：修改时原样保留；添加时沿用 general 的当前取值
    // （没有 general 就用 AgentTypeConfig 的缺省值），不拿一份新产品缺省配置覆盖。
    final base = draft.isNew
        ? (_config.agentTypes['general'])
        : existing;

    // 输入模态：编辑器传来的值必须仍只放行 text/image（目录里的 video 等
    // 在编辑器回填时就已经剔除并打日志，不会到这里）。未传时沿用 base。
    List<String> modalities;
    if (draft.inputModalities == null) {
      modalities = List<String>.from(
          base?.inputModalities ?? AgentTypeConfig.kDefaultInputModalities);
    } else {
      final illegal = [
        for (final m in draft.inputModalities!)
          if (!AgentTypeConfig.kAllowedInputModalities.contains(m)) m,
      ];
      if (illegal.isNotEmpty) {
        throw AgentTemplateValidationException(
            '输入模态',
            '输入模态只能是 '
                '${AgentTypeConfig.kAllowedInputModalities.join(" / ")}：'
                '不接受 ${illegal.join("、")}');
      }
      final unique = <String>[];
      for (final m in draft.inputModalities!) {
        if (!unique.contains(m)) unique.add(m);
      }
      modalities = unique.isEmpty
          ? List<String>.from(AgentTypeConfig.kDefaultInputModalities)
          : unique;
    }

    return AgentTypeConfig(
      name: name,
      provider: provider,
      model: model,
      systemPrompt: draft.systemPrompt,
      tools: List<String>.unmodifiable(draft.tools),
      thinkingEffort: effort.isEmpty ? null : effort,
      maxContextTokens: window,
      compactionThresholdPercent: base?.compactionThresholdPercent ??
          AgentTypeConfig.kDefaultCompactionThresholdPercent,
      compactionWaitThresholdPercent: base?.compactionWaitThresholdPercent ??
          AgentTypeConfig.kDefaultCompactionWaitThresholdPercent,
      inputModalities: List<String>.unmodifiable(modalities),
      commandTimeoutMs:
          base?.commandTimeoutMs ?? AgentTypeConfig.kDefaultCommandTimeoutMs,
      commandMaxTimeoutMs: base?.commandMaxTimeoutMs ??
          AgentTypeConfig.kDefaultCommandMaxTimeoutMs,
      standingRequirements: base?.standingRequirements ?? const [],
    );
  }

  /// 校验并保存。写回的是**完整** `AppConfig`（providers / search / spill / 其它模板
  /// 全部原样保留），然后才更新内存注册表 —— 写盘失败时注册表也不会先变。
  AgentTemplateSaveResult save(AgentTemplateDraft draft) {
    final template = validate(draft);
    final types = Map<String, AgentTypeConfig>.from(_config.agentTypes)
      ..[template.name] = template;
    final next = _config.copyWith(agentTypes: types);
    ConfigService.save(next, configPath: configPath);
    if (draft.isNew) {
      registry.add(template);
    } else {
      registry.update(template);
    }
    _config = next;
    return AgentTemplateSaveResult(
      config: next,
      template: template,
      created: draft.isNew,
    );
  }
}
