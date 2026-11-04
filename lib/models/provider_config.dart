import 'package:flutter/foundation.dart';

import 'model_catalog_entry.dart';

/// 一个供应商的配置（change `add-provider-model-discovery` 任务 2.2）。
///
/// `models` / `discovered_at` 是模型探测写回的目录快照：旧配置没有这两个键时读成
/// "空目录 + 从未探测"，不写迁移代码。`toJson` 只在真的探测过（有目录或有时刻）时
/// 写回这两个键 —— 从未探测的供应商保持原有形状，探测写回不会顺带改动其它供应商。
class ProviderConfig {
  final String apiKey;
  final String baseUrl;
  final List<ModelCatalogEntry> models;
  final String? discoveredAt;

  const ProviderConfig({
    required this.apiKey,
    required this.baseUrl,
    this.models = const [],
    this.discoveredAt,
  });

  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    return ProviderConfig(
      apiKey: json['api_key'] as String,
      baseUrl: json['base_url'] as String? ?? '',
      models: _parseModels(json['models']),
      discoveredAt: _parseDiscoveredAt(json['discovered_at']),
    );
  }

  /// `models` 的解析：缺失 = 空目录；不是数组 = 整体按空目录处理并打一行日志点名原始值
  /// （非数组没有条目可逐条回落）；是数组时缺字符串 `id` 的条目逐条丢弃（日志由
  /// [ModelCatalogEntry.fromJson] 打，逐条点名原始 JSON）。
  static List<ModelCatalogEntry> _parseModels(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      debugPrint('[AliasAgent] providers.<名>.models 不是数组（原始值：$raw），'
          '按空目录处理');
      return const [];
    }
    final parsed = <ModelCatalogEntry>[];
    for (final item in raw) {
      final entry = ModelCatalogEntry.fromJson(item);
      if (entry != null) parsed.add(entry);
    }
    return List<ModelCatalogEntry>.unmodifiable(parsed);
  }

  /// `discovered_at` 解析：缺失 = 从未探测；不是非空字符串 = 按从未探测处理并打一行日志。
  static String? _parseDiscoveredAt(Object? raw) {
    if (raw == null) return null;
    if (raw is String && raw.isNotEmpty) return raw;
    debugPrint('[AliasAgent] providers.<名>.discovered_at 不是字符串'
        '（原始值：$raw），按从未探测处理');
    return null;
  }

  Map<String, dynamic> toJson() => {
        'api_key': apiKey,
        'base_url': baseUrl,
        if (models.isNotEmpty || discoveredAt != null)
          'models': [for (final model in models) model.toJson()],
        if (discoveredAt != null) 'discovered_at': discoveredAt,
      };

  ProviderConfig copyWith({
    String? apiKey,
    String? baseUrl,
    List<ModelCatalogEntry>? models,
    String? discoveredAt,
  }) {
    return ProviderConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      models: models ?? this.models,
      discoveredAt: discoveredAt ?? this.discoveredAt,
    );
  }
}

/// 网关地址归一化（change `add-provider-model-discovery` 任务 2.2，设计 D2）。
///
/// 规则只有一条：剥掉尾随的 `/`，再剥掉尾部路径段 `/v1`，循环至稳定；其余路径逐字保留。
/// 存储值与两条拼接（对话 `{base_url}/v1/messages`、探测 `{base_url}/v1/models`）同源，
/// 用户粘 `http://127.0.0.1:3425/v1` 也不会拼出 `/v1/v1/`。
String normalizeBaseUrl(String raw) {
  var url = raw;
  while (true) {
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    } else if (url.endsWith('/v1')) {
      url = url.substring(0, url.length - 3);
    } else {
      return url;
    }
  }
}
