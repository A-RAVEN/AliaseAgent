import 'agent_type_config.dart';
import 'provider_config.dart';

class AppConfig {
  final int version;
  final Map<String, ProviderConfig> providers;
  final Map<String, AgentTypeConfig> agentTypes;
  final Map<String, dynamic>? search;

  /// `spill.preview_chars`：工具输出超长时，内联预览**头尾各留多少字符**。
  ///
  /// 缺省 1000 是用户 2026-10-25 的决定（原话「4000字听起来也好多，改成1000字吧」）。
  /// 判定"要不要省略"的阈值是它的 2 倍（头 + 尾），算术推论，不是第二个数。
  final int spillPreviewChars;

  static const int kDefaultSpillPreviewChars = 1000;
  static const int kMinSpillPreviewChars = 1;

  const AppConfig({
    required this.version,
    this.providers = const {},
    this.agentTypes = const {},
    this.search,
    this.spillPreviewChars = kDefaultSpillPreviewChars,
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

    // `spill` 是个可选的顶层块；`preview_chars` 缺失 / 写成 0、负数、文字时
    // 一律回落到缺省值（与其它可选键的处理方式一致）。
    var previewChars = kDefaultSpillPreviewChars;
    final spill = json['spill'];
    if (spill is Map<String, dynamic>) {
      final raw = spill['preview_chars'];
      if (raw is int && raw >= kMinSpillPreviewChars) previewChars = raw;
    }

    return AppConfig(
      version: json['version'] as int? ?? 1,
      providers: providers,
      agentTypes: agentTypes,
      search: json['search'] as Map<String, dynamic>?,
      spillPreviewChars: previewChars,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'version': version,
      'providers': providers.map((k, v) => MapEntry(k, v.toJson())),
      'agent_types': agentTypes.map((k, v) => MapEntry(k, v.toJson())),
      'spill': {'preview_chars': spillPreviewChars},
    };
    // Conditionally include search when non-null and non-empty
    if (search != null && search!.isNotEmpty) {
      m['search'] = search;
    }
    return m;
  }
}
