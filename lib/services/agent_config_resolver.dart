import '../models/agent_type_config.dart';
import '../models/provider_config.dart';
import '../models/resolved_agent_config.dart';
import 'provider_resolver.dart';

/// 解析实例生效配置时发现的**可区分**错误。
///
/// 每一种都带模板名（必要时带 provider 名），因为用户唯一能行动的信息就是
/// "哪个模板的哪个字段错了"。这些错误在创建 Agent 时抛出，绝不被静默降级。
class AgentConfigException implements Exception {
  final String templateName;
  final String message;

  const AgentConfigException(this.templateName, this.message);

  @override
  String toString() => message;
}

/// 模板缺失（会话引用了未注册的模板名）。
class MissingAgentTemplateException extends AgentConfigException {
  final String requestedName;

  MissingAgentTemplateException(this.requestedName)
      : super(
          requestedName,
          'Agent 模板 "$requestedName" 不存在：拒绝创建实例，也不会退回 general',
        );
}

/// 上下文窗口缺失、为零或为负。
class InvalidAgentContextWindowException extends AgentConfigException {
  final int? value;

  InvalidAgentContextWindowException(String templateName, this.value)
      : super(
          templateName,
          'Agent 模板 "$templateName" 的 max_context_tokens 无效（$value）：'
          '必须是正整数。拒绝创建实例，不按 0 继续发送，也不会静默关闭压缩或改发全文。',
        );
}

/// 模板引用了未定义的 provider。
class MissingAgentProviderException extends AgentConfigException {
  final String providerName;

  MissingAgentProviderException(String templateName, this.providerName)
      : super(
          templateName,
          'Agent 模板 "$templateName" 引用的 provider "$providerName" 未定义：'
          '拒绝创建实例。',
        );
}

/// 从可复用模板解析出某个 Agent 实例不可变的生效配置。
///
/// 解析器只做**取值与校验**，不读配置文件、不写任何状态，所以同一份模板任何时候
/// 解析出来的结果都一样；唯一的外部依赖是 provider 引用表（由 [ProviderResolver] 持有）。
class AgentConfigResolver {
  final ProviderResolver providers;

  const AgentConfigResolver(this.providers);

  /// 合法推理强度集合。沿用当前执行路径原来写在 `lib/main.dart` 里的那一组，
  /// 不新增档位（档位是产品既有数字，不是我发明的）。
  static const Set<String> kThinkingEfforts = {
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  };

  /// 由 `thinking_effort` 推导推理模式：合法值 → `adaptive`，缺失或非法 → `disabled`。
  static String thinkingModeFor(String? effort) =>
      (effort != null && kThinkingEfforts.contains(effort))
          ? 'adaptive'
          : 'disabled';

  /// 生效推理强度：`disabled` 时是空串（与现有 `sendMessage` 的约定一致）。
  static String thinkingEffortFor(String? effort) =>
      thinkingModeFor(effort) == 'adaptive' ? effort! : '';

  /// 窗口是否合法：必须是严格正整数。
  static bool isValidWindow(int? value) => value != null && value > 0;

  /// 编辑模型时是否必须让用户当场确认窗口。
  ///
  /// 依据 design 决策 1：换模型意味着窗口值很可能不再适用，编辑器必须要求用户重新
  /// 确认；解析器仍会对每次创建独立校验，不依赖"上一次模型"这个不存在的输入。
  static bool windowConfirmationRequired({
    required String previousModel,
    required String nextModel,
  }) {
    final previous = previousModel.trim();
    final next = nextModel.trim();
    return next.isNotEmpty && next != previous;
  }

  /// 解析 [template] 的生效配置。
  ///
  /// [spillPreviewChars] 来自顶层 `spill.preview_chars`（不属于模板），因为命令工具
  /// 每次调用都要把它交给执行侧。窗口非法、provider 未定义都会抛出可区分错误，
  /// 并把模板名写进消息。
  ResolvedAgentConfig resolve({
    required AgentTypeConfig template,
    required int spillPreviewChars,
  }) {
    if (!isValidWindow(template.maxContextTokens)) {
      throw InvalidAgentContextWindowException(
          template.name, template.maxContextTokens);
    }
    final effort = template.thinkingEffort;
    // 非法强度不阻止创建：规范把它定义为"解析为 disabled"的一种解析结果，
    // 不是创建失败条件。回落由 thinkingModeFor / thinkingEffortFor 统一决定。
    return ResolvedAgentConfig(
      templateName: template.name,
      providerName: template.provider,
      model: template.model,
      thinkingMode: thinkingModeFor(effort),
      thinkingEffort: thinkingEffortFor(effort),
      systemPrompt: template.systemPrompt,
      tools: List<String>.unmodifiable(template.tools),
      maxContextTokens: template.maxContextTokens!,
      compactionThresholdPercent: template.compactionThresholdPercent,
      compactionWaitThresholdPercent: template.compactionWaitThresholdPercent,
      inputModalities: List<String>.unmodifiable(template.inputModalities),
      commandTimeoutMs: template.commandTimeoutMs,
      commandMaxTimeoutMs: template.commandMaxTimeoutMs,
      standingRequirements:
          List<String>.unmodifiable(template.standingRequirements),
      spillPreviewChars: spillPreviewChars,
    );
  }

  /// 取该实例要用的 provider（密钥只在这里作为执行依赖出现，不进入
  /// [ResolvedAgentConfig] 的可序列化快照）。
  ProviderConfig resolveProvider(ResolvedAgentConfig config) {
    final provider = providers.resolve(config.providerName);
    if (provider == null) {
      throw MissingAgentProviderException(
          config.templateName, config.providerName);
    }
    return provider;
  }
}
