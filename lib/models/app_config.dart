import 'package:flutter/foundation.dart';

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

  /// `tool.parallel_max`：单个只读并发段一次最多同时启动多少个成员。
  ///
  /// 0 = **不设上限**（默认，见 design D6：不发明硬编码上限）；正整数 = 该段按这个
  /// 值顺次切成多个子并发段，交付顺序不变。缺键、非整数、负数一律回落 0 并打印
  /// 一次提示（与 `compaction_threshold_percent` 的缺省回落形态一致）。
  final int toolParallelMax;

  /// 缺省 0 = 不设上限（design D6 的配置项默认值）。
  static const int kDefaultToolParallelMax = 0;

  /// 只在第一次遇到非法的 `tool.parallel_max` 时打印一行，免得每次读配置都喊一次。
  static bool _illegalToolParallelMaxReported = false;

  /// 解析 `tool.parallel_max`：只有"非负整数"才生效，其它值一律回落 0。
  static int _parseToolParallelMax(Object? raw) {
    if (raw is int && raw >= 0) return raw;
    if (!_illegalToolParallelMaxReported) {
      _illegalToolParallelMaxReported = true;
      debugPrint('[AliasAgent] tool.parallel_max=$raw is absent or not a '
          'non-negative integer — using the default '
          '$kDefaultToolParallelMax (no limit)');
    }
    return kDefaultToolParallelMax;
  }

  const AppConfig({
    required this.version,
    this.providers = const {},
    this.agentTypes = const {},
    this.search,
    this.spillPreviewChars = kDefaultSpillPreviewChars,
    this.toolParallelMax = kDefaultToolParallelMax,
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

    // `tool` 是可选的顶层块；`parallel_max` 缺键 / 非整数 / 负数一律回落 0
    // （= 不设上限），并打印一次提示。
    final tool = json['tool'];
    final toolParallelMax = _parseToolParallelMax(
        tool is Map<String, dynamic> ? tool['parallel_max'] : null);

    return AppConfig(
      version: json['version'] as int? ?? 1,
      providers: providers,
      agentTypes: agentTypes,
      search: json['search'] as Map<String, dynamic>?,
      spillPreviewChars: previewChars,
      toolParallelMax: toolParallelMax,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'version': version,
      'providers': providers.map((k, v) => MapEntry(k, v.toJson())),
      'agent_types': agentTypes.map((k, v) => MapEntry(k, v.toJson())),
      'spill': {'preview_chars': spillPreviewChars},
      // 总是写回：这个旋钮没有界面，只能靠 config.json 改（同 spill）。
      'tool': {'parallel_max': toolParallelMax},
    };
    // Conditionally include search when non-null and non-empty
    if (search != null && search!.isNotEmpty) {
      m['search'] = search;
    }
    return m;
  }

  /// 复制一份只替换指定字段的配置。
  ///
  /// 模板保存与首启补问都必须走"在现有配置上换掉必要字段"，而不是拿一份新的缺省
  /// 配置整份覆盖 —— 后者会静默丢掉 providers / search / spill / 其它模板。
  AppConfig copyWith({
    int? version,
    Map<String, ProviderConfig>? providers,
    Map<String, AgentTypeConfig>? agentTypes,
    Map<String, dynamic>? search,
    int? spillPreviewChars,
    int? toolParallelMax,
  }) {
    return AppConfig(
      version: version ?? this.version,
      providers: providers ?? this.providers,
      agentTypes: agentTypes ?? this.agentTypes,
      search: search ?? this.search,
      spillPreviewChars: spillPreviewChars ?? this.spillPreviewChars,
      toolParallelMax: toolParallelMax ?? this.toolParallelMax,
    );
  }
}
