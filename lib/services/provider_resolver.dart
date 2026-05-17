import '../models/app_config.dart';
import '../models/provider_config.dart';

class ProviderResolver {
  final Map<String, ProviderConfig> _providers;

  ProviderResolver(AppConfig config) : _providers = Map.unmodifiable(config.providers);

  ProviderConfig? resolve(String name) => _providers[name];
}
