// 群聊 RPC 测试的无头核心装置（change `agent-group-chat` §7）。
//
// 真 `HttpServer` + 真 WebSocket + 真 sqlite（临时目录 `openAt` 注入）+ `FakeSidecar`。
// 事件与响应都留着原文，断言前打印（TESTING.md §3.1 可观察性）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import 'fake_sidecar.dart';

/// 链在**测试侧**的上界（不是产品上限；产品的每组上限是 `maxRounds` ≤ 50）。
///
/// 出处（change `group-reactive-mode` R.6 的推导公式）：假 sidecar 单轮预期 ≤ 1s ×
/// 用例最大成员数 4 × `min(该组上限或默认 8, 3)` × 安全系数 2 = 24s。它的唯一作用是
/// 让"链不收敛 / 忘了等终态"变成**红**而不是永久挂起。
const Duration kTestChainTimeout = Duration(seconds: 24);

const AgentTypeConfig kGroupTestTemplate = AgentTypeConfig(
  name: 'general',
  provider: 'p',
  model: 'm',
  systemPrompt: '你是测试模板。',
  tools: ['read_file', 'list_dir', 'run_command'],
  maxContextTokens: 100000,
);

final AppConfig kGroupTestConfig = AppConfig(
  version: 1,
  providers: const {
    'p': ProviderConfig(apiKey: 'k', baseUrl: 'http://127.0.0.1:1'),
  },
  agentTypes: const {'general': kGroupTestTemplate},
);

class WsRpcClient {
  WsRpcClient._(this._socket) {
    _subscription = _socket.listen(_onData);
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final List<Map<String, dynamic>> events = [];
  final List<Map<String, dynamic>> responses = [];
  int _nextId = 1;

  static Future<WsRpcClient> connect(Uri uri) async {
    final socket = await WebSocket.connect(uri.toString());
    return WsRpcClient._(socket);
  }

  void _onData(dynamic data) {
    final decoded = jsonDecode(data as String) as Map<String, dynamic>;
    final id = decoded['id'];
    if (id is int && !decoded.containsKey('method')) {
      responses.add(decoded);
      _pending.remove(id)?.complete(decoded);
      return;
    }
    if (decoded['method'] == 'agent.event') {
      events.add(Map<String, dynamic>.from(decoded['params'] as Map));
    }
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
    return completer.future.timeout(const Duration(seconds: 20));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}

class GroupCoreHarness {
  GroupCoreHarness._({
    required this.core,
    required this.ws,
    required this.root,
    required this.sidecar,
  });

  /// 当前核心实例。**可变**：`restart()` 会在同一个临时根目录上重建它
  /// （change `group-chat-layout` R.14）。
  HeadlessCore core;

  /// 当前 WS 客户端（与 [core] 同代；`restart()` 后重连）。
  WsRpcClient ws;

  final Directory root;
  final FakeSidecar sidecar;

  static Future<GroupCoreHarness> start({
    FakeSidecar? sidecar,
    Directory? root,
  }) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tempRoot = root ?? Directory.systemTemp.createTempSync('group_rpc_');
    final fake = sidecar ?? FakeSidecar();
    ToolCatalog.instance.seed({
      'read_file': {'name': 'read_file'},
      'list_dir': {'name': 'list_dir'},
      'run_command': {'name': 'run_command'},
    });
    final core = await _build(tempRoot, fake);
    final ws = await WsRpcClient.connect(core.websocketUrl);
    return GroupCoreHarness._(
        core: core, ws: ws, root: tempRoot, sidecar: fake);
  }

  /// 在 [root] 上构建并启动一个无头核心（真 sqlite 路径 / 真 WS / 给定假 sidecar）。
  static Future<HeadlessCore> _build(Directory root, FakeSidecar fake) async {
    final core = await buildHeadlessCore(
      config: kGroupTestConfig,
      sidecar: fake,
      openDatabase: () => DatabaseService.openAt(root.path),
      configPath: '${root.path}${Platform.pathSeparator}config.json',
      attachmentsDir: '${root.path}${Platform.pathSeparator}attachments',
    );
    await core.start();
    return core;
  }

  /// 模拟**核心 + sidecar 重启**（change `group-chat-layout` R.14）：
  /// 等链终态 → 断 WS、停旧核心（关库）→ 清 sidecar 内存上下文（对齐 DLL 重启后
  /// 上下文全丢）→ **同一个临时根目录**上重建核心并重连 WS。
  ///
  /// 不删 [root]：存量群 / 成员 / 消息必须还在，才能验"重启后存量群仍可反应"。
  /// 也不碰用户真实 `~/.aliasagent`：数据库路径仍是临时目录。
  Future<void> restart() async {
    for (final groupId in core.groups.runningGroupIds) {
      await core.groups.waitForChain(groupId).timeout(kTestChainTimeout);
    }
    await ws.close();
    await core.stop();
    sidecar.simulateSidecarRestart();
    core = await _build(root, sidecar);
    ws = await WsRpcClient.connect(core.websocketUrl);
  }

  /// 建组（可带 workspace / 自发反应开关）。
  ///
  /// **夹具口径，不是产品默认**（change `group-reactive-mode` 任务 0.3 / design D12
  /// 的 Risks）：产品新建组默认 `reactionsEnabled = true`，但既有群聊 RPC 用例依赖
  /// 「点名后只有一个人跑」的旧语义，所以这里**缺省 `false`**。要验自发反应的用例
  /// 必须显式传 `true`。不传时 `group.list` 必须读回 `false`（7.1 之外的 0.3 用例验它）。
  Future<Map<String, dynamic>> createGroup({
    String? title,
    String? workspace,
    bool? reactionsEnabled = false,
    Object? maxRounds,
  }) =>
      ws.request('group.create', {
        'title': ?title,
        'workspace': ?workspace,
        'reactionsEnabled': ?reactionsEnabled,
        'maxRounds': ?maxRounds,
      });

  Future<Map<String, dynamic>> addMember(
    String groupId,
    String name, {
    String templateName = 'general',
    Map<String, dynamic>? overrides,
  }) =>
      ws.request('group.member.add', {
        'groupId': groupId,
        'name': name,
        'templateName': templateName,
        'overrides': ?overrides,
      });

  /// `group.chain` 的结果体（没链时 `status = idle`）。
  Future<Map<String, dynamic>> groupChain(String groupId) async {
    final response = await ws.request('group.chain', {'groupId': groupId});
    final error = response['error'];
    if (error != null) {
      throw StateError('group.chain 失败：$error');
    }
    return Map<String, dynamic>.from(response['result'] as Map);
  }

  /// 轮询 `group.chain` 到终态（异步发送的测试必须等终态再断言 / 清理；
  /// change `group-reactive-mode` R.7）。上界出处见 `kTestChainTimeout` 的注释。
  Future<Map<String, dynamic>> waitForChain(
    String groupId, {
    Duration limit = kTestChainTimeout,
  }) async {
    final deadline = DateTime.now().add(limit);
    while (true) {
      final chain = await groupChain(groupId);
      if (chain['status'] != 'running') return chain;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
            '等待组 "$groupId" 的链进入终态超时（$limit）：当前 $chain',
            limit);
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> stop() async {
    // R.7 的硬约束：**异步链未结束不得销毁侧车 / 删临时目录**。先等所有在跑的链
    // 进入终态（上界 `kTestChainTimeout`，让"忘了等终态"变成红而不是竞态）。
    for (final groupId in core.groups.runningGroupIds) {
      await core.groups.waitForChain(groupId).timeout(kTestChainTimeout);
    }
    await ws.close();
    await core.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// 用户真实目录基线（这条装置也验隔离）。
  static Map<String, Object?> realUserDirFingerprint() {
    final dir = ConfigService.configDir;
    final out = <String, Object?>{};
    for (final name in ['aliasagent.db', 'config.json', 'core.lock']) {
      final file = File('$dir${Platform.pathSeparator}$name');
      if (!file.existsSync()) {
        out[name] = null;
        continue;
      }
      final stat = file.statSync();
      out[name] = '${stat.size}@${stat.modified.millisecondsSinceEpoch}';
    }
    return out;
  }
}
