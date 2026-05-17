import '../models/agent_type_config.dart';

class AgentTypeRegistry {
  final Map<String, AgentTypeConfig> _types = {};

  void register(AgentTypeConfig config) {
    _types[config.name] = config;
  }

  AgentTypeConfig? lookup(String name) => _types[name];

  List<String> listNames() => _types.keys.toList();

  void clear() => _types.clear();
}
