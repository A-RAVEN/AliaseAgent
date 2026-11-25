import 'package:meta/meta.dart';

import '../services/logging.dart';
import 'agent_type_config.dart';
import 'provider_config.dart';
import 'user_profile.dart';

class AppConfig {
  final int version;
  final Map<String, ProviderConfig> providers;
  final Map<String, AgentTypeConfig> agentTypes;
  final Map<String, dynamic>? search;

  /// 本机用户资料块（change `chat-bubbles-avatars` D2）：头像路径 + 用户标识。
  ///
  /// `null` = 没有资料（界面按常量种子画身份图案）。整块缺席或不是对象时读作没有
  /// 资料；块里两项都没有值也归成 `null`，好让 `toJson` 不写出空块。
  final UserProfile? profile;

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

  /// 无头核心固定端口（`core.port`，change `windows-desktop-shell` D2）。
  ///
  /// 缺省 = [kDefaultCorePort]；缺席 / 非整数 / 越界一律回落该常量并打一行日志。
  final int corePort;

  /// 缺省 0 = 不设上限（design D6 的配置项默认值）。
  static const int kDefaultToolParallelMax = 0;

  /// `core.port`：无头核心监听的固定端口（change `windows-desktop-shell` D2）。
  ///
  /// 取值链：`--port` > `core.port` > 这个具名默认值；`0` 只保留给**核心**侧的
  /// 「交回 OS 分配」调试/测试形态（壳明确拒绝 0）。数字本身取 `0x4141`（产品名缩写
  /// AA 的 ASCII 十六进制），落在 IANA/RFC 6335 的用户端口区 1024–49151。
  ///
  /// **这是唯一一处 Dart 侧字面量**：`test/unit/desktop_shell_docs_test.dart` 会扫描
  /// `lib/**/*.dart`，别处再写一个同样的数字即红。
  static const int kDefaultCorePort = 16705;

  /// 端口合法范围（TCP 端口域，平台硬限）。
  static const int kMinCorePort = 1;
  static const int kMaxCorePort = 65535;

  /// 只在第一次遇到缺席 / 非法的 `core.port` 时打印一行，免得每次读配置都喊一次。
  static bool _illegalCorePortReported = false;

  /// 仅测试用：清掉"已经报过一次 core.port"的标记（否则第二条非法值用例抓不到日志）。
  @visibleForTesting
  static void resetCorePortReportForTests() {
    _illegalCorePortReported = false;
  }

  /// 解析 `core.port`：只有"1–65535 的整数"才生效，其它值一律回落默认（不阻塞启动）。
  static int _parseCorePort(Object? raw) {
    if (raw is int && raw >= kMinCorePort && raw <= kMaxCorePort) return raw;
    if (!_illegalCorePortReported) {
      _illegalCorePortReported = true;
      debugPrint('[AliasAgent] core.port=$raw is absent or not an integer in '
          '$kMinCorePort..$kMaxCorePort — using the default $kDefaultCorePort');
    }
    return kDefaultCorePort;
  }

  /// 只在第一次遇到非法的 `tool.parallel_max` 时打印一行，免得每次读配置都喊一次。
  static bool _illegalToolParallelMaxReported = false;

  /// 只在第一次遇到"`profile` 不是对象"时打印一行。
  static bool _illegalProfileBlockReported = false;

  /// 仅测试用：清掉"已经报过一次 profile 块非法"的标记。
  @visibleForTesting
  static void resetProfileBlockReportForTests() {
    _illegalProfileBlockReported = false;
  }

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
    this.profile,
    this.spillPreviewChars = kDefaultSpillPreviewChars,
    this.toolParallelMax = kDefaultToolParallelMax,
    this.corePort = kDefaultCorePort,
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

    // `core` 是可选的顶层块（change `windows-desktop-shell` D2）：`port` 缺席 /
    // 非整数 / 越界一律回落默认常量并打印一次提示（不静默、也不阻塞启动）。
    final core = json['core'];
    final corePort =
        _parseCorePort(core is Map<String, dynamic> ? core['port'] : null);

    // `profile` 是可选的顶层块（change `chat-bubbles-avatars` D2）：缺席静默；不是
    // 对象 ⇒ 读作"没有资料"并打一行日志；块里两项都没有值 ⇒ 归成 null（不写空块）。
    final rawProfile = json['profile'];
    UserProfile? profile;
    if (rawProfile == null) {
      profile = null;
    } else if (rawProfile is Map) {
      final parsed = UserProfile.fromJson(Map<String, dynamic>.from(rawProfile));
      profile = parsed.isEmpty ? null : parsed;
    } else {
      if (!_illegalProfileBlockReported) {
        _illegalProfileBlockReported = true;
        debugPrint('[AliasAgent] profile=$rawProfile is not an object — '
            'treating it as "no user profile"');
      }
      profile = null;
    }

    return AppConfig(
      version: json['version'] as int? ?? 1,
      providers: providers,
      agentTypes: agentTypes,
      search: json['search'] as Map<String, dynamic>?,
      profile: profile,
      spillPreviewChars: previewChars,
      toolParallelMax: toolParallelMax,
      corePort: corePort,
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
      // 总是写回 `core` 块：`ConfigService.save` 整份覆盖写盘，不写回就会在用户
      // 「保存一次 provider」之后丢掉这个键（与 `profile` 块的降级边界同一类）。
      'core': {'port': corePort},
    };
    // Conditionally include search when non-null and non-empty
    if (search != null && search!.isNotEmpty) {
      m['search'] = search;
    }
    // 用户资料块只在至少一项有值时写回（没有资料不写空块）。
    if (profile != null && !profile!.isEmpty) {
      m['profile'] = profile!.toJson();
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
    UserProfile? profile,
    bool clearProfile = false,
    int? spillPreviewChars,
    int? toolParallelMax,
    int? corePort,
  }) {
    return AppConfig(
      version: version ?? this.version,
      providers: providers ?? this.providers,
      agentTypes: agentTypes ?? this.agentTypes,
      search: search ?? this.search,
      // 照 `GroupMember.copyWith(clearOverrides: true)` 的先例：`null` 不能表达
      // "清掉"，必须给一个显式的清除开关。
      profile: clearProfile ? null : (profile ?? this.profile),
      spillPreviewChars: spillPreviewChars ?? this.spillPreviewChars,
      toolParallelMax: toolParallelMax ?? this.toolParallelMax,
      corePort: corePort ?? this.corePort,
    );
  }
}
