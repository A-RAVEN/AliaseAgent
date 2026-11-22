// 成员 / 会话级覆盖层（change `agent-group-chat`，新能力 `agent-instance-overrides`）。
//
// 覆盖层是**模板之上的一层**：v1 只有三个字段，全部是"收紧或追加"，不开放替换。
//
// **空值三态（钉死，三者互不等价）**：
//   字段缺席 / JSON null  → 无覆盖（沿用模板解析结果）
//   工具子集显式 []       → 合法的零工具子集（交集语义下生效工具为空）
//   思考强度显式 ""       → 关闭思考（既有语义：显式非白名单值 ⇒ disabled）
// 所以三个字段的"存在性"必须单独保存，不能靠"值是否为 null / 空"推断。
//
// 这一层与模板的关系：模板仍是预设（`AgentTypeConfig`），覆盖层只存在于
// 成员行 / 会话行的 `overrides_json` 里，**不改模板、不加 config.json 键**。
import 'dart:convert';

import '../services/agent_config_resolver.dart';
import '../services/logging.dart';
import 'agent_type_config.dart';
import 'resolved_agent_config.dart';

/// 覆盖层校验失败：**可归因**（字段 + 具体原因 + 拒绝的名字），绝不静默忽略。
class AgentOverridesException implements Exception {
  const AgentOverridesException(this.field, this.message);

  /// 出错的字段（`toolsSubset` / `systemPromptAppend` / `thinkingEffort` / 字段名）。
  final String field;
  final String message;

  @override
  String toString() => '覆盖层字段 "$field" 被拒绝：$message';
}

/// 覆盖层里**不允许**出现的字段（只做收紧与追加，不做替换）。
///
/// 每一种写法都登记：用户/界面可能用驼峰或下划线，两种都要能点名拒绝，
/// 否则"静默忽略一个 model 覆盖"会让用户以为换了模型。
const Set<String> kForbiddenOverrideFields = {
  'model',
  'provider',
  'maxContextTokens',
  'max_context_tokens',
  'systemPrompt',
  'system_prompt',
  'inputModalities',
  'input_modalities',
  'compactionThresholdPercent',
  'compaction_threshold_percent',
};

/// 三个字段的 JSON 键名（**唯一来源**：文档守卫与测试都读这些常量）。
const String kOverrideToolsSubsetKey = 'toolsSubset';
const String kOverrideSystemPromptAppendKey = 'systemPromptAppend';
const String kOverrideThinkingEffortKey = 'thinkingEffort';

/// 一个实例（成员或会话）的覆盖层。
class AgentInstanceOverrides {
  const AgentInstanceOverrides._({
    required this.hasToolsSubset,
    required this.toolsSubset,
    required this.hasSystemPromptAppend,
    required this.systemPromptAppend,
    required this.hasThinkingEffort,
    required this.thinkingEffort,
  });

  /// "没有覆盖"（三字段都缺席）。与"显式空覆盖"不同：这里三者的 has* 都是 false。
  static const AgentInstanceOverrides none = AgentInstanceOverrides._(
    hasToolsSubset: false,
    toolsSubset: null,
    hasSystemPromptAppend: false,
    systemPromptAppend: null,
    hasThinkingEffort: false,
    thinkingEffort: null,
  );

  /// 工具子集字段是否**出现**（出现即表示"以子集为准"，包括空列表）。
  final bool hasToolsSubset;

  /// 工具子集；[hasToolsSubset] 为 false 时是 null（无覆盖）。
  final List<String>? toolsSubset;

  /// 提示词追加字段是否出现。
  final bool hasSystemPromptAppend;

  /// 提示词追加段；为空串时等价于"没有追加内容"（append 语义，不产生空行）。
  final String? systemPromptAppend;

  /// 思考强度字段是否出现。
  final bool hasThinkingEffort;

  /// 思考强度；空串表示"关闭思考"（不是无覆盖）。
  final String? thinkingEffort;

  bool get isEmpty =>
      !hasToolsSubset && !hasSystemPromptAppend && !hasThinkingEffort;

  /// 从 JSON 对象严格解析（保存路径）：未知的**替换类**字段显式拒绝。
  ///
  /// 非替换类的未知键忽略（向前兼容：以后加字段不会把旧客户端读挂），但
  /// `model` / 窗口 / provider / 系统提示词替换一律拒绝并点名。
  factory AgentInstanceOverrides.fromJson(Map<String, dynamic> json) {
    for (final key in json.keys) {
      if (kForbiddenOverrideFields.contains(key)) {
        throw AgentOverridesException(
          key,
          '覆盖层不开放替换字段（只允许收紧工具子集、追加提示词、改思考强度）：'
          '请删掉 "$key"',
        );
      }
    }

    var hasTools = false;
    List<String>? tools;
    if (json.containsKey(kOverrideToolsSubsetKey)) {
      final raw = json[kOverrideToolsSubsetKey];
      if (raw == null) {
        hasTools = false;
      } else {
        if (raw is! List || raw.any((item) => item is! String)) {
          throw const AgentOverridesException(
              kOverrideToolsSubsetKey, '必须是字符串数组（显式 [] 表示零工具）');
        }
        hasTools = true;
        tools = List<String>.unmodifiable(raw.cast<String>());
      }
    }

    var hasAppend = false;
    String? append;
    if (json.containsKey(kOverrideSystemPromptAppendKey)) {
      final raw = json[kOverrideSystemPromptAppendKey];
      if (raw == null) {
        hasAppend = false;
      } else {
        if (raw is! String) {
          throw const AgentOverridesException(
              kOverrideSystemPromptAppendKey, '必须是字符串（append 语义，不替换）');
        }
        hasAppend = true;
        append = raw;
      }
    }

    var hasEffort = false;
    String? effort;
    if (json.containsKey(kOverrideThinkingEffortKey)) {
      final raw = json[kOverrideThinkingEffortKey];
      if (raw == null) {
        hasEffort = false;
      } else {
        if (raw is! String) {
          throw const AgentOverridesException(
              kOverrideThinkingEffortKey, '必须是字符串（显式空串 = 关闭思考）');
        }
        hasEffort = true;
        effort = raw;
      }
    }

    return AgentInstanceOverrides._(
      hasToolsSubset: hasTools,
      toolsSubset: tools,
      hasSystemPromptAppend: hasAppend,
      systemPromptAppend: append,
      hasThinkingEffort: hasEffort,
      thinkingEffort: effort,
    );
  }

  /// 从落库的 `overrides_json` 文本解析。
  ///
  /// 语义：
  ///   - `null` / 空串 → "没有覆盖"；
  ///   - 合法 JSON 对象 → 严格解析（替换类字段被拒）；
  ///   - 坏 JSON / 不是对象 → 返回 null **并打一行日志**。读取路径不能因为一行坏
  ///     覆盖层就再也恢复不了会话；拒绝发生在保存路径（[fromJson]）。
  static AgentInstanceOverrides? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      debugPrint('[AliasAgent] overrides_json 不是合法 JSON（${e.runtimeType}）— 按无覆盖处理');
      return null;
    }
    if (decoded is! Map) {
      debugPrint('[AliasAgent] overrides_json 不是对象 — 按无覆盖处理');
      return null;
    }
    try {
      return AgentInstanceOverrides.fromJson(Map<String, dynamic>.from(decoded));
    } on AgentOverridesException catch (e) {
      debugPrint('[AliasAgent] overrides_json 解析失败：$e — 按无覆盖处理');
      return null;
    }
  }

  /// 序列化为落库 JSON（只写出现的字段，保留三态）。
  Map<String, dynamic> toJson() => {
        if (hasToolsSubset) kOverrideToolsSubsetKey: toolsSubset,
        if (hasSystemPromptAppend) kOverrideSystemPromptAppendKey: systemPromptAppend,
        if (hasThinkingEffort) kOverrideThinkingEffortKey: thinkingEffort,
      };

  /// 落库文本；"没有覆盖"写 NULL（不是 `{}`）。
  String? toJsonString() {
    if (isEmpty) return null;
    return jsonEncode(toJson());
  }

  /// 派生：替换工具子集（显式列表 / null = 移除覆盖）。
  AgentInstanceOverrides withToolsSubset(List<String>? subset) =>
      AgentInstanceOverrides._(
        hasToolsSubset: subset != null,
        toolsSubset: subset == null ? null : List<String>.unmodifiable(subset),
        hasSystemPromptAppend: hasSystemPromptAppend,
        systemPromptAppend: systemPromptAppend,
        hasThinkingEffort: hasThinkingEffort,
        thinkingEffort: thinkingEffort,
      );

  AgentInstanceOverrides withSystemPromptAppend(String? append) =>
      AgentInstanceOverrides._(
        hasToolsSubset: hasToolsSubset,
        toolsSubset: toolsSubset,
        hasSystemPromptAppend: append != null,
        systemPromptAppend: append,
        hasThinkingEffort: hasThinkingEffort,
        thinkingEffort: thinkingEffort,
      );

  AgentInstanceOverrides withThinkingEffort(String? value) =>
      AgentInstanceOverrides._(
        hasToolsSubset: hasToolsSubset,
        toolsSubset: toolsSubset,
        hasSystemPromptAppend: hasSystemPromptAppend,
        systemPromptAppend: systemPromptAppend,
        hasThinkingEffort: value != null,
        thinkingEffort: value,
      );

  @override
  String toString() => 'AgentInstanceOverrides(${toJson()})';

  // ---------------------------------------------------------------------------
  // 解析与校验（保存路径 + 创建/恢复路径共用同一实现）
  // ---------------------------------------------------------------------------

  /// 保存时校验（2.2 / 2.4）：工具子集只能取模板已有工具；思考强度按模板编辑器
  /// 的**同一判据**（白名单内接受、空串接受为关闭、非白名单拒绝并列档位）。
  ///
  /// [template] 是成员/会话当前模板；[knownTools] 是工具目录（未知名字与"超出模板"
  /// 分开报，两者都列出名字）。
  void validateForSave({
    required AgentTypeConfig template,
    required Set<String> knownTools,
  }) {
    if (hasToolsSubset) {
      final subset = toolsSubset ?? const <String>[];
      final duplicates = <String>{};
      final seen = <String>{};
      for (final name in subset) {
        if (name.trim().isEmpty) {
          throw const AgentOverridesException(
              kOverrideToolsSubsetKey, '工具名不能为空：拒绝保存');
        }
        if (!seen.add(name)) duplicates.add(name);
      }
      if (duplicates.isNotEmpty) {
        throw AgentOverridesException(
            kOverrideToolsSubsetKey, '工具名重复：${duplicates.join("、")}');
      }
      final unknown = [
        for (final name in subset)
          if (!knownTools.contains(name)) name,
      ];
      if (unknown.isNotEmpty) {
        throw AgentOverridesException(kOverrideToolsSubsetKey,
            '工具目录里没有：${unknown.join("、")}（不静默删掉）');
      }
      final outside = [
        for (final name in subset)
          if (!template.tools.contains(name)) name,
      ];
      if (outside.isNotEmpty) {
        throw AgentOverridesException(
            kOverrideToolsSubsetKey,
            '模板 "${template.name}" 没有这些工具：${outside.join("、")}'
            '（覆盖层只能在模板上收紧）');
      }
    }
    if (hasThinkingEffort) {
      final effort = thinkingEffort ?? '';
      if (effort.isNotEmpty &&
          !AgentConfigResolver.kThinkingEfforts.contains(effort)) {
        throw AgentOverridesException(
          kOverrideThinkingEffortKey,
          '不是合法档位："$effort"；合法档位：'
          '${AgentConfigResolver.kThinkingEfforts.join("、")}'
          '（空串表示关闭思考）',
        );
      }
    }
  }

  /// 生效工具清单 = 模板工具 ∩ 子集，顺序按模板（2.3）。
  ///
  /// 模板后来删掉子集里的工具 ⇒ 求交收紧并**留一行说明**（不能放回来）。
  List<String> effectiveTools(List<String> templateTools) {
    if (!hasToolsSubset) return List<String>.unmodifiable(templateTools);
    final subset = toolsSubset ?? const <String>[];
    final dropped = <String>[
      for (final name in subset)
        if (!templateTools.contains(name)) name,
    ];
    if (dropped.isNotEmpty) {
      debugPrint('[AliasAgent] 覆盖层的工具子集里有模板已不再提供的工具：'
          '${dropped.join("、")} — 求交后不再生效（覆盖层存储不改写，'
          '它们也不会以其它方式回来）');
    }
    return List<String>.unmodifiable([
      for (final name in templateTools)
        if (subset.contains(name)) name,
    ]);
  }

  /// 生效系统提示词 = 模板提示词 + 追加段（append 语义；空追加不产生空行）。
  String effectiveSystemPrompt(String templatePrompt) {
    if (!hasSystemPromptAppend) return templatePrompt;
    final append = systemPromptAppend ?? '';
    if (append.isEmpty) return templatePrompt;
    if (templatePrompt.isEmpty) return append;
    return '$templatePrompt\n$append';
  }

  /// 生效思考档：显式空串 / 非白名单 ⇒ disabled（既有语义，不回落模板推导）；
  /// 字段缺席 ⇒ [null]（由调用方按模板 + 目录推导）。
  ({String mode, String effort})? effectiveThinking() {
    if (!hasThinkingEffort) return null;
    final effort = thinkingEffort ?? '';
    if (AgentConfigResolver.kThinkingEfforts.contains(effort)) {
      return (mode: 'adaptive', effort: effort);
    }
    return (mode: 'disabled', effort: '');
  }

  /// 把覆盖层叠到模板解析结果上（创建/恢复路径的**唯一**入口，2.5）。
  ///
  /// **不**改窗口、模型、provider（模板级冻结）：只替换工具清单、系统提示词与
  /// 初始思考档。思考强度的逐轮热更新由 `Agent._resolveRoundThinking` 读覆盖层。
  ResolvedAgentConfig applyTo(ResolvedAgentConfig base) {
    final thinking = effectiveThinking();
    return base.copyWith(
      tools: effectiveTools(base.tools),
      systemPrompt: effectiveSystemPrompt(base.systemPrompt),
      thinking: thinking,
    );
  }

  /// 可观察的生效配置（`group.list` 的 `effective` 字段）。
  Map<String, dynamic> describeEffective({
    required List<String> templateTools,
    required String templatePrompt,
    required String templateThinkingMode,
    required String templateThinkingEffort,
    required String model,
    required int windowTokens,
  }) {
    final tools = effectiveTools(templateTools);
    final thinking = effectiveThinking() ??
        (mode: templateThinkingMode, effort: templateThinkingEffort);
    return {
      'tools': tools,
      'systemPrompt': effectiveSystemPrompt(templatePrompt),
      'thinkingMode': thinking.mode,
      'thinkingEffort': thinking.effort,
      'model': model,
      'maxContextTokens': windowTokens,
    };
  }
}
