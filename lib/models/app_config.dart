import 'agent_type_config.dart';
import 'provider_config.dart';

class AppConfig {
  final int version;
  final Map<String, ProviderConfig> providers;
  final Map<String, AgentTypeConfig> agentTypes;
  final Map<String, dynamic>? search;

  const AppConfig({
    required this.version,
    this.providers = const {},
    this.agentTypes = const {},
    this.search,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final providers = <String, ProviderConfig>{};
    if (json['providers'] is Map<String, dynamic>) {
      for (final entry in (json['providers'] as Map<String, dynamic>).entries) {
        providers[entry.key] =
            ProviderConfig.fromJson(entry.value as Map<String, dynamic>);
      }
    }

    final agentTypes = <String, AgentTypeConfig>{};
    if (json['agent_types'] is Map<String, dynamic>) {
      for (final entry
          in (json['agent_types'] as Map<String, dynamic>).entries) {
        agentTypes[entry.key] = AgentTypeConfig.fromJson(
            entry.key, entry.value as Map<String, dynamic>);
      }
    }

    return AppConfig(
      version: json['version'] as int? ?? 1,
      providers: providers,
      agentTypes: agentTypes,
      search: json['search'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'version': version,
      'providers': providers.map((k, v) => MapEntry(k, v.toJson())),
      'agent_types': agentTypes.map((k, v) => MapEntry(k, v.toJson())),
    };
    // Conditionally include search when non-null and non-empty
    if (search != null && search!.isNotEmpty) {
      m['search'] = search;
    }
    return m;
  }
}
