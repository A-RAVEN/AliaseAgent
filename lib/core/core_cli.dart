// 无头核心的命令行解析（change `windows-desktop-shell` 任务 1.2 / design D2 / D3）。
//
// 抽出来的理由：端口现在有**优先级**（`--port` > 配置 `core.port` > 具名默认），
// 而这段逻辑既要被 `bin/alias_agent_core.dart` 用，也要被单元测试与文档守卫直接调 ——
// 埋在 `main()` 里就只能靠跑进程来验。
//
// 口径（与 spec `web-core-shim` 的「无头核心进程独立启动并回显访问地址」一致）：
//   - `--port`：显式输入，非法（非整数 / 负数 / 超出 65535）即报错退出，**不猜默认**；
//     `0` 是保留形态 = 交回 OS 分配（仅调试/测试用，壳侧会拒绝它）；
//   - 配置 `core.port`：缺席 / 非整数 / 越界 ⇒ `AppConfig` 回落具名默认并留一行日志
//     （回落可见），这里不重复那套校验；
//   - 默认值只有一个来源：`AppConfig.kDefaultCorePort`（本文件不写第二份字面量）。
import '../models/app_config.dart';
import '../services/config_service.dart';
import 'headless_core.dart';

/// `--help` 的全文（入口与测试同源；启动命令来自 [kCoreEntryCommand]）。
const String kCoreCliUsage = '''
AliasAgent 无头核心（web UI 后端）

用法：$kCoreEntryCommand [选项]

选项：
  --port <n>         监听端口（1–${AppConfig.kMaxCorePort}；0 = 交回 OS 分配，仅调试/测试用）
                     优先级：--port > 配置 core.port > 默认 ${AppConfig.kDefaultCorePort}
  --config <path>    指定配置文件（默认 ~/.aliasagent/config.json）
  --lock <path>      指定单实例锁文件（默认 ~/.aliasagent/core.lock）
  --web-root <path>  web 客户端构建产物目录（默认 <CWD>/web/dist）
  -h, --help         显示本帮助

注意：CWD 必须包含仓库根的 sidecar.dll（裸名字加载）。
''';

/// 命令行错误：入口打印 [message] + 用法并以 2 退出（与既有「参数错误 = 2」一致）。
class CoreCliException implements Exception {
  const CoreCliException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析后的命令行。`port == null` = 用户没给 `--port`（不是 0）。
class CoreCliOptions {
  const CoreCliOptions({
    this.configPath,
    this.lockPath,
    this.webRoot,
    this.port,
    this.help = false,
  });

  final String? configPath;
  final String? lockPath;
  final String? webRoot;
  final int? port;
  final bool help;

  @override
  String toString() => 'CoreCliOptions(port=$port, config=$configPath, '
      'lock=$lockPath, webRoot=$webRoot, help=$help)';
}

/// 端口来源（启动输出用它说明「这个值从哪来」）。
enum CorePortSource { cli, config, defaultConstant }

/// 端口解析结果：值 + 来源 + 可选的说明（供启动输出逐行写清）。
class CorePortResolution {
  const CorePortResolution({
    required this.port,
    required this.source,
    this.note,
  });

  final int port;
  final CorePortSource source;
  final String? note;

  /// 启动输出里的「端口来源」一行。
  String describeSource() {
    final base = switch (source) {
      CorePortSource.cli => '--port（显式参数）',
      CorePortSource.config => '配置 core.port',
      CorePortSource.defaultConstant => '默认值 kDefaultCorePort',
    };
    return note == null ? base : '$base：$note';
  }

  @override
  String toString() => 'CorePortResolution(port=$port, source=${source.name}, '
      'note=$note)';
}

/// 解析命令行。成功返回选项；任何非法输入抛 [CoreCliException]（不猜默认值）。
CoreCliOptions parseCoreArgs(List<String> args) {
  String? configPath;
  String? lockPath;
  String? webRoot;
  int? port;
  var help = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];

    String takeValue() {
      if (i + 1 >= args.length) {
        throw CoreCliException('$arg 需要一个参数（收到的命令里它是最后一个）');
      }
      i++;
      return args[i];
    }

    switch (arg) {
      case '--config':
        configPath = takeValue();
      case '--lock':
        lockPath = takeValue();
      case '--web-root':
        webRoot = takeValue();
      case '--port':
        port = _parseCliPort(takeValue());
      case '-h':
      case '--help':
        help = true;
      default:
        throw CoreCliException('未知参数：$arg');
    }
  }

  return CoreCliOptions(
    configPath: configPath,
    lockPath: lockPath,
    webRoot: webRoot,
    port: port,
    help: help,
  );
}

/// `--port` 的取值校验：显式输入非法即报错（`0` 合法 = 交回 OS 分配）。
int _parseCliPort(String raw) {
  final parsed = int.tryParse(raw);
  if (parsed == null) {
    throw CoreCliException('--port 必须是整数（1–${AppConfig.kMaxCorePort}；'
        '0 = 交回 OS 分配），收到 "$raw"');
  }
  if (parsed < 0 || parsed > AppConfig.kMaxCorePort) {
    throw CoreCliException('--port 超出范围 0–${AppConfig.kMaxCorePort}'
        '（0 = 交回 OS 分配），收到 "$raw"');
  }
  return parsed;
}

/// 按优先级算出端口：`--port` > 配置 `core.port` > 具名默认。
///
/// `--port` 是显式输入：非法（负数 / 超范围）抛 [CoreCliException] —— 这条是给
/// 直接调用本函数的调用方（测试 / 未来的其它入口）的守卫，`parseCoreArgs` 已在
/// 解析时就拒过一次。
///
/// **来源判定为什么只比默认值**：`AppConfig.fromJson` 已经把「缺席 / 非法」回落成
/// 默认常量并留过一行日志，这里拿不到「原本有没有写」这个信息；为了避免把校验逻辑
/// 复制第二份（那会变成两个真相源），来源按「配置给出值与默认值是否相同」判定：
/// 相同 ⇒ 报「默认值」，不同 ⇒ 报「配置 core.port」。用户显式写默认值这种情形会
/// 被标成默认值 —— 值本身完全一样，不影响行为。
CorePortResolution resolveCorePortWithSource({
  int? cliPort,
  String? configPath,
}) {
  if (cliPort != null) {
    if (cliPort < 0 || cliPort > AppConfig.kMaxCorePort) {
      throw CoreCliException('端口超出范围 0–${AppConfig.kMaxCorePort}：收到 $cliPort');
    }
    return CorePortResolution(port: cliPort, source: CorePortSource.cli);
  }

  final result = ConfigService.load(configPath: configPath);
  if (result.status == ConfigStatus.ok) {
    final config = result.config!;
    if (config.corePort == AppConfig.kDefaultCorePort) {
      return const CorePortResolution(
        port: AppConfig.kDefaultCorePort,
        source: CorePortSource.defaultConstant,
        note: '配置文件里没有合法的 core.port（回落实现在 AppConfig，那里留了一行日志）',
      );
    }
    return CorePortResolution(
      port: config.corePort,
      source: CorePortSource.config,
    );
  }
  return CorePortResolution(
    port: AppConfig.kDefaultCorePort,
    source: CorePortSource.defaultConstant,
    note: result.status == ConfigStatus.malformed
        ? '配置文件无法解析（核心启动时会以可归因错误退出）'
        : '配置文件不存在',
  );
}

/// 只要端口值的便捷形态（文档守卫与调用方读它）。
int resolveCorePort({int? cliPort, String? configPath}) =>
    resolveCorePortWithSource(cliPort: cliPort, configPath: configPath).port;
