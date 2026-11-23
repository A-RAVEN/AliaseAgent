// 自发反应的**真实模型**验收（change `group-reactive-mode` R.6 / 任务 7.1 / 7.2 / 7.3）。
//
// 形态与 `group_chat_live_test.dart` 一致：真 sidecar DLL + 真模型 + 临时隔离目录。
// 本文件是 suite 本体，两个入口共用：
//   - `integration_test/group_reaction_live_test.dart`（`-d windows` 设备态入口）
//   - `test/live/group_reaction_live_test.dart`（无窗口入口）
//
// **异步契约（R.6）**：`group.send` 只断言 `started` 且在链结束前返回；链的终态、轮数、
// stopReason 与 steps 一律**轮询 `group.chain`** 读，不再从 send 回包里取。
//
// 场景（design D12 的 live 部分 / R.6）：
//   ① 建组（**默认自发反应开启**）+ 按顺序加甲乙丙；第一段用户消息「丙讲笑话，甲乙评价」
//      （裸名点名、不带 `@`，验身份锚 + 名点识别）：第一个成员公开发言的 `author` 必须是丙；
//      链终态 `stopReason ∈ {all_passed, round_cap}`、`rounds <= 上限`、无 `turn.failed`；
//      R.9 起**允许成员结构化沉默**，只打印沉默率，不强制每人 replied；
//   ② 第二段用户消息「@乙 具体说说哪里好笑」（不选 speaker，验定向）：乙的 step 满足
//      `source == mention && status == replied && publicSeq != null`，且没有 `forced_*`；
//   ③ 两段都打印每轮 triggerSeq / 成员 / 状态与时间线公开行（人读现场），并调用
//      `web/e2e/group_reactions.mjs` 截图（断言 PNG 存在且字节数非 0）；
//   ④ 隔离核对：真实 `~/.aliasagent` 的 db / config / core.lock 运行前后指纹不变
//      （`logs/` 是已知副作用，只记录不比断言）。
//
// **「实质评价」不靠结构断言冒充**：结构断言只保留可失败的部分（replied 一旦出现就
// 非空、非旧哨兵、有公开行），另外加一条**测试侧纯恭维启发式**（整条匹配「说得好」
// 「不错」「哈哈」等即失败）；真正的"实质"由主循环读 finalText/时间线（+ `read_image`）
// 判断，报告要写判断口径。**沉默率是观察指标**：默认沉默提示词是经验性的，`round_cap`
// 仍是可靠兜底，不保证模型一定沉默。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/group_reaction.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

// 真实用户目录的运行前后指纹核对（与群聊 integration 夹具同一个实现）。
import '../test/integration/group_test_support.dart' show RealUserDirBaseline;

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 一条公开时间线行的可读形态。
String _rowLine(Map<String, dynamic> row) =>
    '${(row['author'] as String?) ?? 'user'}: ${row['content']}';

/// 纯恭维启发式（**测试侧**判据，不冒充语义检查）：整条只有客气话就失败。
///
/// 命中条件：去掉标点与空白后，整条文本只由这些短语构成（或字符数很短且含其中之一）。
bool looksLikePureCompliment(String text) {
  const phrases = [
    '说得好',
    '不错',
    '哈哈',
    '有意思',
    '好笑',
    '有趣',
    '很棒',
    '太好了',
    '同意',
  ];
  final stripped = text.replaceAll(RegExp(r'[\s，。！？、,.!?~～…"“”‘’()（）]'), '');
  if (stripped.isEmpty) return true;
  var remainder = stripped;
  for (final phrase in phrases) {
    remainder = remainder.replaceAll(phrase, '');
  }
  final residual = remainder.replaceAll(RegExp(r'[\[/\]PASS]'), '');
  // 去掉恭维短语后只剩很少的字 ⇒ 基本是纯恭维。
  return residual.length <= 2;
}

/// 记录每次模型请求（只观察，不改行为）。
class RecordingSidecar implements ISidecar {
  RecordingSidecar(this.inner);

  final ISidecar inner;

  final List<
      ({
        String handle,
        String thinkingMode,
        String systemPrompt,
        String messagesJson,
      })> requests = [];

  List<Map<String, dynamic>> get summaryRequests => [
        for (final request in requests)
          if (request.thinkingMode == 'summary')
            {
              'systemPrompt': request.systemPrompt,
              'messagesJson': request.messagesJson,
            },
      ];

  @override
  Future<bool> ensureContext(String sessionId, {String? defaultWorkspace}) =>
      inner.ensureContext(sessionId, defaultWorkspace: defaultWorkspace);

  @override
  Future<void> disposeContext(String sessionId) =>
      inner.disposeContext(sessionId);

  @override
  void cancelRequest(String handle) => inner.cancelRequest(handle);

  @override
  WorkspaceQueryResult getWorkspace(String handle) =>
      inner.getWorkspace(handle);

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

class LiveWs {
  LiveWs._(this.socket) {
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

  static Future<LiveWs> connect(Uri uri) async =>
      LiveWs._(await WebSocket.connect(uri.toString()));

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
    // 单个 RPC 的等待上界：只在"没有推导信息"时保护（心跳/取消等便宜调用）。
    // 链的等待上界由 waitChain 的推导公式给（见调用处），不是产品上限。
    return completer.future.timeout(const Duration(minutes: 5));
  }

  Future<void> close() async {
    await sub.cancel();
    await socket.close();
  }
}

/// 轮询 `group.chain` 直到链进入终态（异步发送契约，R.6）。
///
/// [limit] 是**总上界**（测试侧推导，见调用点）；[stallLimit] 是**连续无进展上界**：
/// 只要 `status`/`rounds`/`steps` 有推进就重新计时，只有"长时间完全没有新步骤"才判挂起。
///
/// 两者都不是产品上限。为什么要看门狗：真模型的单轮耗时波动极大（同一轮既可能 5s
/// 也可能 20s），任何"总时长 = 单轮 × 步数"的固定公式都可能误杀**仍在正常推进**的链；
/// 而"链停下来不再产生步骤"才是要抓的缺陷。
Future<Map<String, dynamic>> waitChain(
    LiveWs ws, String groupId, Duration limit,
    {Duration? stallLimit}) async {
  final deadline = DateTime.now().add(limit);
  var lastProgressAt = DateTime.now();
  var lastSignature = '';
  while (true) {
    final response = await ws.request('group.chain', {'groupId': groupId});
    final error = response['error'];
    if (error != null) throw StateError('group.chain 失败：$error');
    final chain = Map<String, dynamic>.from(response['result'] as Map);
    final stepCount = ((chain['steps'] as List?) ?? const []).length;
    final signature = '${chain['status']}/${chain['rounds']}/$stepCount';
    if (signature != lastSignature) {
      lastSignature = signature;
      lastProgressAt = DateTime.now();
    }
    if (chain['status'] != 'running') return chain;
    final now = DateTime.now();
    if (stallLimit != null && now.difference(lastProgressAt) > stallLimit) {
      throw TimeoutException(
          '组 "$groupId" 的链连续 ${stallLimit.inSeconds}s 没有任何进展'
          '（status/rounds/steps 都没动）：status=${chain['status']} '
          'rounds=${chain['rounds']} steps=$stepCount',
          stallLimit);
    }
    if (now.isAfter(deadline)) {
      throw TimeoutException(
          '组 "$groupId" 的链没有在总上界（$limit）内进入终态：'
          'status=${chain['status']} rounds=${chain['rounds']} steps=$stepCount',
          limit);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// 打印一条链的全部步骤（断言前先留现场）。
void _dumpChain(String label, Map<String, dynamic> chain) {
  final steps = (chain['steps'] as List?) ?? const [];
  // ignore: avoid_print
  print('[OBS] $label status=${chain['status']} stopReason=${chain['stopReason']} '
      'rounds=${chain['rounds']} triggerSeq=${chain['triggerSeq']} '
      'steps=${steps.length}');
  for (final raw in steps) {
    final step = raw as Map;
    // ignore: avoid_print
    print('[OBS]   trigger=${step['triggerSeq']} member=${step['memberId']} '
        'source=${step['source']} status=${step['status']} '
        'publicSeq=${step['publicSeq']} finalText=${step['finalText']}');
  }
}

/// R.9：打印一段链的**沉默率**（passed / replied / empty）。
///
/// 这是观察指标，不是硬门：提示词是经验性的，`round_cap` 仍是可靠兜底；
/// 只把数据打出来供人判断「默认沉默是否生效、是否出现 all_passed」。
void _reportSilence(String label, List<Map<String, dynamic>> steps) {
  final byRound = <int, List<String>>{};
  for (final step in steps) {
    final trigger = (step['triggerSeq'] as num?)?.toInt() ?? 0;
    byRound.putIfAbsent(trigger, () => []).add('${step['status']}');
  }
  for (final entry in byRound.entries) {
    final statuses = entry.value;
    final passed = statuses
        .where((status) => status == 'passed' || status == 'forced_pass')
        .length;
    final replied = statuses.where((status) => status == 'replied').length;
    final empty = statuses
        .where((status) => status == 'empty' || status == 'forced_empty')
        .length;
    // ignore: avoid_print
    print('[OBS] $label 轮 trigger=${entry.key}：passed=$passed replied=$replied '
        'empty=$empty（共 ${statuses.length} 步）');
  }
  final counts = <String, int>{};
  for (final step in steps) {
    final status = '${step['status']}';
    counts[status] = (counts[status] ?? 0) + 1;
  }
  final passed = (counts['passed'] ?? 0) + (counts['forced_pass'] ?? 0);
  final replied = counts['replied'] ?? 0;
  final empty = (counts['empty'] ?? 0) + (counts['forced_empty'] ?? 0);
  final total = passed + replied + empty;
  final ratio = total == 0 ? 'n/a' : '${(passed / total * 100).toStringAsFixed(0)}%';
  // ignore: avoid_print
  print('[OBS] $label 沉默率合计：passed=$passed replied=$replied empty=$empty '
      'total=$total ⇒ $ratio；状态分布=$counts');
}

/// 自发反应的 live suite（两个入口共用）。
void runGroupReactionLiveSuite() {
  test('真实模型自发反应：异步 started → 链收敛/上限 → @乙 定向必应（隔离 + 截图）',
      () async {
    // ---- 配置门（与既有 live 用例同一口径：缺配置就 skip，不伪绿） ----
    final loaded = ConfigService.load();
    final config = loaded.config;
    final complete = config != null &&
        config.providers.values.any((provider) =>
            provider.apiKey.isNotEmpty && provider.baseUrl.isNotEmpty) &&
        config.agentTypes.isNotEmpty;
    if (!complete) {
      _obs('配置门', '缺少完整 providers/agent_types ⇒ 跳过 live 用例');
      markTestSkipped('用户配置不完整（api_key / base_url / agent_types）：跳过 live 自发反应用例');
      return;
    }

    // ---- 隔离：临时目录里的一份配置副本 + 临时 DB / lock / workspace / attachments ----
    final root = Directory.systemTemp.createTempSync('group_reaction_live_');
    final configPath = p.join(root.path, 'config.json');
    ConfigService.save(config, configPath: configPath);
    final workspace = p.join(root.path, 'workspace');
    Directory(workspace).createSync(recursive: true);
    final attachmentsDir = p.join(root.path, 'attachments');
    Directory(attachmentsDir).createSync(recursive: true);
    final lockPath = p.join(root.path, 'core.lock');
    final baseline = RealUserDirBaseline.capture();
    // ignore: avoid_print
    print('[OBS] ${baseline.describe()}');

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final recorded = RecordingSidecar(SidecarBridge.instance);
    HeadlessCore? core;
    LiveWs? ws;
    var failureDump = '';
    String? groupId;
    // 清理前要等终态的所有组（主组 + 单成员探针组；R.7：链未结束不得销毁侧车/删目录）。
    final chainGroupIds = <String>[];
    // 清理前等链终态的上界（R.7：异步链未结束不得销毁侧车/删临时目录）。
    // 有实测 T 时用推导出的每段上界；没有时用一个保护值（不是产品上限）。
    Duration? cleanupBound;
    try {
      core = await HeadlessCoreRunner.start(
        configPath: configPath,
        lockPath: lockPath,
        configOverride: null,
        sidecarLoader: () => recorded,
        openDatabaseOverride: () =>
            DatabaseService.openAt(p.join(root.path, 'db')),
        attachmentsDir: attachmentsDir,
        // 反应验收不测压缩：关掉后台折叠，避免额外的摘要模型调用混进 steps/时间线。
        backgroundFoldEnabled: false,
      );
      Directory(p.join(root.path, 'db')).createSync(recursive: true);
      ws = await LiveWs.connect(core.websocketUrl);
      _obs('核心', core.url);

      final templateName = config.agentTypes.keys.first;

      // ---- R.6 超时上界推导：**单成员定向轮**实测 T ----
      // 产品侧的上限是每组 `maxRounds`（本组显式 4）；下面只是**测试侧**等待上界：
      //   每段上界 = 单轮实测 T × 成员数 3 × 该组上限 × 安全系数 2
      // 出处：T 由下面这个**关闭自发反应的探针组**跑一轮单成员定向轮实测（一个完整的
      // 模型生成 + 落库 + RPC 往返）；成员数取 3（甲/乙/丙）；上限取 4；2 是模型抖动/
      // 重试的安全系数。**不是产品上限，也不是拍脑袋的短墙钟。**
      //
      // 为什么单独建关闭态探针组：2026-11-22 的 live 复跑（a）用「请只回一句收到」在
      // 开启态探针，T≈1.7s 但真实笑话/评价轮约 8s/步，39.9s 上界在第 5 步就误判超时；
      // （b）改用长探针文本后，开启态探针本身会跑满 4 轮×3 成员（数十次生成长文本）而
      // 撞探针保护。**关闭态 + 单成员 + 定向轮**才真正是"一轮"的耗时，既只花一次模型
      // 调用、又能控制输出体裁。
      //
      // 探针文本必须与真实段**同体裁、同量级**：本 suite 的第一段就是"讲笑话 + 评价"。
      // 用「两三句话介绍自己」实测 T≈2.3s，而笑话/评价轮约 8s/步（长回复的流式生成
      // 慢数倍）—— T 偏小会把上界又压回分钟以内。所以探针直接让单个成员"讲一个短笑话
      // 并解释笑点"，让 T 代表真实长回复；再乘 3 成员 × 上限 4 × 安全系数 2（最坏
      // 12 步，上界 24×T 是它的两倍）。
      const probeBound = Duration(minutes: 3); // 单轮探针的保护上界（不是产品上限）
      final probeCreated = await ws.request('group.create', {
        'title': 'reaction live 探针组',
        'workspace': workspace,
        'reactionsEnabled': false,
      });
      final probeGroup = (probeCreated['result'] as Map)['group'] as Map;
      final probeGroupId = probeGroup['id'] as String;
      chainGroupIds.add(probeGroupId);
      expect(probeGroup['reactionsEnabled'], isFalse, reason: '探针组必须是安静态');
      final probeMemberAdded = await ws.request('group.member.add', {
        'groupId': probeGroupId,
        'name': '探针',
        'templateName': templateName,
        // 反应链验收不需要工具：零工具成员保证每一步只有一次模型请求（有界）。
        // 实测（2026-11-22 live 复跑）真实成员会调用 `spawn_subagent`，子 Agent 的
        // 多轮模型调用会把**一个成员轮**拉到远超 120s 模型请求超时，单步耗时不可界，
        // 既让等待上界失效、也烧掉大量 token。工具使用由 `group_chat_live_test` 覆盖。
        'overrides': const {'toolsSubset': <String>[]},
      });
      final probeMemberId =
          ((probeMemberAdded['result'] as Map)['member'] as Map)['id'] as String;
      final probeStart = DateTime.now();
      final probeResponse = await ws.request('group.send', {
        'groupId': probeGroupId,
        'speaker': probeMemberId,
        'text': '请讲一个三句话的短笑话，再用一句话解释笑点在哪里。',
      });
      expect((probeResponse['result'] as Map)['status'], 'started');
      final probeChain = await waitChain(ws, probeGroupId, probeBound);
      final probeT = DateTime.now().difference(probeStart);
      final probeSteps = ((probeChain['steps'] as List?) ?? const []).length;
      _obs('探针链（关闭态单成员定向轮）', {
        'status': probeChain['status'],
        'stopReason': probeChain['stopReason'],
        'rounds': probeChain['rounds'],
        'steps': probeSteps,
      });
      _obs('单轮实测 T（该轮总耗时）', probeT);
      expect(probeChain['status'], isNot('failed'), reason: '探针轮不应失败');
      expect(probeSteps, 1, reason: '关闭态单成员定向轮必须只有一个步骤');

      // ---- 建组（**默认自发反应开启**）+ 显式设一个适中上限 + 按顺序加甲乙丙 ----
      // live 测试组显式设 `maxRounds = 4`（change `group-reactive-mode` R.6 追加返工）：
      // 让链**有界**、快速收敛，等待上界才能按该 cap 推导；产品默认 8 会让真模型链
      // 跑到 8 轮×3 成员×单轮数秒，旧推导 `min(上限,3)` 把上界压到 19s 左右必然误判超时。
      // 4 仍是真实可用的组设置（范围 1..50），不是测试专用开关。
      const liveMaxRounds = 4;
      final created = await ws.request('group.create', {
        'title': 'reaction live 组',
        'workspace': workspace,
        'maxRounds': liveMaxRounds,
      });
      final group = (created['result'] as Map)['group'] as Map;
      groupId = group['id'] as String;
      chainGroupIds.add(groupId);
      _obs('组', {
        'id': groupId,
        'reactionsEnabled': group['reactionsEnabled'],
        'maxRounds': group['maxRounds'],
      });
      expect(group['reactionsEnabled'], isTrue, reason: '新建组默认开启自发反应');
      expect(group['maxRounds'], liveMaxRounds, reason: '建组时显式设的上限必须回读');
      final groupMaxRounds =
          (group['maxRounds'] as num?)?.toInt() ?? kDefaultMaxReactionRounds;
      expect(groupMaxRounds, liveMaxRounds);

      final memberIds = <String, String>{};
      for (final name in ['甲', '乙', '丙']) {
        final added = await ws.request('group.member.add', {
          'groupId': groupId,
          'name': name,
          'templateName': templateName,
          // 同上：零工具成员 ⇒ 每个成员轮至多一次模型请求（120s 产品超时即上界），
          // 不会因为工具/子 Agent 把单步拉长；工具使用不在本用例的验收面内。
          'overrides': const {'toolsSubset': <String>[]},
        });
        memberIds[name] = ((added['result'] as Map)['member'] as Map)['id'] as String;
      }
      _obs('成员 id', memberIds);
      expect(memberIds.keys.toList(), ['甲', '乙', '丙'],
          reason: '加入顺序必须是甲→乙→丙（串行顺序由加入顺序决定）');

      // 等待判据（测试侧；出处是**产品侧硬限** + 本用例的成员配置）：
      //   - 本用例的成员是**零工具**（`toolsSubset: []`，见上面的 member.add）：每个
      //     成员轮至多一次模型请求；产品给每个模型请求设了硬超时——`sidecar/src/
      //     model_gateway.cpp` 的 `long timeout_secs = 120;`（`set_timeout` 没有调用方，
      //     实际生效就是 120s）。所以单个成员轮**不可能**超过 120s。
      //     （若成员带工具，`spawn_subagent` / `run_command` 会把一步拉长到远超 120s，
      //      那时 120s 就不成立——本用例刻意不用工具，工具面由 `group_chat_live_test` 覆盖。）
      //   - 单步/无进展上界 = 2 × 120s = 240s（120s 请求超时 + 本地落库/流式收尾余量）。
      //   - 最多步数 = 轮1 的 3 成员 + 之后每轮（作者排除）2 成员 × (上限-1) 轮
      //              = 3 + 2 × 3 = 9 步（本组上限 4）。
      //   - 每段总上界 = 单步上界 × 最多步数（240s × 9 = 36min，只是病态兜底；
      //     正常链在几分钟内结束，探针实测 T 仍打印出来供人读）。
      const kModelRequestTimeout = Duration(seconds: 120);
      final stallFloor = kModelRequestTimeout * 2;
      final stallFromProbe = probeT * 10;
      final stallLimit =
          stallFromProbe > stallFloor ? stallFromProbe : stallFloor;
      final maxSteps = 3 + 2 * (groupMaxRounds - 1);
      final segmentTimeout = stallLimit * maxSteps;
      final pageMargin = const Duration(seconds: 90);
      final totalBudget = segmentTimeout * 2 + pageMargin;
      cleanupBound = segmentTimeout;
      _obs('推导依据', '产品模型请求超时 120s（model_gateway.cpp）→ 无进展上界 2×120s');
      _obs('最多步数（3 + 2×(上限-1)）', maxSteps);
      _obs('推导出的单步/无进展上界', stallLimit);
      _obs('推导出的每段总上界', segmentTimeout);
      _obs('推导出的总预算（两段 + 截图余量）', totalBudget);

      /// 发一条消息：**先断言 started**，再轮询 `group.chain` 到终态并返回链。
      Future<Map<String, dynamic>> sendAndWait(String text) async {
        final response = await ws!.request('group.send', {
          'groupId': groupId,
          'text': text,
        });
        if (response['error'] != null) {
          throw StateError('group.send 失败：${response['error']}');
        }
        final started = Map<String, dynamic>.from(response['result'] as Map);
        _obs('group.send 回包', started);
        expect(started['status'], 'started',
            reason: '异步契约：group.send 必须在链结束前返回 started');
        for (final forbidden in ['steps', 'rounds', 'finalText', 'memberId']) {
          expect(started.containsKey(forbidden), isFalse,
              reason: '异步回包不再带 $forbidden（从 group.chain 读）');
        }
        return waitChain(ws, groupId!, segmentTimeout,
            stallLimit: stallLimit);
      }

      // ---- 第一段：丙讲笑话，甲乙评价（裸名点名，验身份锚 + 名点识别） ----
      final firstChain =
          await sendAndWait('丙讲一个笑话，甲和乙分别评价一下这个笑话。');
      _dumpChain('第一段', firstChain);
      final firstSteps = (firstChain['steps'] as List).cast<Map<String, dynamic>>();
      final firstChainText = jsonEncode(firstChain);
      if (firstChainText.contains('402') || firstChainText.contains('余额不足')) {
        _obs('余额不足', '第一段链出现 402/余额不足：跳过后续断言，不伪绿');
        markTestSkipped('模型余额不足（402）：live 未验证，不伪造通过');
        return;
      }
      // R.12：裸名点名「丙」必须由丙把笑话讲出来。用**丙自己的公开发言行**判作者：
      // 丙的 step 必须是 replied、publicSeq 非空，且时间线里确实有 author=丙 的公开行。
      // 注意：甲/乙在此之前说一句「请丙先贴正文」属于提示词允许的「实质性补充」，
      // 不算抢讲；判据是**讲笑话的公开行 author=丙**，不是「全场第一条必须是丙」。
      final firstPage = ((await ws.request('message.query', {
        'sessionId': groupId,
        'pageSize': 500,
      }))['result'] as Map)['messages'] as List;
      final firstPublicAssistant = [
        for (final row in firstPage)
          if ((row as Map)['visibility'] == 'public' && row['role'] == 'assistant')
            row as Map<String, dynamic>,
      ]..sort((a, b) => ((a['seq'] as num?) ?? 0)
          .compareTo((b['seq'] as num?) ?? 0));
      expect(firstPublicAssistant, isNotEmpty,
          reason: '第一段必须至少产生一条成员公开发言（丙没有回应？）');
      _obs('第一段公开行 author',
          firstPublicAssistant.map((row) => row['author']).toList());
      // R.12 对象未出现先等待：第一轮（trigger = 用户消息 seq）甲/乙必须 passed，
      // 丙才能 replied；甲乙不得在对象未出现时编造评价。
      final userSeq = ((firstPage.firstWhere(
        (row) => (row as Map)['role'] == 'user',
        orElse: () => <String, dynamic>{},
      ) as Map)['seq'] as num?)
          ?.toInt();
      expect(userSeq, isNotNull, reason: '第一段必须有用户消息作为首触发');
      final firstRound =
          firstSteps.where((step) => step['triggerSeq'] == userSeq).toList();
      _obs('第一轮步骤',
          firstRound.map((s) => '${s['memberId']}/${s['status']}').toList());
      final firstRoundByMember = <String, Map<String, dynamic>>{
        for (final step in firstRound)
          '${step['memberId']}': step,
      };
      for (final name in ['甲', '乙']) {
        final step = firstRoundByMember[memberIds[name]];
        expect(step, isNotNull, reason: '$name 必须有第一轮步骤');
        expect(step!['status'], 'passed',
            reason: '$name 在对象（丙的笑话）未出现时必须 PASS 等待，不能编造评价');
      }
      final cFirst = firstRoundByMember[memberIds['丙']];
      expect(cFirst, isNotNull);
      expect(cFirst!['status'], 'replied',
          reason: '丙必须在第一轮讲出笑话');
      final laterEvaluations = firstSteps
          .where((step) =>
              step['triggerSeq'] != userSeq &&
              (step['memberId'] == memberIds['甲'] ||
                  step['memberId'] == memberIds['乙']) &&
              step['status'] == 'replied')
          .toList();
      _obs('对象出现后甲乙评价步骤',
          laterEvaluations.map((s) => '${s['memberId']}/${s['status']}').toList());
      expect(laterEvaluations, isNotEmpty,
          reason: '丙的笑话出现后，甲乙应在后续轮评价它');
      final firstAllPublicText =
          firstPublicAssistant.map((row) => '${row['content']}').join('\n');
      expect(firstAllPublicText, isNot(contains('joke_scores')),
          reason: '不得引用不存在的假文件 joke_scores');
      final cPublic = firstPublicAssistant
          .where((row) => row['author'] == memberIds['丙'])
          .toList();
      expect(cPublic, isNotEmpty,
          reason: '丙必须公开讲出笑话（R.12：点名丙不能由别人代讲）');
      final firstPublicText = '${cPublic.first['content']}'.trim();
      expect(firstPublicText, isNotEmpty);
      // R.12 第一人称/禁自我署名：正文不能以「丙：」「丙（作者本人）：」「作为丙」开头，
      // 也不能自报「丙（作者本人）」；应使用第一人称「我」，署名由系统 author 承担。
      final selfLabel = RegExp(r'^\s*(丙\s*[:：（(]|作为丙)');
      _obs('丙正文首行', firstPublicText.split('\n').first);
      expect(firstPublicText, isNot(contains('丙（作者本人）')),
          reason: '正文不得给自己贴「丙（作者本人）」署名');
      expect(selfLabel.hasMatch(firstPublicText), isFalse,
          reason: '正文不得以「丙：」「丙（…）」「作为丙」开头（系统自动署名）');
      expect(firstPublicText, contains('我'),
          reason: '正文应使用第一人称「我」');
      _obs('丙正文是否第一人称开头', firstPublicText.startsWith('我'));
      // 丙的 step 必须与这条公开行对得上（不是只在别处说了句话）。
      final cStep = (firstChain['steps'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((step) => step['memberId'] == memberIds['丙'],
              orElse: () => <String, dynamic>{});
      // ignore: avoid_print
      print('[OBS] 丙讲笑话 author=${cPublic.first['author']} '
          'step.status=${cStep['status']} publicSeq=${cStep['publicSeq']}');
      expect(cStep['status'], 'replied');
      expect(cStep['publicSeq'], cPublic.first['seq'],
          reason: '丙的 replied step 必须指向这条讲笑话的公开行');
      // ignore: avoid_print
      print('[OBS] 丙讲的公开内容：「$firstPublicText」');
      // R.12：每个成员最近一次真实请求的系统提示词必须含**当前群成员名单**与自己的
      // 唯一称呼（名单每轮现读，不是创建时缓存）。
      for (final name in ['甲', '乙', '丙']) {
        final view = (await ws.request('group.view', {
          'groupId': groupId,
          'memberId': memberIds[name],
        }))['result'] as Map;
        final snapshot = view['snapshot'] as Map?;
        // ContextSnapshot.toJson 的键是 `system`（不是 systemPrompt）。
        final prompt = '${snapshot?['system'] ?? ''}';
        _obs('$name 名单/身份片段',
            prompt.contains('本群成员：甲、乙、丙。你是「$name」。'));
        expect(prompt, contains('本群成员：甲、乙、丙。'),
            reason: '$name 的系统提示词必须含当前群成员名单');
        expect(prompt, contains('你是「$name」'),
            reason: '$name 的系统提示词必须含自己的唯一称呼');
      }
      // R.9：默认沉默框架下**允许**成员 pass=true（不再要求每人都发言）；
      // 只要求每个成员至少被规划到一步，且一旦 replied 就必须是实质内容。
      for (final name in ['甲', '乙', '丙']) {
        final steps = firstSteps
            .where((step) => step['memberId'] == memberIds[name])
            .toList();
        expect(steps, isNotEmpty, reason: '$name 必须有反应步骤（自发反应没被触发？）');
        for (final step in steps.where((s) => s['status'] == 'replied')) {
          final text = '${step['finalText']}'.trim();
          expect(text, isNotEmpty, reason: '$name 的 replied 步骤不得为空');
          expect(step['publicSeq'], isNotNull);
          expect(text, isNot(kGroupPassSentinel), reason: 'replied 不应是旧哨兵文本');
          // ignore: avoid_print
          print('[OBS] $name 的公开回复 finalText：「$text」');
          expect(looksLikePureCompliment(text), isFalse,
              reason: '$name 的评价看起来是纯恭维（「$text」）：实质评价要求给出理由，'
                  '不要只说"说得好"。这是测试侧启发式，不是语义检查。');
        }
      }
      _reportSilence('第一段', firstSteps);
      // 链终态（R.6 追加返工）：**收敛判据 = 在推导上界内进入终态**，且
      // `stopReason ∈ {all_passed, round_cap}`（自然沉默停 / 达该组上限停，两者都是
      // 合法收敛），`rounds <= 该组上限`，整体不是 failed。
      expect(kGroupChainStopReasons, contains(firstChain['stopReason']),
          reason: 'stopReason 必须取封闭枚举，实测 ${firstChain['stopReason']}');
      expect(firstChain['status'], 'completed',
          reason: '第一段必须是 completed（不是 failed），实测 ${firstChain['status']}');
      final firstRounds = (firstChain['rounds'] as num).toInt();
      expect(firstRounds, lessThanOrEqualTo(groupMaxRounds),
          reason: '反应轮数不得超过该组上限（rounds=$firstRounds, 上限=$groupMaxRounds）');
      final firstStopReason = firstChain['stopReason'] as String;
      expect(['all_passed', 'round_cap'], contains(firstStopReason),
          reason: '收敛判据：自然沉默停（all_passed）或达该组上限停（round_cap），'
              '实测 $firstStopReason');
      if (firstStopReason == 'round_cap') {
        expect(firstRounds, groupMaxRounds, reason: 'round_cap 必须正好停在轮数上限');
        _obs('第一段以上限停', 'rounds=$firstRounds');
      } else {
        // 收敛：按 triggerSeq 取**最后一轮**：该轮全部 passed/empty 且没有新 publicSeq。
        final triggerSeqs = [
          for (final step in firstSteps) (step['triggerSeq'] as num?)?.toInt() ?? 0,
        ];
        final lastTrigger = triggerSeqs.reduce((a, b) => a > b ? a : b);
        final lastRound = firstSteps
            .where((step) => ((step['triggerSeq'] as num?)?.toInt() ?? 0) == lastTrigger)
            .toList();
        _obs('最后一轮的 triggerSeq', lastTrigger);
        _obs('最后一轮的步骤',
            lastRound.map((s) => '${s['source']}/${s['status']}').toList());
        expect(lastRound, isNotEmpty);
        for (final step in lastRound) {
          expect(['passed', 'empty'], contains(step['status']),
              reason: 'all_passed 的最后一轮必须全是沉默（passed/empty），实测 ${step['status']}');
          expect(step['publicSeq'], isNull, reason: '最后一轮不得产生新的公开行');
        }
      }

      final turnFailed = ws.events
          .where((event) => event['type'] == 'turn.failed')
          .toList();
      _obs('turn.failed 事件', turnFailed);
      expect(turnFailed, isEmpty, reason: '全程不应有 turn.failed');

      // ---- 第二段：@乙 具体说说哪里好笑（不选 speaker，验定向必应） ----
      final secondChain = await sendAndWait('@乙 具体说说哪里好笑。');
      _dumpChain('第二段', secondChain);
      final secondSteps = (secondChain['steps'] as List).cast<Map<String, dynamic>>();
      _reportSilence('第二段', secondSteps);
      final forced = secondSteps
          .where((step) =>
              step['status'] == 'forced_pass' || step['status'] == 'forced_empty')
          .toList();
      expect(forced, isEmpty,
          reason: '@乙 定向必须得到实质回应，不允许 forced_pass / forced_empty');
      final mentionStep = secondSteps.firstWhere(
          (step) => step['source'] == 'mention',
          orElse: () => <String, dynamic>{});
      expect(mentionStep, isNotEmpty,
          reason: '@乙 必须产生 source=mention 的步骤，实测 ${secondSteps.map((s) => s['source'])}');
      expect(mentionStep['memberId'], memberIds['乙']);
      expect(mentionStep['status'], 'replied',
          reason: '被 @ 的成员必须真的回应（status=replied）');
      expect(mentionStep['publicSeq'], isNotNull);
      expect(secondChain['status'], isNot('failed'),
          reason: '第二段链不得硬失败');
      expect(secondChain['status'], isNot('cancelled'));
      // 第二段同样按「有界收敛」判：stopReason 在 {all_passed, round_cap}，轮数不超上限。
      expect(['all_passed', 'round_cap'], contains(secondChain['stopReason']),
          reason: '第二段收敛判据同上，实测 ${secondChain['stopReason']}');
      expect((secondChain['rounds'] as num).toInt(),
          lessThanOrEqualTo(groupMaxRounds),
          reason: '第二段轮数不得超过该组上限');

      // ---- 时间线：公开行打印出来（人读"实质"的现场） ----
      final messages = ((await ws.request('message.query', {
        'sessionId': groupId,
        'pageSize': 500,
      }))['result'] as Map)['messages'] as List;
      final publicRows = [
        for (final row in messages)
          if ((row as Map)['visibility'] == 'public') row as Map<String, dynamic>,
      ];
      _obs('公开时间线行数', publicRows.length);
      for (final row in publicRows) {
        // ignore: avoid_print
        print('[OBS] 时间线 ${_rowLine(row)}');
      }
      // 哨兵不得进公开时间线（整条 trim 后全等）。
      for (final row in publicRows) {
        expect('${row['content']}'.trim(), isNot(kGroupPassSentinel),
            reason: '公开时间线里出现了整条等于哨兵的行（PASS 泄漏）');
      }

      // ---- 截图：真实页面驱动脚本（无头 Edge）+ 断言 PNG 非空 ----
      final shotPath = p.normalize(p.join(Directory.current.path,
          'test', 'live_visual', 'group_reactions_live.png'));
      final script = p.join(Directory.current.path, 'web', 'e2e', 'group_reactions.mjs');
      final run = await Process.run(
        'node',
        [
          script,
          '--coreUrl=${core.url.toString().replaceAll(RegExp(r'/$'), '')}',
          '--shotPath=$shotPath',
          '--prompt=丙再讲一个短笑话，甲和乙各评价一句。',
          '--mentionPrompt=@乙 具体说说哪里好笑。',
        ],
        workingDirectory: p.join(Directory.current.path, 'web'),
      );
      _obs('截图脚本退出码', run.exitCode);
      // ignore: avoid_print
      print('[OBS] 截图脚本 stdout 末尾：'
          '${run.stdout.toString().split('\n').where((l) => l.trim().isNotEmpty).toList().reversed.take(4).toList().reversed}');
      if (run.exitCode != 0) {
        // ignore: avoid_print
        print('[OBS] 截图脚本 stderr：${run.stderr}');
      }
      expect(run.exitCode, 0, reason: '真实页面驱动脚本必须成功（它同时验 UI 选择器）');
      final shot = File(shotPath);
      _obs('截图', {'path': shotPath, 'exists': shot.existsSync(),
        'bytes': shot.existsSync() ? shot.lengthSync() : 0});
      expect(shot.existsSync(), isTrue, reason: '必须生成 live 截图');
      expect(shot.lengthSync(), greaterThan(0), reason: '截图字节数不能为 0');

      // ---- 7.3 隔离核对：真实用户目录 db/config/core.lock 指纹不变 ----
      final differences = baseline.differences();
      _obs('真实用户目录差异', differences);
      if (differences.isNotEmpty) {
        // ignore: avoid_print
        print('[OBS] 临时根目录=${root.path} configPath=$configPath '
            'databaseDir=${p.join(root.path, 'db')} lockPath=$lockPath '
            'attachmentsDir=$attachmentsDir workspace=$workspace');
      }
      expect(differences, isEmpty,
          reason: 'live 用例绝不能写用户真实 ~/.aliasagent 的 db/config/core.lock');
      // logs/ 是已知副作用：只记录，不比断言。
      _obs('logs（已知副作用，只记录）', baseline.logsSummary);
    } catch (error, stack) {
      failureDump = '[OBS] 失败现场：临时根目录=${root.path} '
          'configPath=$configPath lockPath=$lockPath '
          'attachmentsDir=$attachmentsDir workspace=$workspace\n'
          '[OBS] 已记录模型请求数=${recorded.requests.length}\n';
      // ignore: avoid_print
      print(failureDump);
      // ignore: avoid_print
      print('[OBS] 失败原因：$error\n$stack');
      rethrow;
    } finally {
      // R.7：**异步链未结束不得销毁侧车 / 删临时目录**。先等所有组（主组 + 单成员
      // 探针组）的链进入终态（有推导上界用它，否则用 2 分钟保护值 —— 都不是产品上限）；
      // 超时也继续清理，但留下记录。
      final bound = cleanupBound ?? const Duration(minutes: 2);
      final liveWs = ws;
      if (liveWs != null) {
        for (final chainGroup in chainGroupIds) {
          try {
            // 清理路径也用"无进展"判据：真挂起时 2×120s（产品模型请求超时的两倍，
            // 见上面的推导）内没有新步骤才放弃等待并继续清理。
            await waitChain(liveWs, chainGroup, bound,
                stallLimit: const Duration(seconds: 240));
          } catch (waitError) {
            // ignore: avoid_print
            print('[OBS] 清理前等组 "$chainGroup" 的链终态失败（已继续清理）：$waitError');
          }
        }
      }
      try {
        await ws?.close();
      } catch (_) {}
      try {
        await core?.stop();
      } catch (_) {}
      if (failureDump.isEmpty) {
        // 通过路径：清掉临时目录（Windows 文件锁：删不掉就吞掉）。
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  },
      // 外层不给字面墙钟（R.6 明确不写字面 20 分钟）：真正的**推导上界**是
      // `waitChain` 的每段 segmentTimeout —— 链不收敛时它们会抛红。
      timeout: Timeout.none);
}
