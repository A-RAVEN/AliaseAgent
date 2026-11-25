// 固定端口：进程内 + 子进程端到端（change `windows-desktop-shell` 任务 0.3）。
//
// 为什么两段都要（design D8）：
//   - 进程内段证明「按配置算出的端口真的被绑定、`--port` 覆盖真的生效、端口被占时
//     抛的是**可归因**异常」；
//   - 子进程段证明 `--port` 真的接进了 `bin/alias_agent_core.dart` 这条真入口 ——
//     只测进程内「传端口」会漏掉「入口根本没接线」这种半空靶。
//
// 隔离（照 `group_test_support.dart` 的约定）：临时 config.json / attachments /
// `openAt` 临时库 / 临时 core.lock，子进程的 `USERPROFILE` 也指向临时目录；
// 收尾用 `realUserDirDifferences()` 证明 `~/.aliasagent` 的 db / config / core.lock 没变。
//
// 端口**不用**默认 16705：先 `bind 0` 取一个空闲端口写进临时 `core.port` ——
// 否则用户此刻正开着壳（占着 16705）时本测试会假红。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/core_cli.dart';
import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/services/database_service.dart';

import 'group_test_support.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[固定端口] $label: $value');
}

/// 当场取一个空闲端口（绑 0 再释放）。这里**不**做「被抢就重试」——被抢会让
/// 后续断言失败并显示真实原因，比偷偷换端口更容易归因。
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// 进程内一套：临时夹具 + 临时配置（写进空闲端口）。
class _Fixture {
  _Fixture(this.support);

  final GroupTestSupport support;

  static Future<_Fixture> create({required int configPort}) async {
    final support = await GroupTestSupport.create(prefix: 'core_fixed_port_');
    support.writeConfig(support.minimalConfig().copyWith(corePort: configPort));
    return _Fixture(support);
  }

  Future<HeadlessCore> start({required int port}) {
    return HeadlessCoreRunner.start(
      configPath: support.configPath,
      lockPath: support.lockPath,
      port: port,
      attachmentsDir: support.attachmentsDir,
      sidecarLoader: () => support.sidecar,
      webRoot: p.join(Directory.current.path, 'web', 'dist'),
      openDatabaseOverride: () async {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        await DatabaseService.openAt(support.databaseDir);
      },
    );
  }

  Future<void> dispose() async {
    await support.dispose();
  }
}

/// 子进程：真 `cmd /c dart run bin/alias_agent_core.dart …`。
class _CoreProcess {
  _CoreProcess(this.process) {
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stdoutLines.add(line);
    });
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderrLines.add(line);
    });
    _exitFuture = process.exitCode;
  }

  final Process process;
  final List<String> stdoutLines = [];
  final List<String> stderrLines = [];
  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;
  late final Future<int> _exitFuture;

  static Future<_CoreProcess> start({
    required List<String> args,
    required String tempHome,
  }) async {
    // 本机 `Get-Command dart` 只给到 `dart.bat`：`Process.start` 不能直接执行批处理，
    // 必须经 `cmd /C`（与壳的 DartExecutableResolver 同一条事实）。
    final process = await Process.start(
      'cmd',
      ['/c', 'dart', 'run', 'bin/alias_agent_core.dart', ...args],
      workingDirectory: Directory.current.path,
      environment: {
        'USERPROFILE': tempHome,
        'HOME': tempHome,
      },
    );
    return _CoreProcess(process);
  }

  /// 等到启动输出里出现 `http://127.0.0.1:<port>`，返回该端口；超时或进程提前退出
  /// 返回 null（调用方据此红并贴已收到的输出）。
  Future<int?> waitForUrlPort({Duration timeout = const Duration(seconds: 180)}) async {
    final deadline = DateTime.now().add(timeout);
    final pattern = RegExp(r'http://127\.0\.0\.1:(\d+)');
    while (DateTime.now().isBefore(deadline)) {
      for (final line in stdoutLines) {
        final match = pattern.firstMatch(line);
        if (match != null) return int.parse(match.group(1)!);
      }
      final exited = await Future.any<Object?>([
        _exitFuture,
        Future<void>.delayed(const Duration(milliseconds: 50)),
      ]);
      if (exited is int) {
        // 进程已退出：再给 stdout 一小段时间排空，然后返回 null。
        await Future<void>.delayed(const Duration(milliseconds: 200));
        for (final line in stdoutLines) {
          final match = pattern.firstMatch(line);
          if (match != null) return int.parse(match.group(1)!);
        }
        return null;
      }
    }
    return null;
  }

  Future<int> waitForExit({Duration timeout = const Duration(seconds: 120)}) =>
      _exitFuture.timeout(timeout);

  Future<void> killAndWait() async {
    // `cmd /C dart run …` 是双层进程：只 kill cmd 会留下 dart.exe 孤儿（还占着端口）。
    // `taskkill /T` 杀掉整棵树 —— 本用例不许给后面的用例留占位进程。
    try {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F'])
          .timeout(const Duration(seconds: 30));
    } catch (_) {}
    try {
      process.kill();
    } catch (_) {}
    try {
      await _exitFuture.timeout(const Duration(seconds: 20));
    } catch (_) {}
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
  }

  String get stdoutText => stdoutLines.join('\n');
}

/// 子进程前置：`dart` 能解析 && 仓库根有 `sidecar.dll`。
Future<String?> _subprocessPrerequisite() async {
  if (!File(p.join(Directory.current.path, 'sidecar.dll')).existsSync()) {
    return '仓库根没有 sidecar.dll';
  }
  try {
    final probe = await Process.run('cmd', ['/c', 'dart', '--version'])
        .timeout(const Duration(seconds: 60));
    if (probe.exitCode != 0) {
      return 'dart --version 退出码 ${probe.exitCode}';
    }
    _obs('dart --version', '${probe.stdout}'.trim());
  } catch (e) {
    return 'dart 不可解析：$e';
  }
  return null;
}

void main() {
  // 本文件是 `test()` + 真实 IO（HttpServer / WebSocket / 子进程）。
  // **不要**初始化 TestWidgetsFlutterBinding（它会装 HttpOverrides 拦截所有请求）。

  group('进程内：按配置算出的固定端口', () {
    late _Fixture fixture;
    late int configPort;
    HeadlessCore? core;

    setUp(() async {
      configPort = await _freePort();
      fixture = await _Fixture.create(configPort: configPort);
      _obs('临时配置里的 core.port', configPort);
    });

    tearDown(() async {
      await core?.stop();
      core = null;
      await fixture.dispose();
    });

    test('配置端口真的被绑定，core.ping 在该端口可通', () async {
      final resolved = resolveCorePort(
          cliPort: null, configPath: fixture.support.configPath);
      _obs('resolveCorePort（无 --port）', resolved);
      expect(resolved, configPort, reason: '没有 --port 时必须读配置里的 core.port');

      core = await fixture.start(port: resolved);
      _obs('核心实际监听端口', core!.port);
      _obs('回显 URL', core!.url);
      expect(core!.port, configPort, reason: '核心必须绑在配置给出的端口上');

      final ws = await WebSocket.connect(core!.websocketUrl.toString());
      final completer = Completer<Map<String, dynamic>>();
      final sub = ws.listen((data) {
        final decoded = jsonDecode(data as String) as Map<String, dynamic>;
        if (decoded['id'] == 1 && !completer.isCompleted) {
          completer.complete(decoded);
        }
      });
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'core.ping',
        'params': const <String, dynamic>{},
      }));
      final response = await completer.future.timeout(const Duration(seconds: 15));
      _obs('core.ping 响应', response);
      expect((response['result'] as Map)['ok'], isTrue);
      await sub.cancel();
      await ws.close();

      _obs('隔离读数', fixture.support.describeIsolation());
      expect(fixture.support.realUserDirDifferences(), isEmpty,
          reason: '本测试不许写用户真实 ~/.aliasagent（db/config/core.lock）');
    });

    test('--port 覆盖配置', () async {
      final overridePort = await _freePort();
      final resolved = resolveCorePort(
          cliPort: overridePort, configPath: fixture.support.configPath);
      _obs('配置 $configPort + --port $overridePort ⇒', resolved);
      expect(resolved, overridePort);

      core = await fixture.start(port: resolved);
      _obs('核心实际监听端口', core!.port);
      expect(core!.port, overridePort,
          reason: '--port 是显式输入，必须覆盖配置值');

      // 配置本身不被改写（覆盖只影响本次运行）。
      final configBack = File(fixture.support.configPath).readAsStringSync();
      _obs('盘上配置仍含 core.port', configBack.contains('"port": $configPort'));
      expect(configBack, contains('"port": $configPort'));
    });

    test('端口被占用：抛可归因异常（消息含端口号与 core.port）', () async {
      // 先用一个 ServerSocket 占住目标端口（模拟「用户正开着壳」）。
      final squatter =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, configPort);
      _obs('占位 socket 绑在', squatter.port);
      HeadlessCoreStartupException? caught;
      try {
        core = await fixture.start(port: configPort);
        _obs('端口被占却启动成功（不该发生）', core?.port);
      } on HeadlessCoreStartupException catch (e) {
        caught = e;
      } finally {
        await squatter.close();
      }
      _obs('端口被占的启动错误', caught?.message);
      expect(caught, isNotNull,
          reason: '端口被占必须抛 HeadlessCoreStartupException，不许静默换端口');
      expect(caught!.message, contains('$configPort'),
          reason: '消息必须点名端口号（可归因）');
      expect(caught.message, contains('core.port'),
          reason: '消息必须给出改法：改 core.port 或 --port');
      expect(caught.message, isNot(contains('SocketException')),
          reason: '不许把裸 SocketException 原样抛给调用方');
    });
  });

  group('子进程端到端：真入口接线', () {
    late GroupTestSupport support;
    late String tempHome;
    final List<_CoreProcess> spawned = [];

    setUp(() async {
      support = await GroupTestSupport.create(prefix: 'core_fixed_port_proc_');
      // 子进程的 USERPROFILE 指向这套临时夹具的根（config / db / 附件 / 日志全在里面）。
      tempHome = support.root.path;
    });

    tearDown(() async {
      for (final proc in spawned) {
        await proc.killAndWait();
      }
      spawned.clear();
      await support.dispose();
    });

    test('配置端口 / --port 覆盖 / 端口被占 三条子进程路径', () async {
      final missing = await _subprocessPrerequisite();
      if (missing != null) {
        _obs('跳过子进程段的原因', missing);
        markTestSkipped('外部前置缺失：$missing（子进程段未验证）');
        return;
      }

      // ① 配置驱动：配置里写 core.port，**不传 --port**，启动输出里的端口必须是它。
      final configPort = await _freePort();
      support.writeConfig(
          support.minimalConfig().copyWith(corePort: configPort));
      _obs('① 子进程：配置 core.port', configPort);
      final fromConfig = await _CoreProcess.start(
        args: [
          '--config',
          support.configPath,
          '--lock',
          p.join(support.root.path, 'case1.lock'),
        ],
        tempHome: tempHome,
      );
      spawned.add(fromConfig);
      final reportedConfigPort = await fromConfig.waitForUrlPort();
      _obs('① 子进程 stdout', fromConfig.stdoutLines);
      expect(reportedConfigPort, configPort,
          reason: '没有 --port 时，真入口必须按配置 core.port 绑端口并回显它');
      expect(fromConfig.stdoutText, contains('端口来源: 配置 core.port'),
          reason: '启动输出必须写明端口来源（配置 / 参数 / 默认三种之一）');
      await _assertPingOnPort(reportedConfigPort!);
      await fromConfig.killAndWait();
      spawned.remove(fromConfig);

      // ② --port 覆盖：配置写 P1，命令行给 P2，回显必须是 P2。
      final configPort2 = await _freePort();
      final overridePort = await _freePort();
      support.writeConfig(
          support.minimalConfig().copyWith(corePort: configPort2));
      _obs('② 子进程：配置 $configPort2 + --port $overridePort', null);
      final overridden = await _CoreProcess.start(
        args: [
          '--port',
          '$overridePort',
          '--config',
          support.configPath,
          '--lock',
          p.join(support.root.path, 'case2.lock'),
        ],
        tempHome: tempHome,
      );
      spawned.add(overridden);
      final reportedOverride = await overridden.waitForUrlPort();
      _obs('② 子进程 stdout', overridden.stdoutLines);
      expect(reportedOverride, overridePort,
          reason: '--port 必须覆盖配置（真入口接线，不是只在进程内算对）');
      expect(overridden.stdoutText, contains('端口来源: --port（显式参数）'));
      await _assertPingOnPort(reportedOverride!);
      // 覆盖不改写配置。
      expect(File(support.configPath).readAsStringSync(),
          contains('"port": $configPort2'));
      await overridden.killAndWait();
      spawned.remove(overridden);

      // ③ 端口被占：占位 socket 在父进程里，子进程必须以可归因消息非零退出。
      final occupiedPort = await _freePort();
      final squatter =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, occupiedPort);
      _obs('③ 子进程：占位 socket', squatter.port);
      final blocked = await _CoreProcess.start(
        args: [
          '--port',
          '$occupiedPort',
          '--config',
          support.configPath,
          '--lock',
          p.join(support.root.path, 'case3.lock'),
        ],
        tempHome: tempHome,
      );
      spawned.add(blocked);
      final blockedExit = await blocked.waitForExit();
      await squatter.close();
      final blockedStderr = blocked.stderrLines.join('\n');
      _obs('③ 子进程退出码', blockedExit);
      _obs('③ 子进程 stderr', blocked.stderrLines);
      expect(blockedExit, isNot(0),
          reason: '端口被占必须非零退出（不许静默换端口后继续）');
      expect(blockedStderr, contains('$occupiedPort'),
          reason: '退出消息必须点名端口号');
      expect(blockedStderr, contains('core.port'),
          reason: '退出消息必须给出改法：改 core.port 或 --port');

      _obs('隔离读数', support.describeIsolation());
      expect(support.realUserDirDifferences(), isEmpty,
          reason: '子进程段的 USERPROFILE 指向临时目录，不许写用户真实 ~/.aliasagent');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}

/// 在给定端口上做一次 `core.ping`（子进程真的在服务，而不只是打印了地址）。
Future<void> _assertPingOnPort(int port) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws')
      .timeout(const Duration(seconds: 30));
  final completer = Completer<Map<String, dynamic>>();
  final sub = ws.listen((data) {
    final decoded = jsonDecode(data as String) as Map<String, dynamic>;
    if (decoded['id'] == 1 && !completer.isCompleted) {
      completer.complete(decoded);
    }
  });
  ws.add(jsonEncode({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'core.ping',
    'params': const <String, dynamic>{},
  }));
  final response = await completer.future.timeout(const Duration(seconds: 30));
  _obs('子进程 core.ping 响应', response);
  expect((response['result'] as Map)['ok'], isTrue);
  await sub.cancel();
  await ws.close();
}
