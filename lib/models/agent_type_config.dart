class AgentTypeConfig {
  final String name;
  final String provider;
  final String model;
  final String systemPrompt;
  final List<String> tools;
  final String? thinkingEffort;
  final int? maxContextTokens;
  /// Explicit user-written goals/acceptance criteria that compaction may never
  /// fold (design D-guard). Source is an explicit mechanism, NOT LLM-extraction
  /// from prose, so it is deterministic and revocable.
  final List<String> standingRequirements;

  const AgentTypeConfig({
    required this.name,
    required this.provider,
    required this.model,
    required this.systemPrompt,
    this.tools = const [],
    this.thinkingEffort,
    this.maxContextTokens,
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
        if (standingRequirements.isNotEmpty)
          'standing_requirements': standingRequirements,
      };
}
