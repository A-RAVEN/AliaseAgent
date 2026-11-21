// 无头 Dart 核心入口（change `web-ui-core-shim` 任务 2.1）。
//
//   dart run bin/alias_agent_core.dart [--config <path>] [--lock <path>]
//                                      [--web-root <path>]
//
// 约定（也写进 `Docs/user-guide/web-core-shim.md`）：
//   - CWD 必须在**仓库根**：sidecar 以裸名字 `DynamicLibrary.open('sidecar.dll')`
//     加载，DLL 就在仓库根；
//   - 监听端口由 OS 分配（port 0），启动输出回显 `http://127.0.0.1:<port>`；
//   - 同一时刻只跑一个核心：锁文件被占用时打印"已有核心在运行"并以非零码退出；
//   - 与 Flutter 应用共用同一份配置与数据库（灰度共存，回退 = 不启动本进程）。
//
// 不许在这里起任何窗口：本入口只绑定回环 HTTP/WS，界面由浏览器打开。
import 'dart:async';
import 'dart:io';

import 'package:alias_agent/core/headless_core.dart';

const String kCoreUsage = '''
AliasAgent 无头核心（web UI 后端）

用法：$kCoreEntryCommand [选项]

选项：
  --config <path>    指定配置文件（默认 ~/.aliasagent/config.json）
  --lock <path>      指定单实例锁文件（默认 ~/.aliasagent/core.lock）
  --web-root <path>  web 客户端构建产物目录（默认 <CWD>/web/dist）
  -h, --help         显示本帮助

注意：CWD 必须包含仓库根的 sidecar.dll（裸名字加载）。
''';

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.write(kCoreUsage);
    return;
  }

  String? configPath;
  String? lockPath;
  String? webRoot;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? takeValue() {
      if (i + 1 >= args.length) return null;
      i++;
      return args[i];
    }

    switch (arg) {
      case '--config':
        configPath = takeValue();
        if (configPath == null) {
          stderr.writeln('--config 需要一个参数');
          exitCode = 2;
          return;
        }
      case '--lock':
        lockPath = takeValue();
        if (lockPath == null) {
          stderr.writeln('--lock 需要一个参数');
          exitCode = 2;
          return;
        }
      case '--web-root':
        webRoot = takeValue();
        if (webRoot == null) {
          stderr.writeln('--web-root 需要一个参数');
          exitCode = 2;
          return;
        }
      default:
        stderr.writeln('未知参数：$arg\n');
        stderr.write(kCoreUsage);
        exitCode = 2;
        return;
    }
  }

  final HeadlessCore core;
  try {
    core = await HeadlessCoreRunner.start(
      configPath: configPath,
      lockPath: lockPath,
      webRoot: webRoot,
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
  stdout.writeln('  URL:       ${core.url}');
  stdout.writeln('  WebSocket: ${core.websocketUrl}');
  stdout.writeln('  RPC:       ${core.rpcMethods.join(', ')}');
  stdout.writeln('  （同一时刻只跑一个核心；按 Ctrl+C 退出）');
  await stdout.flush();

  final done = Completer<void>();
  StreamSubscription<ProcessSignal>? sigint;
  try {
    sigint = ProcessSignal.sigint.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  } catch (_) {
    // 某些平台不支持 signal watch：进程仍可由外部终止。
  }

  await done.future;
  await sigint?.cancel();
  await core.stop();
  stdout.writeln('已退出。');
}
