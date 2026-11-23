@Tags(['live'])
library;

// 群聊的真实模型验收（change `agent-group-chat` 任务 10.1 / 10.2）。
//
// 形态：`@Tags(['live'])` + 真实 sidecar DLL + 真实模型（`-d windows`）。隔离：
// 临时 DB（`DatabaseService.openAt`）、临时 lock、临时工作区、临时 attachments；
// `configPath` 指向用户配置的**临时副本**（绝不改用户 db/config）。
//
// 断言（隐私打**输入通道**）：
//   ① 甲用工具改了共享工作区文件，B（乙）的视图 / 快照 / **摘要请求输入** 都不含甲的
//      私有标记；
//   ② 甲的公开结论回到组里且带文件指针；
//   ③ 相邻 user 轮不导致接口报错。
//
// 断言前打印：实际工具调用（从后续请求的 tool_use 回放里读）、两次成员视图差异、
// 捕获到的摘要请求 payload。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';


void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 记录每次模型请求的 sidecar 包装（只观察，不改行为）。
class _RecordingSidecar implements ISidecar {
  _RecordingSidecar(this.inner);

  final ISidecar inner;

  /// 每次 sendMessage 的观察记录。
  final List<({String handle, String thinkingMode, String systemPrompt, String messagesJson})>
      requests = [];

  List<Map<String, dynamic>> get summaryRequests => [
        for (final r in requests)
          if (r.thinkingMode == 'summary')
            {'systemPrompt': r.systemPrompt, 'messagesJson': r.messagesJson},
      ];

  @override
  Future<bool> ensureContext(String sessionId, {String? defaultWorkspace}) =>
      inner.ensureContext(sessionId, defaultWorkspace: defaultWorkspace);

  @override
  Future<void> disposeContext(String sessionId) => inner.disposeContext(sessionId);

  @override
  void cancelRequest(String handle) => inner.cancelRequest(handle);

  @override
  WorkspaceQueryResult getWorkspace(String handle) => inner.getWorkspace(handle);

  @override
  String? setWorkspace(String handle, String path) =>
      inner.setWorkspace(handle, path);

  @override
  Future<void> sendMessage({
    required String handle,
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required String thinkingMode,
    required String thinkingEffort,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  }) {
    requests.add((
      handle: handle,
      thinkingMode: thinkingMode,
      systemPrompt: systemPrompt,
      messagesJson: messagesJson,
    ));
    return inner.sendMessage(
      handle: handle,
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      systemPrompt: systemPrompt,
      messagesJson: messagesJson,
      toolsJson: toolsJson,
      thinkingMode: thinkingMode,
      thinkingEffort: thinkingEffort,
      onChunk: onChunk,
      onToolCall: onToolCall,
      onThinking: onThinking,
      onDone: onDone,
    );
  }

  @override
  String readFile(String handle, String requestJson) =>
      inner.readFile(handle, requestJson);

  @override
  String listDir(String handle, String path) => inner.listDir(handle, path);

  @override
  String writeFile(String handle, String requestJson) =>
      inner.writeFile(handle, requestJson);

  @override
  String editFile(String handle, String requestJson) =>
      inner.editFile(handle, requestJson);

  @override
  String globFile(String handle, String requestJson) =>
      inner.globFile(handle, requestJson);

  @override
  String grepFile(String handle, String requestJson) =>
      inner.grepFile(handle, requestJson);

  @override
  Future<String> webSearch(String handle, String requestJson) =>
      inner.webSearch(handle, requestJson);

  @override
  Future<String> webFetch(String handle, String requestJson) =>
      inner.webFetch(handle, requestJson);

  @override
  Future<String> browserAvailable() => inner.browserAvailable();

  @override
  Future<String> browserNavigate(String handle, String requestJson) =>
      inner.browserNavigate(handle, requestJson);

  @override
  Future<String> browserClick(String handle, String requestJson) =>
      inner.browserClick(handle, requestJson);

  @override
  Future<String> browserType(String handle, String requestJson) =>
      inner.browserType(handle, requestJson);

  @override
  Future<String> browserSnapshot(String handle, String requestJson) =>
      inner.browserSnapshot(handle, requestJson);

  @override
  Future<String> runCommand(String handle, String requestJson) =>
      inner.runCommand(handle, requestJson);

  @override
  String readSpill(String handle, String requestJson) =>
      inner.readSpill(handle, requestJson);

  @override
  String readImage(String handle, String requestJson) =>
      inner.readImage(handle, requestJson);

  @override
  String readClipboardImage(String handle, String requestJson) =>
      inner.readClipboardImage(handle, requestJson);

  @override
  String ensureSearchInfra(String configJson) =>
      inner.ensureSearchInfra(configJson);

  @override
  String getSearchProviders() => inner.getSearchProviders();

  @override
  Future<String> loadSkill(String handle, String requestJson) =>
      inner.loadSkill(handle, requestJson);

  @override
  Future<String> callToolOnWorker(
          String toolName, String handle, String requestJson) =>
      inner.callToolOnWorker(toolName, handle, requestJson);
}

class _Ws {
  _Ws._(this.socket) {
    sub = socket.listen((data) {
      final decoded = jsonDecode(data as String) as Map<String, dynamic>;
      final id = decoded['id'];
      if (id is int && !decoded.containsKey('method')) {
        pending.remove(id)?.complete(decoded);
      } else if (decoded['method'] == 'agent.event') {
        events.add(Map<String, dynamic>.from(decoded['params'] as Map));
      }
    });
  }

  final WebSocket socket;
  late final StreamSubscription<dynamic> sub;
  final Map<int, Completer<Map<String, dynamic>>> pending = {};
  final List<Map<String, dynamic>> events = [];
  int _id = 1;

  static Future<_Ws> connect(Uri uri) async =>
      _Ws._(await WebSocket.connect(uri.toString()));

  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}]) {
    final id = _id++;
    final completer = Completer<Map<String, dynamic>>();
    pending[id] = completer;
    socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return completer.future.timeout(const Duration(seconds: 240));
  }

  Future<void> close() async {
    await sub.cancel();
    await socket.close();
  }
}

/// 轮询 `group.chain` 到终态（异步发送契约；change `group-reactive-mode` R.6 / R.7）。
///
/// [limit] 是**测试侧**上界（各调用点的推导公式在注释里）；它是保护，不是产品上限。
Future<Map<String, dynamic>> _waitChain(
    _Ws ws, String groupId, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (true) {
    final response = await ws.request('group.chain', {'groupId': groupId});
    final error = response['error'];
    if (error != null) throw StateError('group.chain 失败：$error');
    final chain = Map<String, dynamic>.from(response['result'] as Map);
    if (chain['status'] != 'running') return chain;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
          '组 "$groupId" 的链没有在 $limit 内进入终态（当前 $chain）', limit);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  test('真实模型下的组：甲的私有标记不进乙的视图/快照/摘要输入；相邻 user 轮不报错',
      () async {
    final loaded = ConfigService.load();
    final config = loaded.config;
    final complete = config != null &&
        config.providers.values.any((provider) =>
            provider.apiKey.isNotEmpty && provider.baseUrl.isNotEmpty) &&
        config.agentTypes.isNotEmpty;
    if (!complete) {
      _obs('配置门', '缺少完整 providers/agent_types ⇒ 跳过 live 用例');
      markTestSkipped('用户配置不完整（api_key / base_url / agent_types）：跳过 live 群聊用例');
      return;
    }

    // ---- 隔离：临时目录里的一份配置副本 + 临时 DB / lock / workspace / attachments。
    final root = Directory.systemTemp.createTempSync('group_live_');
    final configPath = p.join(root.path, 'config.json');
    ConfigService.save(config, configPath: configPath);
    final workspace = p.join(root.path, 'workspace');
    Directory(workspace).createSync(recursive: true);
    // 锁由 HeadlessCoreRunner 用**临时路径**取得（同一个锁文件不能两个句柄各取一次）。
    final lockPath = p.join(root.path, 'core.lock');

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final recorded = _RecordingSidecar(SidecarBridge.instance);
    HeadlessCore? core;
    _Ws? ws;
    // 清理用：**异步链未结束不得销毁侧车/删临时目录**（R.7），finally 里要等它。
    String? chainGroupId;
    try {
      core = await HeadlessCoreRunner.start(
        configPath: configPath,
        lockPath: lockPath,
        configOverride: null,
        sidecarLoader: () => recorded,
        openDatabaseOverride: () =>
            DatabaseService.openAt(p.join(root.path, 'db')),
        attachmentsDir: p.join(root.path, 'attachments'),
        backgroundFoldEnabled: true,
      );
      Directory(p.join(root.path, 'db')).createSync(recursive: true);
      ws = await _Ws.connect(core.websocketUrl);
      _obs('核心', core.url);

      final created = await ws.request('group.create', {
        'title': 'live 组',
        'workspace': workspace,
        // **本用例刻意建关闭态组**（change `group-reactive-mode` 任务 0.3）：
        // 它验的是「点名一个成员 → 只有他跑」的旧语义（私有证据、相邻 user 轮、
        // 文件指针），自发反应会让额外成员在真模型下接话、烧钱且让断言面变得
        // 不可归因。自发反应的真模型验收在 `group_reaction_live_test.dart`。
        'reactionsEnabled': false,
      });
      final groupId = (created['result'] as Map)['group']['id'] as String;
      chainGroupId = groupId;
      final groupWorkspace = recorded.getWorkspace(groupId);
      _obs('组工作区', groupWorkspace.workspace);
      expect(p.normalize(groupWorkspace.workspace ?? ''), p.normalize(workspace));

      final memberA = (await ws.request('group.member.add', {
        'groupId': groupId,
        'name': '甲',
        'templateName': config.agentTypes.keys.first,
        'overrides': {
          'systemPromptAppend': '你可以使用工具改共享工作区里的文件。'
        },
      }))['result'] as Map;
      final memberB = (await ws.request('group.member.add', {
        'groupId': groupId,
        'name': '乙',
        'templateName': config.agentTypes.keys.first,
      }))['result'] as Map;
      final aId = (memberA['member'] as Map)['id'] as String;
      final bId = (memberB['member'] as Map)['id'] as String;

      // 甲：用工具写文件（工具调用/思考是甲的**私有证据**，真实模型下无法预置标记，
      // 所以下面从落库的私有行里取本次运行独有的标识：工具调用 id 与思考签名）。
      final sendA = await ws.request('group.send', {
        'groupId': groupId,
        'speaker': aId,
        'text': '请在共享工作区里创建 note-a.txt，内容写“甲写好了”，'
            '然后用一句自包含的公开结论回复，带上文件路径。',
      });
      _obs('甲的结果', sendA['result']);
      // 异步契约（change group-reactive-mode R.7）：send 只回 started，链终态查 group.chain。
      expect((sendA['result'] as Map)['status'], 'started');
      final chainA = await _waitChain(ws, groupId, const Duration(minutes: 5));
      _obs('甲的链终态', { 'status': chainA['status'], 'stopReason': chainA['stopReason'] });
      expect(chainA['status'], isNot('failed'));

      // 打印实际工具调用（从后续请求的 tool_use 回放里读）与两次请求差异。
      final aRequests = recorded.requests
          .where((r) => r.handle == '$groupId::$aId')
          .toList();
      final aToolUses = <String>[];
      for (final request in aRequests) {
        for (final match
            in RegExp(r'"type":"tool_use"[^}]*}').allMatches(request.messagesJson)) {
          aToolUses.add(match.group(0)!);
        }
      }
      _obs('甲的实际工具调用（节选）', aToolUses.take(6).toList());
      _obs('甲的请求数', aRequests.length);
      final noteFile = File(p.join(workspace, 'note-a.txt'));
      _obs('共享工作区文件存在', noteFile.existsSync());
      if (noteFile.existsSync()) _obs('文件内容', noteFile.readAsStringSync().trim());

      // 乙：产生一条用户消息 + 一轮回复 ⇒ 视图里出现相邻 user 轮（用户消息 + 「甲 说：」）。
      final sendB = await ws.request('group.send', {
        'groupId': groupId,
        'speaker': bId,
        'text': '请复述一下甲说了什么，并确认 note-a.txt 是否存在。',
      });
      _obs('乙的结果', sendB['result']);
      expect((sendB['result'] as Map)['status'], 'started');
      final chainB = await _waitChain(ws, groupId, const Duration(minutes: 5));
      _obs('乙的链终态', { 'status': chainB['status'], 'stopReason': chainB['stopReason'] });
      expect(chainB['status'], isNot('failed'));

      final bRequests = recorded.requests
          .where((r) => r.handle == '$groupId::$bId')
          .toList();
      final bAllInput =
          bRequests.map((r) => '${r.systemPrompt}\n${r.messagesJson}').join('\n');
      final summaryInputs = [
        for (final request in recorded.summaryRequests)
          '${request['systemPrompt']}\n${request['messagesJson']}',
      ].join('\n');

      // 甲这一轮的**私有证据标识**（只该出现在甲自己的视图/摘要输入里）：
      // 工具调用 id 与思考签名都是本次运行独有的串。
      final allRows =
          ((await ws.request('message.query', {
        'sessionId': groupId,
        'pageSize': 500,
      }))['result'] as Map)['messages'] as List;
      final privateA = allRows.where((row) =>
          (row as Map)['author'] == aId &&
          row['visibility'] == 'private-to-author');
      final privateMarks = <String>{};
      for (final row in privateA) {
        final thinking = (row as Map)['thinking'];
        if (thinking is List) {
          for (final block in thinking) {
            final signature = (block as Map)['signature'];
            if (signature is String && signature.length > 12) {
              privateMarks.add(signature);
            }
          }
        }
        final toolCalls = row['toolCalls'];
        if (toolCalls is List) {
          for (final call in toolCalls) {
            final id = (call as Map)['id'];
            if (id is String && id.length > 8) privateMarks.add(id);
          }
        }
      }
      final mark = privateMarks.isEmpty ? null : privateMarks.first;
      _obs('甲的私有证据标识（样本）', mark);
      _obs('甲的私有行数', privateA.length);
      _obs('乙的请求数', bRequests.length);
      _obs('乙输入含甲的私有标识', mark != null && bAllInput.contains(mark));
      _obs('摘要请求数', recorded.summaryRequests.length);
      _obs('摘要输入含甲的私有标识',
          mark != null && summaryInputs.contains(mark));
      _obs('乙输入含「甲 说：」', bAllInput.contains('甲 说：'));

      // ① 乙的视图 / ② 快照 / ③ 摘要请求输入都不含甲的私有证据。
      expect(privateA, isNotEmpty,
          reason: '甲这一轮必须产生私有行（thinking / 工具调用）才有可验的证据');
      expect(mark, isNotNull);
      for (final identifier in privateMarks.take(5)) {
        expect(bAllInput, isNot(contains(identifier)),
            reason: '乙的请求 messages 不得含甲的私有证据（$identifier）');
        expect(summaryInputs, isNot(contains(identifier)),
            reason: '摘要请求输入（folded + 参考块）不得含甲的私有证据（$identifier）');
      }
      final viewB = await ws.request('group.view', {
        'groupId': groupId,
        'memberId': bId,
      });
      final snapshotB = jsonEncode((viewB['result'] as Map)['snapshot']);
      _obs('乙快照含甲的私有标识', snapshotB.contains(mark!));
      for (final identifier in privateMarks.take(5)) {
        expect(snapshotB, isNot(contains(identifier)),
            reason: '乙的真实上下文快照不得含甲的私有证据（$identifier）');
      }

      // 反证：甲自己的输入里能看到自己的私有证据（工具轮被回放 / 摘要输入里有）。
      final aInput = aRequests.map((r) => r.messagesJson).join('\n');
      final summaryA = recorded.summaryRequests
          .map((r) => '${r['messagesJson']}')
          .join('\n');
      _obs('甲的输入含自己的私有标识',
          privateMarks.any((m) => aInput.contains(m) || summaryA.contains(m)));
      expect(
          privateMarks.any((m) => aInput.contains(m) || summaryA.contains(m)),
          isTrue,
          reason: '反证：甲自己的私有证据确实被写入了（不是两边都丢）');

      // ② 甲的公开结论回到组里且带文件指针。
      final messages = await ws.request('message.query', {
        'sessionId': groupId,
        'pageSize': 200,
      });
      final rows = (messages['result'] as Map)['messages'] as List;
      final publicA = rows.where((row) =>
          (row as Map)['author'] == aId &&
          row['visibility'] == 'public' &&
          (row['content'] as String).isNotEmpty);
      _obs('甲的公开回复', publicA.map((row) => (row as Map)['content']).toList());
      expect(publicA, isNotEmpty);
      expect(
          publicA.any((row) => ((row as Map)['content'] as String).contains('note-a.txt')),
          isTrue,
          reason: '甲的公开结论必须带文件指针');

      // ③ 相邻 user 轮没有导致接口报错：两轮都 completed，且没有任何 turn.failed。
      final failures = ws.events
          .where((event) => event['type'] == 'turn.failed')
          .toList();
      _obs('turn.failed 事件', failures);
      expect(failures, isEmpty, reason: '相邻 user 轮不得导致接口报错');
      // 组事件带身份。**按事件类型断言**（change `group-reactive-mode` 任务 0.3 / R.2）：
      // 成员运行事件必须带 memberId；组服务自己写入的用户消息（异步契约下**所有**发送
      // 都由组服务写）没有成员可归，允许为空 —— 判据按类型分流。
      const memberRunTypes = {
        'assistant.message',
        'assistant.chunk',
        'tool.call',
        'tool.result',
        'agent.streaming',
        'turn.completed',
        'context.snapshot',
        'agent.metering',
        'thinking.delta',
        'thinking.block',
        'session.title',
      };
      final groupEvents = ws.events.where((event) => event['groupId'] == groupId);
      expect(groupEvents, isNotEmpty);
      for (final event in groupEvents.take(5)) {
        _obs('事件身份', '${event['type']}/${event['memberId']}');
      }
      for (final event in groupEvents) {
        if (!memberRunTypes.contains(event['type'])) continue;
        expect(event['memberId'], isNotNull,
            reason: '成员运行事件（${event['type']}）必须带 memberId，payload='
                '${event['data']}');
      }
    } finally {
      // R.7：**异步链未结束不得销毁侧车 / 删临时目录**。这里先尝试等链进入终态；
      // 1 分钟是"没有实测单轮耗时可用时"的清理保护（不是产品上限），超时也继续清理
      // （不掩盖原来的失败）。
      if (ws != null && chainGroupId != null) {
        try {
          await _waitChain(ws, chainGroupId, const Duration(minutes: 1));
        } catch (waitError) {
          // ignore: avoid_print
          print('[OBS] 清理前等链终态失败（已继续清理）：$waitError');
        }
      }
      await ws?.close();
      await core?.stop();
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(seconds: 600)));
}
