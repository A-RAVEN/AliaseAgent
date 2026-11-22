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

  final HeadlessCore core;
  final WsRpcClient ws;
  final Directory root;
  final FakeSidecar sidecar;

  static Future<GroupCoreHarness> start({FakeSidecar? sidecar}) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = Directory.systemTemp.createTempSync('group_rpc_');
    final fake = sidecar ?? FakeSidecar();
    ToolCatalog.instance.seed({
      'read_file': {'name': 'read_file'},
      'list_dir': {'name': 'list_dir'},
      'run_command': {'name': 'run_command'},
    });
    final core = await buildHeadlessCore(
      config: kGroupTestConfig,
      sidecar: fake,
      openDatabase: () => DatabaseService.openAt(root.path),
      configPath: '${root.path}${Platform.pathSeparator}config.json',
      attachmentsDir: '${root.path}${Platform.pathSeparator}attachments',
    );
    await core.start();
    final ws = await WsRpcClient.connect(core.websocketUrl);
    return GroupCoreHarness._(
        core: core, ws: ws, root: root, sidecar: fake);
  }

  /// 建组（可带 workspace）。
  Future<Map<String, dynamic>> createGroup({String? title, String? workspace}) =>
      ws.request('group.create', {
        'title': ?title,
        'workspace': ?workspace,
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

  Future<void> stop() async {
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
