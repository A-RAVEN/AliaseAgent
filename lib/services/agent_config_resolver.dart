import 'package:flutter/foundation.dart';

import '../models/agent_type_config.dart';
import '../models/model_catalog_entry.dart';
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

/// 生效上下文窗口无法确定（change `model-truth-from-gateway` D1）。
///
/// 语义已从"max_context_tokens 非法"扩展为"目录与覆盖都拿不到窗口"：目录里该模型
/// 没有正数 `context_window`，配置也没有正整数覆盖值。**不允许回落任何写死的窗口
/// 数字**——回落值就是隐性硬编码，正是这个 change 要消灭的东西。
class InvalidAgentContextWindowException extends AgentConfigException {
  final int? value;
  final String providerName;
  final String model;

  InvalidAgentContextWindowException(
    String templateName,
    this.value, {
    this.providerName = '',
    this.model = '',
  }) : super(
          templateName,
          'Agent 模板 "$templateName" 的上下文窗口无法确定：模型 "$model"'
          '${providerName.isEmpty ? "" : "（provider \"$providerName\"）"}的目录里没有'
          '正数 context_window${value == null ? "，配置里也没有 max_context_tokens 覆盖值" : "，配置里的 max_context_tokens=$value 也不是正整数"}。'
          '拒绝创建实例，不按 0 继续发送，也不会静默关闭压缩或改发全文，更不回落任何写死的窗口数字。'
          '两条出路：① 去 Providers 页探测 provider "$providerName" 的目录；'
          '② 在 agent_types.$templateName.max_context_tokens 写一个正整数覆盖。',
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
  ///
  /// 这是**只看显式键**的旧规则；缺键时按目录推导的新规则见 [resolveThinking]（D6）。
  static String thinkingModeFor(String? effort) =>
      (effort != null && kThinkingEfforts.contains(effort))
          ? 'adaptive'
          : 'disabled';

  /// 生效推理强度：`disabled` 时是空串（与现有 `sendMessage` 的约定一致）。
  static String thinkingEffortFor(String? effort) =>
      thinkingModeFor(effort) == 'adaptive' ? effort! : '';

  /// 目录档位按 [kThinkingEfforts] 顺序取**中间档**（D6）。
  ///
  /// 只吃 `none` 之外的合法档：`none` 是"关闭"，把 0 档当中间档会算出错误结论。
  /// 偶数档时取靠前的那个（可判定、不引入第二种规则）；一档就是它自己。
  static String? catalogMedianEffort(List<String>? reasoningEfforts) {
    if (reasoningEfforts == null || reasoningEfforts.isEmpty) return null;
    final ordered = <String>[
      for (final effort in kThinkingEfforts)
        if (reasoningEfforts.contains(effort)) effort,
    ];
    if (ordered.isEmpty) return null;
    return ordered[(ordered.length - 1) ~/ 2];
  }

  /// 思考模式与强度（D6 唯一口径）。
  ///
  /// 顺序钉死：显式白名单档 **永远优先**；缺键 ⇒ 目录 `reasoningEfforts` 的中间档；
  /// 空 / 全 `none` / 目录缺失（含 Provider 未探测）⇒ `disabled`（不变得更糟）。
  /// 显式但非法的值（例如 `"MAX"`、`""`）按既有语义解析成 `disabled`，**不**退回目录
  /// 推导——"缺键"与"写错了"是两件事，后者不该被静默修好。
  static ({String mode, String effort}) resolveThinking({
    required String? explicitEffort,
    required ModelCatalogEntry? entry,
  }) {
    if (explicitEffort != null) {
      return thinkingModeFor(explicitEffort) == 'adaptive'
          ? (mode: 'adaptive', effort: explicitEffort)
          : (mode: 'disabled', effort: '');
    }
    final derived = catalogMedianEffort(entry?.reasoningEfforts);
    return derived == null
        ? (mode: 'disabled', effort: '')
        : (mode: 'adaptive', effort: derived);
  }

  /// 窗口是否合法：必须是严格正整数。
  static bool isValidWindow(int? value) => value != null && value > 0;

  /// 目录里该模型的条目（Provider 未探测 / 目录无此模型 ⇒ null）。
  ///
  /// Provider 目录在运行时的唯一查询方式就是 [ProviderResolver]（它持有
  /// `ProviderConfig.models` 与 `discoveredAt`），所以解析器不需要第二个注入点。
  ModelCatalogEntry? catalogEntryFor({
    required String providerName,
    required String model,
  }) {
    final provider = providers.resolve(providerName);
    for (final entry in provider?.models ?? const <ModelCatalogEntry>[]) {
      if (entry.id == model) return entry;
    }
    return null;
  }

  /// 生效上下文窗口（D1 唯一口径，单点收拢）。
  ///
  /// 目录有正数 `context_window` ⇒ **一律以目录为准**（覆盖值被忽略并打一行日志
  /// 点名）；目录缺失 ⇒ 配置正整数覆盖；两者都没有 ⇒ 显式失败，**不回落任何数字**。
  static int resolveContextWindow({
    required String templateName,
    required String providerName,
    required String model,
    required int? overrideTokens,
    required ModelCatalogEntry? entry,
  }) {
    final catalogWindow = entry?.contextWindow;
    if (isValidWindow(catalogWindow)) {
      if (isValidWindow(overrideTokens) && overrideTokens != catalogWindow) {
        debugPrint('[AliasAgent] 模板 "$templateName" 的 max_context_tokens='
            '$overrideTokens 被忽略：模型 "$model" 在 provider "$providerName" 的'
            '目录窗口是 $catalogWindow（生效窗口一律以网关目录为准）');
      }
      return catalogWindow!;
    }
    if (isValidWindow(overrideTokens)) return overrideTokens!;
    throw InvalidAgentContextWindowException(
      templateName,
      overrideTokens,
      providerName: providerName,
      model: model,
    );
  }

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
  /// 每次调用都要把它交给执行侧。窗口按 D1 的目录/覆盖链解析、思考档按 D6 推导，
  /// 两者都在这一处收拢；provider 未定义会抛出可区分错误，并把模板名写进消息。
  ResolvedAgentConfig resolve({
    required AgentTypeConfig template,
    required int spillPreviewChars,
  }) {
    final entry = catalogEntryFor(
      providerName: template.provider,
      model: template.model,
    );
    final window = resolveContextWindow(
      templateName: template.name,
      providerName: template.provider,
      model: template.model,
      overrideTokens: template.maxContextTokens,
      entry: entry,
    );
    // 非法强度不阻止创建：规范把它定义为"解析为 disabled"的一种解析结果，
    // 不是创建失败条件。推导规则由 resolveThinking 统一决定。
    final thinking = resolveThinking(
      explicitEffort: template.thinkingEffort,
      entry: entry,
    );
    return ResolvedAgentConfig(
      templateName: template.name,
      providerName: template.provider,
      model: template.model,
      thinkingMode: thinking.mode,
      thinkingEffort: thinking.effort,
      systemPrompt: template.systemPrompt,
      tools: List<String>.unmodifiable(template.tools),
      maxContextTokens: window,
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
