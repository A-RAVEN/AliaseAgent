// 核心优雅停机（change `windows-desktop-shell` 任务 0.4）。
//
// 覆盖哪几件事（每条都能在实现坏掉时变红）：
//   (a) `core.shutdown` 在 `kCoreRpcMethodNames` 里，调用返回 `{"ok": true}` ——
//       连接是**被正常回应后**由服务端关闭，不是被掐断（收不到响应就是被掐断）；
//   (b) `serveUntilShutdown()` 完成后服务器关闭（再连 WS 失败）；
//   (c) **数据完整性**：停机前建一条会话并写一条消息，用同一临时库重启后仍可读；
//   (d) 用同一锁路径能再启动一个核心（锁确实释放），并且**对第二个核心也发
//       `core.shutdown` 并等它退出**（用例收尾不留孤儿核心）。
//
// 全部临时：临时 config / `openAt` 临时库 / 临时 core.lock（照 `group_test_support`
// 的隔离约定），收尾用 `realUserDirDifferences()` 证明用户真实目录没变。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/services/database_service.dart';

import 'group_test_support.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[停机] $label: $value');
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// 在给定临时夹具上起一个核心（固定端口、临时库、假 sidecar）。
Future<HeadlessCore> _startCore(
    GroupTestSupport support, int port) async {
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

/// 发一次 `core.shutdown` 并等服务端关闭这条连接。
///
/// 返回实际观察到的现场：响应帧、关闭码、错误列表 —— 断言前先打印（可观察）。
class _ShutdownOutcome {
  _ShutdownOutcome({
    required this.response,
    required this.closeCode,
    required this.errors,
    required this.framesBeforeClose,
  });

  final Map<String, dynamic> response;
  final int? closeCode;
  final List<String> errors;
  final List<String> framesBeforeClose;
}

Future<_ShutdownOutcome> _callShutdown(Uri websocketUri) async {
  final socket = await WebSocket.connect(websocketUri.toString())
      .timeout(const Duration(seconds: 30));
  final responseCompleter = Completer<Map<String, dynamic>>();
  final doneCompleter = Completer<void>();
  final errors = <String>[];
  final frames = <String>[];
  final sub = socket.listen((data) {
    final text = data is String ? data : '<二进制帧>';
    frames.add(text);
    try {
      final decoded = jsonDecode(data as String) as Map<String, dynamic>;
      if (decoded['id'] == 1 && !responseCompleter.isCompleted) {
        responseCompleter.complete(decoded);
      }
    } catch (_) {
      // 非 JSON 帧不影响本用例的判据：响应帧由 id 识别。
    }
  }, onError: (Object error) {
    errors.add('$error');
  }, onDone: () {
    if (!doneCompleter.isCompleted) doneCompleter.complete();
  });
  socket.add(jsonEncode({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'core.shutdown',
    'params': const <String, dynamic>{},
  }));
  final response =
      await responseCompleter.future.timeout(const Duration(seconds: 30));
  // 服务端应当自己关掉这条连接（停机的一部分）；等它关，别用本地 close 掩盖。
  await doneCompleter.future.timeout(const Duration(seconds: 30));
  final closeCode = socket.closeCode;
  await sub.cancel();
  return _ShutdownOutcome(
    response: response,
    closeCode: closeCode,
    errors: errors,
    framesBeforeClose: frames,
  );
}

/// 一路 WS 客户端：把「收到什么、按什么顺序、何时被关闭」记成一条时间线。
///
/// 任务 2.3 要求断言**事件序列**（不能只看「最后进程退了」），所以这里把每个帧
/// 压成 `event:<type>` / `response:<id>` / `closed(<code>)` 字符串，测试结束时打印。
class _RecordingWs {
  _RecordingWs._(this._socket) {
    _sub = _socket.listen((data) {
      final decoded = jsonDecode(data as String) as Map<String, dynamic>;
      frames.add(decoded);
      final id = decoded['id'];
      if (id is int && !decoded.containsKey('method')) {
        timeline.add('response:$id');
        final completer = _pending.remove(id);
        if (completer != null && !completer.isCompleted) {
          completer.complete(decoded);
        }
        return;
      }
      if (decoded['method'] == 'agent.event') {
        final params = Map<String, dynamic>.from(decoded['params'] as Map);
        events.add(params);
        timeline.add('event:${params['type']}');
      }
    }, onError: (Object error) {
      errors.add('$error');
    }, onDone: () {
      closeCode = _socket.closeCode;
      timeline.add('closed(${_socket.closeCode})');
      if (!_closed.isCompleted) _closed.complete();
    });
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _sub;
  final List<Map<String, dynamic>> frames = [];
  final List<Map<String, dynamic>> events = [];
  final List<String> timeline = [];
  final List<String> errors = [];
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Completer<void> _closed = Completer<void>();
  int? closeCode;
  int _nextId = 1;

  static Future<_RecordingWs> connect(String url) async {
    final socket = await WebSocket.connect(url)
        .timeout(const Duration(seconds: 30));
    return _RecordingWs._(socket);
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return completer.future.timeout(const Duration(seconds: 60));
  }

  Future<Map<String, dynamic>> waitForEvent(
    String type, {
    bool Function(Map<String, dynamic> data)? where,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final event in events) {
        if (event['type'] != type) continue;
        final data = Map<String, dynamic>.from(event['data'] as Map? ?? {});
        if (where == null || where(data)) return event;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('等待事件 "$type" 超时；已收到时间线=$timeline；错误=$errors');
  }

  Future<void> waitForClose({Duration timeout = const Duration(seconds: 60)}) =>
      _closed.future.timeout(timeout);

  /// 在时间线上打一个外部标记（测试自己的动作，便于断言"事件在它之后"）。
  void mark(String label) => timeline.add('marker:$label');

  int indexOfPrefix(String prefix) =>
      timeline.indexWhere((entry) => entry.startsWith(prefix));

  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
    await _sub.cancel();
  }
}

void main() {
  // 本文件是 `test()` + 真实 IO（HttpServer / WebSocket / sqlite）。
  // **不要**初始化 TestWidgetsFlutterBinding（它会装 HttpOverrides 拦截所有请求）。

  test('core.shutdown：清单里有、回 ok 后被正常关闭；serveUntilShutdown 关服务器并放锁', () async {
    final support = await GroupTestSupport.create(prefix: 'core_shutdown_');
    final port = await _freePort();
    support.writeConfig(support.minimalConfig().copyWith(corePort: port));
    HeadlessCore? core;
    try {
      core = await _startCore(support, port);
      _obs('核心端口', core.port);
      _obs('kCoreRpcMethodNames 含 core.shutdown',
          kCoreRpcMethodNames.contains('core.shutdown'));
      expect(kCoreRpcMethodNames, contains('core.shutdown'),
          reason: 'kCoreRpcMethodNames 与 _registerMethods 必须一致（漏注册即抛错）');

      final reportFuture = core.serveUntilShutdown();
      final outcome = await _callShutdown(core.websocketUrl);
      _obs('shutdown 响应帧', outcome.response);
      _obs('收到的帧', outcome.framesBeforeClose);
      _obs('服务端关闭码', outcome.closeCode);
      _obs('WS 错误', outcome.errors);
      expect(outcome.response['result'], {'ok': true},
          reason: '先回包、后停机：调用方必须收到 {ok:true} 而不是被掐断');
      expect(outcome.errors, isEmpty,
          reason: '连接应被正常关闭（不是错误中断）');

      final report =
          await reportFuture.timeout(const Duration(seconds: 60));
      _obs('停机报告 warnings', report.warnings);
      _obs('停机报告 exitCode', report.exitCode);
      expect(report.warnings, isEmpty, reason: '本次停机没有告警');
      expect(report.exitCode, 0);

      // (b) 服务器确实关了：再连 WS 必须失败（不是还能连上）。
      Object? reconnectError;
      try {
        final again = await WebSocket.connect(core.websocketUrl.toString())
            .timeout(const Duration(seconds: 10));
        await again.close();
      } catch (e) {
        reconnectError = e;
      }
      _obs('停机后再连 WS 的错误', reconnectError);
      expect(reconnectError, isNotNull,
          reason: 'serveUntilShutdown 完成后服务器必须关闭（再连应当失败）');

      _obs('隔离读数', support.describeIsolation());
      expect(support.realUserDirDifferences(), isEmpty);
    } finally {
      try {
        await core?.stop();
      } catch (_) {}
      await support.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('停机不破坏数据：同一临时库重启后可读；同一锁路径可再启动第二个核心并把它也停掉', () async {
    final support = await GroupTestSupport.create(prefix: 'core_shutdown_data_');
    final configPort = await _freePort();
    support.writeConfig(support.minimalConfig().copyWith(corePort: configPort));
    HeadlessCore? first;
    HeadlessCore? second;
    try {
      // ① 第一个核心：建一条会话 + 写一条消息。
      first = await _startCore(support, configPort);
      final session = await first.sessionRepo.create(title: '停机前的会话');
      final message = await first.messageRepo.insert(
        sessionId: session.id,
        role: 'user',
        content: '停机前写下的消息',
      );
      _obs('停机前会话', '${session.id} / ${session.title}');
      _obs('停机前消息', '${message.id} / ${message.content}');

      final reportFuture = first.serveUntilShutdown();
      final outcome = await _callShutdown(first.websocketUrl);
      _obs('第一个核心的 shutdown 响应', outcome.response);
      expect(outcome.response['result'], {'ok': true});
      final report = await reportFuture.timeout(const Duration(seconds: 60));
      _obs('第一个核心停机报告', 'warnings=${report.warnings} exit=${report.exitCode}');
      first = null;

      // ② 同一把锁、同一个临时库：再启动第二个核心必须成功（锁确实释放了）。
      second = await _startCore(support, configPort);
      _obs('第二个核心端口', second.port);
      expect(second.port, configPort, reason: '固定端口：重启后仍绑同一个端口');

      // (c) 数据完整性：会话与消息仍可读（正常关库路径，不是被强杀的残留）。
      final rereadSession = await second.sessionRepo.get(session.id);
      final messages = await second.messageRepo.queryBySession(session.id);
      _obs('重启后会话', '${rereadSession?.id} / ${rereadSession?.title}');
      _obs('重启后消息', [for (final m in messages) '${m.role}: ${m.content}']);
      expect(rereadSession, isNotNull, reason: '停机不该丢掉会话行');
      expect(rereadSession!.title, '停机前的会话');
      expect(messages.map((m) => m.content), contains('停机前写下的消息'));

      // ③ 第二个核心也必须被礼停并等它退出（不许留孤儿核心）。
      final secondReport = second.serveUntilShutdown();
      final secondOutcome = await _callShutdown(second.websocketUrl);
      _obs('第二个核心的 shutdown 响应', secondOutcome.response);
      expect(secondOutcome.response['result'], {'ok': true});
      final finalReport =
          await secondReport.timeout(const Duration(seconds: 60));
      _obs('第二个核心停机报告',
          'warnings=${finalReport.warnings} exit=${finalReport.exitCode}');
      expect(finalReport.exitCode, 0);
      second = null;

      _obs('隔离读数', support.describeIsolation());
      expect(support.realUserDirDifferences(), isEmpty,
          reason: '本用例不许写用户真实 ~/.aliasagent');
    } finally {
      try {
        await first?.stop();
      } catch (_) {}
      try {
        await second?.stop();
      } catch (_) {}
      await support.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('停机与在途发送的顺序：先取消 → 等在途整轮收尾（收尾帧先到）→ 才关通道', () async {
    final support =
        await GroupTestSupport.create(prefix: 'core_shutdown_inflight_');
    final port = await _freePort();
    support.writeConfig(support.minimalConfig().copyWith(corePort: port));
    HeadlessCore? core;
    _RecordingWs? observer;
    _RecordingWs? shutdownClient;
    try {
      core = await _startCore(support, port);
      final session = await core.sessionRepo.create(title: '在途会话');
      _obs('在途会话', '${session.id} / ${session.title}');

      // 让这一轮卡在「模型还在流」的窗口里：gate 未放行时 sendMessage 不返回。
      support.sidecar.queueChunk('停机前的流式片段');
      support.sidecar.queueDone();
      support.sidecar.gateNextSend();

      observer = await _RecordingWs.connect(core.websocketUrl.toString());
      shutdownClient =
          await _RecordingWs.connect(core.websocketUrl.toString());

      final sendFuture = observer.request('agent.send', {
        'sessionId': session.id,
        'text': '你好',
      });
      final streamingOn =
          await observer.waitForEvent('agent.streaming', where: (data) {
        return data['streaming'] == true;
      });
      _obs('在途证据：已收到 agent.streaming', streamingOn['data']);

      // 停机请求从**另一条**连接发出（服务端会把这条连接关掉）。
      final reportFuture = core.serveUntilShutdown();
      final shutdownResponse = await shutdownClient.request('core.shutdown');
      _obs('shutdown 响应', shutdownResponse);
      expect(shutdownResponse['result'], {'ok': true});
      observer.mark('shutdown-ok');

      // ① 取消已发生（FakeSidecar 记录的 cancelRequest 次数）。停机信号是异步传递的
      //    （响应刷出 → 等待方收到信号 → stop()），这里等它一下再看。
      final cancelDeadline = DateTime.now().add(const Duration(seconds: 15));
      while (support.sidecar.cancelCount == 0 &&
          DateTime.now().isBefore(cancelDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      _obs('cancel 调用次数', support.sidecar.cancelCount);
      expect(support.sidecar.cancelCount, greaterThan(0),
          reason: '停机必须先对在途 Agent 调 cancel()（置取消标志）');
      // 此刻 gate 还没放行：在途整轮没结束，它的响应帧必然还没到（通道仍开着）。
      final sendFrameArrived =
          observer.frames.any((frame) => frame['id'] == 1);
      _obs('cancel 之后：send 响应是否已到', sendFrameArrived);
      expect(sendFrameArrived, isFalse,
          reason: '整轮还没收尾时不该已经有 send 响应（gate 未放行）');
      _obs('此刻 observer 时间线', observer.timeline);

      // ② 放行在途整轮：收尾帧必须仍能经 WS 送达（说明 stop() 还在等 waitForRounds()）。
      support.sidecar.releaseGate();
      Map<String, dynamic>? sendResponse;
      Object? sendError;
      try {
        sendResponse = await sendFuture;
      } catch (e) {
        // 响应帧本身可能和关通道抢跑；收尾事件（下面断言）才是顺序判据。
        sendError = e;
      }
      _obs('在途 send 的最终响应', sendResponse ?? '（未能送达：$sendError）');
      if (sendResponse != null) {
        expect((sendResponse['result'] as Map)['status'], 'cancelled',
            reason: '取消生效：在途整轮以 cancelled 收尾，不是 completed');
      }

      final report = await reportFuture.timeout(const Duration(seconds: 60));
      _obs('停机报告', report.toString());
      expect(report.warnings, isEmpty, reason: '本次停机没有告警');
      expect(report.exitCode, 0);

      // ③ 事件序列：在途整轮的**最终响应**（status=cancelled，说明整轮真的收尾了）
      //    与「流式结束」事件都出现在「发起停机」之后、「通道关闭」之前 —— 这一条在
      //    删掉 stop() 里的 `await waitForRounds()` 时必须变红（见任务 2.3 变异记录）。
      await observer.waitForClose();
      final timeline = observer.timeline;
      _obs('observer 时间线', timeline);
      final shutdownMark = observer.indexOfPrefix('marker:shutdown-ok');
      final sendResponseIndex = observer.indexOfPrefix('response:1');
      final closedIndex = observer.indexOfPrefix('closed(');
      final streamingEvents = [
        for (final event in observer.events)
          if (event['type'] == 'agent.streaming') event,
      ];
      _obs('流式开关事件', [for (final e in streamingEvents) e['data']]);
      expect(streamingEvents.length, greaterThanOrEqualTo(2),
          reason: '应当看到「流式开始」与「流式结束」两次 agent.streaming');
      expect((streamingEvents.last['data'] as Map)['streaming'], isFalse);
      _obs('关键下标',
          'shutdown=$shutdownMark sendResponse=$sendResponseIndex '
          'closed=$closedIndex');
      expect(shutdownMark, greaterThanOrEqualTo(0));
      expect(closedIndex, greaterThan(shutdownMark),
          reason: '观察者连接最终应被服务端关闭');
      expect(sendResponseIndex, greaterThan(shutdownMark),
          reason: '在途整轮的最终响应必须在停机请求之后仍被送达（通道还没关）');
      expect(sendResponseIndex, lessThan(closedIndex),
          reason: '在途整轮收尾必须早于通道关闭 —— 少 waitForRounds() 这一步就会反');
      expect(sendResponse != null, isTrue,
          reason: '在途整轮的响应应当经 WS 送达（被等待收尾，而不是被掐断）');
      expect(support.sidecar.cancelCount, greaterThan(0));

      _obs('隔离读数', support.describeIsolation());
      expect(support.realUserDirDifferences(), isEmpty,
          reason: '本用例不许写用户真实 ~/.aliasagent');
    } finally {
      try {
        await observer?.close();
      } catch (_) {}
      try {
        await shutdownClient?.close();
      } catch (_) {}
      try {
        await core?.stop();
      } catch (_) {}
      await support.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
