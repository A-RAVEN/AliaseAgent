import 'package:flutter/foundation.dart';

/// 网关模型目录里的一个条目（change `add-provider-model-discovery` 任务 2.1）。
///
/// 字段语义按 magpie 的 `/v1/models` 事实标准（出处见 `Docs/MagpieGatewayDoc.md`）：
/// `context_window` 缺失或非正整数记"窗口未知"（[contextWindow] 为 null）；
/// `supported_reasoning_levels` 显式 `[]` 是合法语义"无已知档位"（[reasoningEfforts]
/// 为空列表），缺失才是未知（null）；`native_endpoints` / `pricing` 缺失记"未知"
/// （null），**不补齐成空集合冒充已知**——该网关文档原文是"未知就整个省略"。
class ModelCatalogEntry {
  final String id;
  final String? displayName;

  /// 窗口未知时为 null（不是 0）。
  final int? contextWindow;

  /// 最大输出 token 未知时为 null。
  final int? maxOutputTokens;

  /// `modalities.input` 原样照录（含产品发不出的 `video` 也照录，过滤只发生在回填模板时）。
  final List<String> inputModalities;

  /// `modalities.output` 原样照录。
  final List<String> outputModalities;

  /// `supported_reasoning_levels[].effort`。null = 字段缺失（未知）；`[]` = 无已知档位。
  final List<String>? reasoningEfforts;

  /// `native_endpoints`。null = 未知（不补空集合）。
  final List<String>? nativeEndpoints;

  /// `pricing` 原样透传（键值都是网关给的字符串/数字），未知为 null。
  final Map<String, dynamic>? pricing;

  const ModelCatalogEntry({
    required this.id,
    this.displayName,
    this.contextWindow,
    this.maxOutputTokens,
    this.inputModalities = const [],
    this.outputModalities = const [],
    this.reasoningEfforts,
    this.nativeEndpoints,
    this.pricing,
  });

  /// 解析一条目录条目。缺字符串 `id` 时返回 null（调用方逐条丢弃并计数），
  /// 同时打一行日志点名原始 JSON —— 不让坏条目静默消失。
  static ModelCatalogEntry? fromJson(Object? raw) {
    if (raw is! Map) {
      debugPrint('[AliasAgent] 模型目录条目不是对象，已丢弃：$raw');
      return null;
    }
    final rawId = raw['id'];
    if (rawId is! String || rawId.trim().isEmpty) {
      debugPrint('[AliasAgent] 模型目录条目缺少字符串 id，已丢弃：$raw');
      return null;
    }

    final rawDisplayName = raw['display_name'];
    final rawModalities = raw['modalities'];
    final input = <String>[];
    final output = <String>[];
    if (rawModalities is Map) {
      input.addAll(_stringList(rawModalities['input']));
      output.addAll(_stringList(rawModalities['output']));
    }

    List<String>? efforts;
    final rawLevels = raw['supported_reasoning_levels'];
    if (rawLevels is List) {
      efforts = <String>[];
      for (final level in rawLevels) {
        if (level is Map && level['effort'] is String) {
          efforts.add(level['effort'] as String);
        }
      }
      efforts = List<String>.unmodifiable(efforts);
    }

    List<String>? endpoints;
    final rawEndpoints = raw['native_endpoints'];
    if (rawEndpoints is List) {
      endpoints = List<String>.unmodifiable(_stringList(rawEndpoints));
    }

    Map<String, dynamic>? pricing;
    final rawPricing = raw['pricing'];
    if (rawPricing is Map) {
      pricing = Map<String, dynamic>.from(rawPricing);
    }

    return ModelCatalogEntry(
      id: rawId,
      displayName: rawDisplayName is String ? rawDisplayName : null,
      contextWindow: _positiveInt(raw['context_window']),
      maxOutputTokens: _positiveInt(raw['max_output_tokens']),
      inputModalities: List<String>.unmodifiable(input),
      outputModalities: List<String>.unmodifiable(output),
      reasoningEfforts: efforts,
      nativeEndpoints: endpoints,
      pricing: pricing,
    );
  }

  static int? _positiveInt(Object? raw) =>
      (raw is int && raw > 0) ? raw : null;

  static List<String> _stringList(Object? raw) => <String>[
        if (raw is List)
          for (final element in raw)
            if (element is String) element,
      ];

  /// 写回配置。只写已知字段：`context_window`/`native_endpoints`/`pricing` 未知时整键省略，
  /// 与网关文档"未知就整个省略"的语义一致，也不会让"未知"在下一轮读回时变成"已知空集合"。
  Map<String, dynamic> toJson() => {
        'id': id,
        if (displayName != null) 'display_name': displayName,
        if (contextWindow != null) 'context_window': contextWindow,
        if (maxOutputTokens != null) 'max_output_tokens': maxOutputTokens,
        'modalities': {
          'input': inputModalities,
          'output': outputModalities,
        },
        if (reasoningEfforts != null)
          'supported_reasoning_levels': [
            for (final effort in reasoningEfforts!) {'effort': effort},
          ],
        if (nativeEndpoints != null) 'native_endpoints': nativeEndpoints,
        if (pricing != null) 'pricing': pricing,
      };

  @override
  bool operator ==(Object other) =>
      other is ModelCatalogEntry &&
      other.id == id &&
      other.contextWindow == contextWindow &&
      other.maxOutputTokens == maxOutputTokens &&
      other.displayName == displayName &&
      _listEquals(other.inputModalities, inputModalities) &&
      _listEquals(other.outputModalities, outputModalities) &&
      _listEquals(other.reasoningEfforts, reasoningEfforts) &&
      _listEquals(other.nativeEndpoints, nativeEndpoints) &&
      _mapEquals(other.pricing, pricing);

  @override
  int get hashCode => Object.hash(
        id,
        displayName,
        contextWindow,
        maxOutputTokens,
        Object.hashAll(inputModalities),
        Object.hashAll(outputModalities),
        reasoningEfforts == null ? null : Object.hashAll(reasoningEfforts!),
        nativeEndpoints == null ? null : Object.hashAll(nativeEndpoints!),
        pricing == null ? null : Object.hashAll(pricing!.entries.map((e) => '${e.key}=${e.value}')),
      );

  @override
  String toString() => 'ModelCatalogEntry(id=$id, displayName=$displayName, '
      'contextWindow=$contextWindow, inputModalities=$inputModalities, '
      'reasoningEfforts=$reasoningEfforts, nativeEndpoints=$nativeEndpoints, '
      'pricing=$pricing)';
}

bool _listEquals(List<String>? a, List<String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
