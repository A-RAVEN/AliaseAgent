class AgentTypeConfig {
  final String name;
  final String provider;
  final String model;
  final String systemPrompt;
  final List<String> tools;

  const AgentTypeConfig({
    required this.name,
    required this.provider,
    required this.model,
    required this.systemPrompt,
    this.tools = const [],
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
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'model': model,
        'system_prompt': systemPrompt,
        'tools': tools,
      };
}
