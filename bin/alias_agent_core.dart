// 无头 Dart 核心入口（change `web-ui-core-shim` 任务 2.1；命令行解析在
// `lib/core/core_cli.dart`，change `windows-desktop-shell` 任务 1.2）。
//
//   dart run bin/alias_agent_core.dart [--port <n>] [--config <path>]
//                                      [--lock <path>] [--web-root <path>]
//
// 约定（也写进 `Docs/user-guide/web-core-shim.md`）：
//   - CWD 必须在**仓库根**：sidecar 以裸名字 `DynamicLibrary.open('sidecar.dll')`
//     加载，DLL 就在仓库根；
//   - 监听端口按优先级决定：`--port` > 配置 `core.port` > 具名默认
//     （`AppConfig.kDefaultCorePort`）。`--port 0` 保留「交回 OS 分配」的
//     调试/测试形态；启动输出回显 `http://127.0.0.1:<port>` 与实际端口来源；
//   - 同一时刻只跑一个核心：锁文件被占用时打印"已有核心在运行"并以非零码退出；
//   - 与 Flutter 应用共用同一份配置与数据库（灰度共存，回退 = 不启动本进程）。
//
// 不许在这里起任何窗口：本入口只绑定回环 HTTP/WS，界面由浏览器打开。
import 'dart:io';

import 'package:alias_agent/core/core_cli.dart';
import 'package:alias_agent/core/headless_core.dart';

Future<void> main(List<String> args) async {
  final CoreCliOptions options;
  try {
    options = parseCoreArgs(args);
  } on CoreCliException catch (e) {
    stderr.writeln(e.message);
    stderr.write(kCoreCliUsage);
    exitCode = 2;
    return;
  }
  if (options.help) {
    stdout.write(kCoreCliUsage);
    return;
  }

  final CorePortResolution resolution;
  try {
    resolution = resolveCorePortWithSource(
      cliPort: options.port,
      configPath: options.configPath,
    );
  } on CoreCliException catch (e) {
    stderr.writeln(e.message);
    exitCode = 2;
    return;
  }

  final HeadlessCore core;
  try {
    core = await HeadlessCoreRunner.start(
      configPath: options.configPath,
      lockPath: options.lockPath,
      webRoot: options.webRoot,
      port: resolution.port,
    );
  } on HeadlessCoreStartupException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  } catch (e, st) {
    stderr.writeln('无头核心启动失败：$e\n$st');
    exitCode = 1;
    return;
  }

  stdout.writeln('AliasAgent 无头核心已启动');
  // 端口来源要写明（配置 / 参数 / 默认）：固定端口只有地址稳定才有价值，
  // 用户得知道这个地址是怎么定下来的。
  stdout.writeln('  端口来源: ${resolution.describeSource()}');
  final notice = core.startupNotice;
  if (notice != null) {
    // change `web-management-ui` D2：空配置启动时把原因写清楚（web 端会显示首启向导）。
    stdout.writeln('  $notice');
  }
  stdout.writeln('  URL:       ${core.url}');
  stdout.writeln('  WebSocket: ${core.websocketUrl}');
  stdout.writeln('  RPC:       ${core.rpcMethods.join(', ')}');
  stdout.writeln('  （同一时刻只跑一个核心；按 Ctrl+C 退出，或经 WS 调 core.shutdown）');
  await stdout.flush();

  // 入口与集成测试**共用**同一个停机等待点（先回包、再停机；SIGINT 也走这里）。
  final report = await core.serveUntilShutdown();
  stdout.writeln('已退出。');
  if (report.hasWarnings) {
    stderr.writeln('停机有告警（退出码 ${report.exitCode}）：');
    for (final warning in report.warnings) {
      stderr.writeln('  - $warning');
    }
    exitCode = report.exitCode;
  }
}
