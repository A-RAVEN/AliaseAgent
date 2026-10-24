import 'package:flutter/foundation.dart';

class AgentTypeConfig {
  final String name;
  final String provider;
  final String model;
  final String systemPrompt;
  final List<String> tools;
  final String? thinkingEffort;
  final int? maxContextTokens;

  /// The percentage of the model's context window that forms the compaction
  /// threshold (config key `compaction_threshold_percent`).
  ///
  /// The threshold is always DERIVED: `maxContextTokens × this ÷ 100`. There is
  /// deliberately no absolute token number anywhere in the mechanism — the user
  /// pinned that rule (see `TODO.md`, the locked original requirement). Default
  /// 25 (100 万 token 的窗口 ⇒ 25 万 token 的阈值).
  final int compactionThresholdPercent;

  /// The share of the model's context window above which a user turn WAITS for
  /// compaction (config key `compaction_wait_threshold_percent`, user request
  /// 2026-10-02).
  ///
  /// Also DERIVED: the wait bound is `maxContextTokens × this ÷ 100`. Below it the
  /// turn is sent without waiting (no summarization call for that turn) and folding
  /// is left to the background lifecycle. Default 75.
  final int compactionWaitThresholdPercent;

  /// Explicit user-written goals/acceptance criteria that compaction may never
  /// fold (design D-guard). Source is an explicit mechanism, NOT LLM-extraction
  /// from prose, so it is deterministic and revocable.
  final List<String> standingRequirements;

  /// 这个模型能吃哪些输入模态（配置键 `input_modalities`）。
  ///
  /// 取值只能是 `text` / `image`。缺省、不是数组、或者含任何非法取值，都整体回落
  /// 成"只有文本"并打一行日志 —— 默认**不允许多模态**是有意的：实测
  /// `deepseek-v4-pro` 收下 `image` 块但不看图，只多算 8 个输入 token、答案与图像
  /// 内容无关（见 `Docs/DeepSeekAPIDoc.md` §6.2 的实测表）。不声明就不发图并给出
  /// 可见提示，比"发过去、模型悄悄看不见"正确。
  final List<String> inputModalities;

  /// 缺省值：只有文本。出处见上面 [inputModalities] 的说明。
  ///
  /// 这里刻意写成"具名常量 + 引用"，而不是把取值直接写成一个方括号列表字面量：
  /// `test/unit/user_docs_test.dart` 会把 `lib/` 里"方括号包一个短字符串"的字面量
  /// 当成"代码解析的配置键"抽出来，再要求每一条都在文档的 json 块里出现 ——
  /// 而 text 是**取值**不是键，不该被这样要求。
  static const String kTextModality = 'text';

  /// 缺省值：只有文本。
  static const List<String> kDefaultInputModalities = <String>[kTextModality];

  /// 允许出现在 `input_modalities` 里的取值。
  static const Set<String> kAllowedInputModalities = {'text', 'image'};

  /// 只在第一次遇到非法值时打一行日志，免得每个 agent 类型各喊一次。
  static bool _illegalModalitiesReported = false;

  /// 解析 `input_modalities`：数组里**每个**元素都必须是 `text` / `image`，
  /// 重复的只留第一次出现的那次；只要有一个元素不合法（或根本不是数组、或是空
  /// 数组）就整体回落成 `kDefaultInputModalities` 并打一行日志。
  ///
  /// 空数组也算回落：一个"什么都不能吃"的模型没有意义，回落比留一个空列表诚实。
  static List<String> _parseInputModalities(Object? raw) {
    var legal = raw is List;
    final parsed = <String>[];
    if (legal) {
      for (final element in raw) {
        if (element is! String || !kAllowedInputModalities.contains(element)) {
          legal = false;
          break;
        }
        if (!parsed.contains(element)) parsed.add(element);
      }
    }
    if (legal && parsed.isNotEmpty) {
      return List<String>.unmodifiable(parsed);
    }
    if (!_illegalModalitiesReported) {
      _illegalModalitiesReported = true;
      debugPrint('[AliasAgent] input_modalities=$raw is absent, not an array, '
          'empty, or contains a value outside ${kAllowedInputModalities.join("/")} '
          '— using the default ${kDefaultInputModalities.join("/")}');
    }
    return kDefaultInputModalities;
  }

  /// 仅测试用：把"已经报过一次非法值"的标记清掉，好让日志断言不受用例顺序影响。
  @visibleForTesting
  static void resetInputModalitiesReportForTests() {
    _illegalModalitiesReported = false;
  }

  /// 命令工具（change `add-command-tool`）的四个旋钮，随每次调用一起传到执行侧
  /// （执行侧不读配置文件）。缺省值必须与 `sidecar/src/command_tool.cpp` 里
  /// 那几个常量一致；非法值一律回落缺省。
  ///
  /// `command_max_output_chars` 的缺省值 8000 是为了与 `lib/main.dart` 的
  /// `kToolResultElisionThreshold` 对齐：大于它的话，工具刚拼好的"截断了、全文
  /// 在哪"会被发给模型之前那道通用截断掐掉中间。
  final int commandTimeoutMs;
  final int commandMaxTimeoutMs;
  final int commandMaxOutputChars;
  final int commandOutputFullChars;

  /// 命令缺省超时毫秒数（与 C++ 侧一致）。
  static const int kDefaultCommandTimeoutMs = 120000;

  /// 命令超时上限（与 C++ 侧一致）。
  static const int kDefaultCommandMaxTimeoutMs = 600000;

  /// 每条流在内存里保留的字符上限（与 C++ 侧、与 kToolResultElisionThreshold 一致）。
  static const int kDefaultCommandMaxOutputChars = 8000;

  /// 写临时文件的完整输出上限（与 C++ 侧一致）。
  static const int kDefaultCommandOutputFullChars = 2000000;

  /// 字符上限的下限（与 C++ 侧一致）：再小就连截断说明和全文路径都放不下。
  static const int kMinCommandMaxOutputChars = 1000;

  /// 解析一个正整数旋钮：不是正整数（缺失 / 非数字 / 0 / 负数）就回落缺省值，
  /// 并打印一行，免得配置里的手误被静默忽略。
  static int _parsePositiveInt(Object? raw, int fallback, String key) {
    if (raw is int && raw > 0) return raw;
    debugPrint('[AliasAgent] $key=$raw is absent or not a positive integer — '
        'using the default $fallback');
    return fallback;
  }

  /// The default used when the config key is absent or illegal.
  static const int kDefaultCompactionThresholdPercent = 25;

  /// The default wait percentage when the config key is absent or illegal.
  static const int kDefaultCompactionWaitThresholdPercent = 75;

  /// Set once so a broken config value is reported a single time per process
  /// rather than once per agent type per load.
  static bool _illegalPercentReported = false;

  /// Set once, separately from [_illegalPercentReported], so a broken
  /// `compaction_wait_threshold_percent` is also reported exactly once.
  static bool _illegalWaitPercentReported = false;

  /// Parse the percentage, falling back to [kDefaultCompactionThresholdPercent]
  /// for anything that is not an integer in 1..100 (absent, non-numeric, 0,
  /// negative, above 100, fractional, boolean). A fallback prints one line so a
  /// typo in the config file is not silently ignored.
  static int _parseCompactionThresholdPercent(Object? raw) {
    if (raw is int && raw > 0 && raw <= 100) return raw;
    if (!_illegalPercentReported) {
      _illegalPercentReported = true;
      debugPrint('[AliasAgent] compaction_threshold_percent=$raw is absent or '
          'not an integer in 1..100 — using the default '
          '$kDefaultCompactionThresholdPercent% of the model context window');
    }
    return kDefaultCompactionThresholdPercent;
  }

  /// Same rule as [_parseCompactionThresholdPercent], for the wait percentage:
  /// anything that is not an integer in 1..100 is treated as absent and falls
  /// back to [kDefaultCompactionWaitThresholdPercent], with one log line.
  static int _parseCompactionWaitThresholdPercent(Object? raw) {
    if (raw is int && raw > 0 && raw <= 100) return raw;
    if (!_illegalWaitPercentReported) {
      _illegalWaitPercentReported = true;
      debugPrint('[AliasAgent] compaction_wait_threshold_percent=$raw is absent '
          'or not an integer in 1..100 — using the default '
          '$kDefaultCompactionWaitThresholdPercent% of the model context window');
    }
    return kDefaultCompactionWaitThresholdPercent;
  }

  const AgentTypeConfig({
    required this.name,
    required this.provider,
    required this.model,
    required this.systemPrompt,
    this.tools = const [],
    this.thinkingEffort,
    this.maxContextTokens,
    this.compactionThresholdPercent = kDefaultCompactionThresholdPercent,
    this.compactionWaitThresholdPercent = kDefaultCompactionWaitThresholdPercent,
    this.standingRequirements = const [],
    this.inputModalities = kDefaultInputModalities,
    this.commandTimeoutMs = kDefaultCommandTimeoutMs,
    this.commandMaxTimeoutMs = kDefaultCommandMaxTimeoutMs,
    this.commandMaxOutputChars = kDefaultCommandMaxOutputChars,
    this.commandOutputFullChars = kDefaultCommandOutputFullChars,
  });

  factory AgentTypeConfig.fromJson(String name, Map<String, dynamic> json) {
    return AgentTypeConfig(
      name: name,
      provider: json['provider'] as String,
      model: json['model'] as String,
      systemPrompt: json['system_prompt'] as String? ?? '',
      tools: (json['tools'] as List<dynamic>?)
              ?.map((t) => t as String)
              .toList() ??
          [],
      thinkingEffort: json['thinking_effort'] as String?,
      maxContextTokens: json['max_context_tokens'] as int?,
      compactionThresholdPercent:
          _parseCompactionThresholdPercent(json['compaction_threshold_percent']),
      compactionWaitThresholdPercent: _parseCompactionWaitThresholdPercent(
          json['compaction_wait_threshold_percent']),
      standingRequirements: (json['standing_requirements'] as List<dynamic>?)
              ?.map((t) => t as String)
              .toList() ??
          [],
      inputModalities: _parseInputModalities(json['input_modalities']),
      commandTimeoutMs: _parsePositiveInt(json['command_timeout_ms'],
          kDefaultCommandTimeoutMs, 'command_timeout_ms'),
      commandMaxTimeoutMs: _parsePositiveInt(json['command_max_timeout_ms'],
          kDefaultCommandMaxTimeoutMs, 'command_max_timeout_ms'),
      // 字符上限另有一个下限：配得比它小一律按它执行（否则连截断说明都放不下）。
      commandMaxOutputChars: (() {
        final parsed = _parsePositiveInt(json['command_max_output_chars'],
            kDefaultCommandMaxOutputChars, 'command_max_output_chars');
        return parsed < kMinCommandMaxOutputChars
            ? kMinCommandMaxOutputChars
            : parsed;
      })(),
      commandOutputFullChars: _parsePositiveInt(json['command_output_full_chars'],
          kDefaultCommandOutputFullChars, 'command_output_full_chars'),
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'model': model,
        'system_prompt': systemPrompt,
        'tools': tools,
        if (thinkingEffort != null) 'thinking_effort': thinkingEffort,
        if (maxContextTokens != null) 'max_context_tokens': maxContextTokens,
        // Always written (there is no UI for it), so the knob is discoverable in
        // ~/.aliasagent/config.json.
        'compaction_threshold_percent': compactionThresholdPercent,
        'compaction_wait_threshold_percent': compactionWaitThresholdPercent,
        // 总是写回：这个旋钮没有界面，只能靠 config.json 改。
        'input_modalities': inputModalities,
        // 命令工具的四个旋钮：一并写回，让它们在 ~/.aliasagent/config.json 里看得见。
        'command_timeout_ms': commandTimeoutMs,
        'command_max_timeout_ms': commandMaxTimeoutMs,
        'command_max_output_chars': commandMaxOutputChars,
        'command_output_full_chars': commandOutputFullChars,
        if (standingRequirements.isNotEmpty)
          'standing_requirements': standingRequirements,
      };
}
