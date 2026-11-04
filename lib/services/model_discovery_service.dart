import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/app_config.dart';
import '../models/model_catalog_entry.dart';
import '../models/provider_config.dart';
import 'config_service.dart';

/// 模型目录探测（change `add-provider-model-discovery` 任务 3.1 / 3.2）。
///
/// 协议与鉴权头照对话请求（设计 D7）：`GET {归一化 base_url}/v1/models`，带
/// `x-api-key` 与 `anthropic-version: 2023-06-01`。超时值不发明：连接与读各 15 秒，
/// 出处 `sidecar/src/web_fetch.cpp` 的 `FETCH_CONNECT_TIMEOUT_SEC = 15L` 与
/// `FETCH_TIMEOUT_SEC = 15L`。
///
/// 失败分三类，全部可见且不破坏旧目录：
/// 1. 非 200：错误写明 HTTP 状态码（密钥不进消息）；
/// 2. 连接拒绝 / 超时：错误写明具体原因；
/// 3. 顶层不是对象、`data` 缺失或非数组：判"该端点不是 magpie 标准目录"，完整原始响应
///    写入 `~/.aliasagent/logs/model_discovery_error_<UTC 时刻>.txt`，错误消息带总字符数、
///    已略去字符数与文件路径（截断可见且可恢复）。
class ModelCatalogProbeResult {
  final bool ok;
  final List<ModelCatalogEntry> entries;
  final int dropped;
  final String? error;

  /// 非标准目录时的预览（长度取自 `spill.preview_chars`）与总字符数 / 略去数 / 落盘文件。
  final String? preview;
  final int? totalChars;
  final int? omittedChars;
  final String? errorFilePath;

  const ModelCatalogProbeResult._({
    required this.ok,
    this.entries = const [],
    this.dropped = 0,
    this.error,
    this.preview,
    this.totalChars,
    this.omittedChars,
    this.errorFilePath,
  });

  factory ModelCatalogProbeResult.success(
          List<ModelCatalogEntry> entries, int dropped) =>
      ModelCatalogProbeResult._(ok: true, entries: entries, dropped: dropped);

  factory ModelCatalogProbeResult.failure(String error) =>
      ModelCatalogProbeResult._(ok: false, error: error);

  factory ModelCatalogProbeResult.nonStandard({
    required String error,
    required String preview,
    required int totalChars,
    required int omittedChars,
    required String errorFilePath,
  }) =>
      ModelCatalogProbeResult._(
        ok: false,
        error: error,
        preview: preview,
        totalChars: totalChars,
        omittedChars: omittedChars,
        errorFilePath: errorFilePath,
      );
}

/// 探测动作的可替换入口：界面注入假实现，测试不必起真网关。
abstract class ModelCatalogProbe {
  Future<ModelCatalogProbeResult> fetch({
    required String baseUrl,
    required String apiKey,
    required int previewChars,
  });
}

/// 一次探测并写回配置的结果。
class ModelDiscoveryReport {
  final bool success;
  final String providerName;

  /// 成功 = 新目录；失败 = 该 Provider 的旧目录原样（旧目录不清空）。
  final List<ModelCatalogEntry> entries;

  final int added;
  final int updated;
  final int removed;

  /// 解析期因缺字符串 `id` 被丢弃的条目数：单独一类，**不计入** [removed]
  /// （把解析失败显示成网关下架会给出相反的原因）。
  final int dropped;

  final String? error;
  final String? preview;
  final int? totalChars;
  final int? omittedChars;
  final String? errorFilePath;

  final String? discoveredAt;

  /// 成功 = 写回后的完整配置；失败 = 传入的配置原样。
  final AppConfig config;

  const ModelDiscoveryReport({
    required this.success,
    required this.providerName,
    required this.entries,
    required this.added,
    required this.updated,
    required this.removed,
    required this.dropped,
    required this.config,
    this.error,
    this.preview,
    this.totalChars,
    this.omittedChars,
    this.errorFilePath,
    this.discoveredAt,
  });

  /// 界面直接显示的一行结果（成功时是四类计数，失败时是原因）。
  String get summary => success
      ? '新增 $added，更新 $updated，移除 $removed，丢弃 $dropped'
      : '探测失败：${error ?? "未知原因"}';
}

/// `dart:io HttpClient` 实现的 magpie 目录探测。
class HttpModelCatalogProbe implements ModelCatalogProbe {
  /// 与 `sidecar/src/web_fetch.cpp` 的 `FETCH_CONNECT_TIMEOUT_SEC = 15L` 同值。
  static const int kConnectTimeoutSeconds = 15;

  /// 与 `sidecar/src/web_fetch.cpp` 的 `FETCH_TIMEOUT_SEC = 15L` 同值。
  static const int kReadTimeoutSeconds = 15;

  /// 错误全文落盘目录；null = 产品的 `~/.aliasagent/logs`。
  final String? logsDir;

  /// 可注入的时钟（测试要断言文件名里的 UTC 时刻）。
  final DateTime Function() clock;

  HttpModelCatalogProbe({this.logsDir, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  String get _resolvedLogsDir =>
      logsDir ??
      '${ConfigService.configDir}${Platform.pathSeparator}logs';

  @override
  Future<ModelCatalogProbeResult> fetch({
    required String baseUrl,
    required String apiKey,
    required int previewChars,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final Uri uri;
    try {
      uri = Uri.parse('$normalized/v1/models');
    } on FormatException catch (e) {
      return ModelCatalogProbeResult.failure('网关地址无法解析：${e.message}');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: kConnectTimeoutSeconds);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: kConnectTimeoutSeconds));
      request.headers.set('x-api-key', apiKey);
      request.headers.set('anthropic-version', '2023-06-01');
      final response = await request
          .close()
          .timeout(const Duration(seconds: kReadTimeoutSeconds));
      final bytes = await response
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
          .timeout(const Duration(seconds: kReadTimeoutSeconds));
      final raw = utf8.decode(bytes, allowMalformed: true);

      if (response.statusCode != 200) {
        // 只带状态码：响应体可能回显请求头，密钥不得进入错误消息与日志。
        return ModelCatalogProbeResult.failure('HTTP ${response.statusCode}');
      }
      return _parse(raw, previewChars);
    } on TimeoutException {
      return ModelCatalogProbeResult.failure(
          '连接或读取超时（连接 $kConnectTimeoutSeconds 秒 / 读取 $kReadTimeoutSeconds 秒）');
    } on SocketException catch (e) {
      return ModelCatalogProbeResult.failure('连接失败：${e.message}');
    } on HttpException catch (e) {
      return ModelCatalogProbeResult.failure('HTTP 请求失败：${e.message}');
    } catch (e) {
      return ModelCatalogProbeResult.failure('探测异常：$e');
    } finally {
      client.close(force: true);
    }
  }

  ModelCatalogProbeResult _parse(String raw, int previewChars) {
    Object? decoded;
    var parseError = false;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      parseError = true;
    }
    final data = decoded is Map ? decoded['data'] : null;
    if (parseError || decoded is! Map || data is! List) {
      return _nonStandardDirectory(raw, previewChars);
    }

    final entries = <ModelCatalogEntry>[];
    var dropped = 0;
    for (final item in data) {
      final entry = ModelCatalogEntry.fromJson(item);
      if (entry == null) {
        dropped++;
      } else {
        entries.add(entry);
      }
    }
    return ModelCatalogProbeResult.success(
        List<ModelCatalogEntry>.unmodifiable(entries), dropped);
  }

  /// 非标准目录：完整原文落盘，界面拿到"总字符数 / 已略去 M 字符 / 文件路径"。
  ModelCatalogProbeResult _nonStandardDirectory(String raw, int previewChars) {
    final preview = _preview(raw, previewChars);
    final omitted = raw.length - preview.length;
    String? path;
    try {
      final dir = Directory(_resolvedLogsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final stamp = clock()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final file =
          File('${dir.path}${Platform.pathSeparator}model_discovery_error_$stamp.txt');
      file.writeAsStringSync(raw);
      path = file.path;
    } catch (e) {
      // 落盘失败也必须说清："完整内容"取不回来时不能让界面假装能取回。
      return ModelCatalogProbeResult.failure(
          '该端点不是 magpie 标准目录：共 ${raw.length} 字符，'
          '完整响应写入失败（$e）');
    }
    return ModelCatalogProbeResult.nonStandard(
      error: '该端点不是 magpie 标准目录：共 ${raw.length} 字符，'
          '已略去 $omitted 字符，完整内容见 $path',
      preview: preview,
      totalChars: raw.length,
      omittedChars: omitted,
      errorFilePath: path,
    );
  }

  /// 头尾预览：总共 [previewChars] 个字符（中间一个 `…` 标记被略去的部分）。
  /// 长度取自产品既有配置 `spill.preview_chars`，不发明第二个数字。
  static String _preview(String raw, int previewChars) {
    if (raw.length <= previewChars) return raw;
    if (previewChars <= 1) return '…';
    final head = (previewChars - 1) ~/ 2;
    final tail = previewChars - 1 - head;
    return '${raw.substring(0, head)}…${raw.substring(raw.length - tail)}';
  }
}

/// 探测 + 目录替换的完整动作入口：Providers 页只依赖这个接口，widget 测试注入假实现。
abstract class ProviderCatalogDiscovery {
  Future<ModelDiscoveryReport> discover(AppConfig config, String providerName);
}

/// 探测 + 目录替换 + 整配置写回（任务 3.2）。
///
/// 写回走 `AppConfig.copyWith` + `ConfigService.save`，`version`、其它 Provider、
/// `agent_types`、`search`、`spill` 全部原样保留；失败时不写盘、不清空旧目录。
class ModelDiscoveryService implements ProviderCatalogDiscovery {
  final ModelCatalogProbe probe;

  /// 写回哪份配置；null = 产品默认的 `~/.aliasagent/config.json`。
  final String? configPath;

  final DateTime Function() clock;

  ModelDiscoveryService({
    ModelCatalogProbe? probe,
    this.configPath,
    DateTime Function()? clock,
  })  : probe = probe ?? HttpModelCatalogProbe(),
        clock = clock ?? DateTime.now;

  @override
  Future<ModelDiscoveryReport> discover(
      AppConfig config, String providerName) async {
    final provider = config.providers[providerName];
    if (provider == null) {
      return ModelDiscoveryReport(
        success: false,
        providerName: providerName,
        entries: const [],
        added: 0,
        updated: 0,
        removed: 0,
        dropped: 0,
        error: 'provider "$providerName" 不存在',
        config: config,
      );
    }

    final result = await probe.fetch(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
      previewChars: config.spillPreviewChars,
    );

    if (!result.ok) {
      return ModelDiscoveryReport(
        success: false,
        providerName: providerName,
        entries: provider.models,
        added: 0,
        updated: 0,
        removed: 0,
        dropped: 0,
        error: result.error,
        preview: result.preview,
        totalChars: result.totalChars,
        omittedChars: result.omittedChars,
        errorFilePath: result.errorFilePath,
        discoveredAt: provider.discoveredAt,
        config: config,
      );
    }

    final oldById = {for (final m in provider.models) m.id: m};
    final newById = {for (final m in result.entries) m.id: m};
    final added = newById.keys.where((id) => !oldById.containsKey(id)).length;
    final updated = newById.keys
        .where((id) => oldById.containsKey(id) && oldById[id] != newById[id])
        .length;
    final removed = oldById.keys.where((id) => !newById.containsKey(id)).length;

    final discoveredAt = clock().toUtc().toIso8601String();
    final providers = Map<String, ProviderConfig>.from(config.providers);
    providers[providerName] = provider.copyWith(
      models: result.entries,
      discoveredAt: discoveredAt,
    );
    final next = config.copyWith(providers: providers);
    ConfigService.save(next, configPath: configPath);

    return ModelDiscoveryReport(
      success: true,
      providerName: providerName,
      entries: result.entries,
      added: added,
      updated: updated,
      removed: removed,
      dropped: result.dropped,
      discoveredAt: discoveredAt,
      config: next,
    );
  }
}
