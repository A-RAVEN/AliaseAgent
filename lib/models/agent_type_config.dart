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
        if (standingRequirements.isNotEmpty)
          'standing_requirements': standingRequirements,
      };
}
