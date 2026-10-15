import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/summary_node.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_reference.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

/// 本变更（never-drop-content-when-compacting）的端到端判据。
///
/// 规则（用户 2026-10-05）：原文⇒一级与一级⇒二级**同一条** —— 压缩前、压缩后比 token，
/// **取小的那一侧作为下一级的内容**；没有特殊情况。于是：
///   · "压不短"不再是一个失败态，不再有"折半重试"、也没有"压不短就把内容丢掉"；
///   · 压缩前赢的时候，那一级的内容就是压缩前那一段，发出去时**仍走原文渲染路径**
///     （工具块、思考块一个不少）；
///   · 超容量时**只**允许把最旧的二级摘要从这次请求里拿掉（只是这次不发，库里不删），
///     一级摘要与原文一条都不许拿。
///
/// 每条断言之前都先打印现场（投影里的 seq、库里 summary_nodes 的行数、日志那几行），
/// 失败时能直接看出这一趟实际发生了什么。

void _setupAgentRegistry({int maxContextTokens = 200, int waitPercent = 1}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
    compactionWaitThresholdPercent: waitPercent,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

Widget _buildApp({
  required FakeSessionRepository sessionRepo,
  required FakeMessageRepository msgRepo,
  required FakeSidecar sidecar,
  required SummaryProvider summaryProvider,
  SummaryNodeRepository? summaryNodeRepo,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: summaryNodeRepo,
      ),
    ),
  );
}

/// 每条消息的估算 token 数都等于 [rawPerMsg]，正文里带 `m<seq>:` 标签 —— 便于直接从
/// 真实投影里读出哪些消息是按原文发出去的。
List<Message> _convLabeled(int n, int rawPerMsg, {int startSeq = 1}) {
  final len = (rawPerMsg - 4) * 4 - 3;
  final out = <Message>[];
  for (var i = 0; i < n; i++) {
    final seq = startSeq + i;
    final prefix = 'm$seq:';
    out.add(Message(
      id: 'p$i',
      seq: seq,
      sessionId: 's1',
      role: i.isEven ? 'user' : 'assistant',
      content: '$prefix${'A' * (len - prefix.length)}',
      createdAt: i,
    ));
  }
  return out;
}

/// 在 [_convLabeled] 的基础上给两处塞进工具块与思考块：
///   · 第 3 条（下标 2）是一条**内容为空、只带 tool_calls**的 assistant —— 它的表示就是
///     那个 tool_use 块（`_buildApiMessages` 会把它连同 tool_result 一起重放）；
///   · 第 4 条（下标 3）带 thinking_json。
/// 用来验"压缩前赢的时候仍走原文渲染路径，工具块与思考块一个不少"。
List<Message> _convWithToolRound(int n, int rawPerMsg) {
  final base = _convLabeled(n, rawPerMsg);
  final out = <Message>[];
  for (var i = 0; i < base.length; i++) {
    final m = base[i];
    if (i == 2) {
      out.add(Message(
        id: m.id,
        seq: m.seq,
        sessionId: m.sessionId,
        role: 'assistant',
        content: '',
        toolCallsJson: jsonEncode([
          {
            'id': 'call_cfg',
            'name': 'read_file',
            'input': {'path': 'config.json'},
            'result': '// timeout=120',
          }
        ]),
        createdAt: m.createdAt,
      ));
    } else if (i == 3) {
      out.add(Message(
        id: m.id,
        seq: m.seq,
        sessionId: m.sessionId,
        role: 'assistant',
        content: m.content,
        thinkingJson: jsonEncode([
          {'type': 'thinking', 'thinking': '先看看配置', 'signature': 'sig'}
        ]),
        createdAt: m.createdAt,
      ));
    } else {
      out.add(m);
    }
  }
  return out;
}

/// 每一次 summarize 都报同一个（很大的）实测 token 数 —— 用它把"压缩后"那一侧钉在
/// 远大于"压缩前"的位置，逼出"压缩前赢"那一支。
///
/// [summarizeCalls] 还能顺带证明"折半重试已经不在了"：旧实现下这个数会明显大于批数。
class _AlwaysBiggerSummaryProvider implements SummaryProvider {
  final int bigTokens;
  final int l2BigTokens;

  /// true ⇒ 二级的正文里保留它收到的输入（那几条一级的文本），用例可以据此从投影里
  /// 读出"这一条二级盖住了哪些区间"。
  final bool echoL2;

  _AlwaysBiggerSummaryProvider(
      {required this.bigTokens, int? l2BigTokens, this.echoL2 = false})
      : l2BigTokens = l2BigTokens ?? bigTokens;

  int summarizeCalls = 0;
  int summarizeTextCalls = 0;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
  }) async {
    summarizeCalls++;
    final lo = folded.isEmpty ? 0 : (folded.first.seq ?? 0);
    final hi = folded.isEmpty ? 0 : (folded.last.seq ?? 0);
    return SummaryResult(text: 'L1 summary seq $lo..$hi', tokens: bigTokens);
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    summarizeTextCalls++;
    return SummaryResult(
        text: echoL2 ? 'L2[$text]' : 'L2 rolled up', tokens: l2BigTokens);
  }
}

/// 内存版 `summary_nodes` 仓库（`testWidgets` 的假时钟下真 sqflite 永远不返回）。
class _FakeSummaryNodeRepository implements SummaryNodeRepository {
  final List<SummaryNode> nodes = [];
  int _nextId = 1;
  final Map<String, int> _treeVersion = {};
  final Map<String, int> _dirtySince = {};

  int get level1Count => nodes.where((n) => n.level == 1).length;
  int get level2Count => nodes.where((n) => n.level == 2).length;

  /// `clearDirty` 被调用了几次 —— R8-c 那条"这一段没重新生成摘要 ⇒ 不消费脏水位"
  /// 的判据靠它：信号生效时它必须是 0。
  int clearDirtyCalls = 0;

  @override
  Future<SummaryNode> insert(SummaryNode node) async {
    final stored = _copy(node, id: _nextId++);
    nodes.add(stored);
    return stored;
  }

  @override
  Future<SummaryNode> materialize({
    required String sessionId,
    required int level,
    required int startSeq,
    required int endSeq,
    required String nodeType,
    int? parentId,
    String? summaryJson,
    int? tokenCost,
    int? summaryPromptVersion,
    String? model,
    required int coveredMinSeq,
    required int coveredMaxSeq,
  }) async {
    nodes.removeWhere((n) =>
        n.sessionId == sessionId &&
        n.level == level &&
        n.coveredMinSeq == coveredMinSeq &&
        n.coveredMaxSeq == coveredMaxSeq);
    final stored = SummaryNode(
      id: _nextId++,
      sessionId: sessionId,
      level: level,
      startSeq: startSeq,
      endSeq: endSeq,
      nodeType: nodeType,
      parentId: parentId,
      summaryJson: summaryJson,
      tokenCost: tokenCost,
      summaryPromptVersion: summaryPromptVersion,
      model: model,
      coveredMinSeq: coveredMinSeq,
      coveredMaxSeq: coveredMaxSeq,
    );
    nodes.add(stored);
    _treeVersion[sessionId] = (_treeVersion[sessionId] ?? 0) + 1;
    return stored;
  }

  @override
  Future<List<SummaryNode>> queryBySession(String sessionId) async =>
      nodes.where((n) => n.sessionId == sessionId).toList();

  @override
  Future<SummaryNode?> findCovering(
      String sessionId, int startSeq, int endSeq, {int? level}) async {
    final hits = nodes
        .where((n) =>
            n.sessionId == sessionId &&
            n.coveredMinSeq == startSeq &&
            n.coveredMaxSeq == endSeq &&
            (level == null || n.level == level))
        .toList()
      ..sort((a, b) => b.level - a.level);
    return hits.isEmpty ? null : hits.first;
  }

  @override
  Future<int> treeVersion(String sessionId) async => _treeVersion[sessionId] ?? 0;

  @override
  Future<void> bumpTreeVersion(String sessionId) async {
    _treeVersion[sessionId] = (_treeVersion[sessionId] ?? 0) + 1;
  }

  @override
  Future<int> dirtySinceSeq(String sessionId) async => _dirtySince[sessionId] ?? 0;

  @override
  Future<void> markDirty(String sessionId, int seq) async {
    final prev = _dirtySince[sessionId] ?? 0;
    _dirtySince[sessionId] = (prev == 0 || prev > seq) ? seq : prev;
  }

  @override
  Future<void> clearDirty(String sessionId) async {
    clearDirtyCalls++;
    _dirtySince[sessionId] = 0;
  }

  static SummaryNode _copy(SummaryNode n, {required int id}) => SummaryNode(
        id: id,
        sessionId: n.sessionId,
        level: n.level,
        startSeq: n.startSeq,
        endSeq: n.endSeq,
        nodeType: n.nodeType,
        parentId: n.parentId,
        summaryJson: n.summaryJson,
        tokenCost: n.tokenCost,
        summaryPromptVersion: n.summaryPromptVersion,
        model: n.model,
        coveredMinSeq: n.coveredMinSeq,
        coveredMaxSeq: n.coveredMaxSeq,
      );
}

void main() {
  group('压缩不丢内容（never-drop-content-when-compacting）', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('① 小批压不短 ⇒ 按原文发出去，不丢、也不发那条更长的摘要', (tester) async {
      // 几何：maxContextTokens=1200 ⇒ 阈值 T = 300 raw token。24 条、每条约 29 raw，
      // 合计约 700 raw —— **投影装得下**（不触发"超容量丢最旧的二级"那条允许的丢弃），
      // 所以这一条只测"压不短"那一支。按 T 切批：每批 11 条左右，两批 + 尾巴。
      //
      // 假 provider 每次都报 5000 token（远大于任何一批的 raw，也远大于两批之和），
      // 于是两级都是"压缩后更大" ⇒ 都取压缩前那一侧（原文本身），一级标
      // verbatimAtLevel，合成出来的二级把它往上传、也标 verbatimAtLevel ⇒ 渲染走原文。
      //
      // 旧实现下这条用例是红的：折半递归到原子批、然后把每一条都丢掉，
      // 投影里那一整段内容一条表示都没有（实测 0/24）。
      _setupAgentRegistry(maxContextTokens: 1200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convWithToolRound(24, 29));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _AlwaysBiggerSummaryProvider(bigTokens: 5000);
      final nodeRepo = _FakeSummaryNodeRepository();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: nodeRepo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      var rawHits = 0;
      for (var seq = 1; seq <= 24; seq++) {
        if (projected.contains('m$seq:')) rawHits++;
      }
      // ignore: avoid_print
      print('  [OBS] ① 压不短：summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          '投影里按原文出现的消息数=$rawHits/24 '
          '库里 level1=${nodeRepo.level1Count} level2=${nodeRepo.level2Count} '
          '含更长的摘要=${projected.contains('L1 summary')} '
          '含 tool_use=${projected.contains('tool_use')} '
          '含 thinking=${projected.contains('thinking')}');

      // ①-a 那一段原文必须发出去（工具块与思考块完整）
      expect(projected.contains('tool_use'), isTrue,
          reason: '压缩前赢的时候走原文渲染路径，tool_use 块必须还在');
      expect(projected.contains('thinking'), isTrue,
          reason: '压缩前赢的时候走原文渲染路径，thinking 块必须还在');
      // ①-b 不许把那条更长的摘要发出去
      expect(projected.contains('L1 summary'), isFalse,
          reason: '压缩后更大 ⇒ 取压缩前那一侧，那条更长的摘要一个字都不许进投影');
      // ①-c 库里不许为这一段写 level-1 行
      expect(nodeRepo.level1Count, 0,
          reason: '这一级没有真的压出摘要，就不该在 summary_nodes 里留 level-1 行');
    });

    testWidgets('④ 二级压不短 ⇒ 取那几条一级（内容仍是原文），不是一段拼接文本', (tester) async {
      // 几何：maxContextTokens=2000 ⇒ T = 500 raw；60 条、每条约 29 raw（合计约 1740，
      // **装得下**，不触发超容量丢弃）。按 T 切批：每批 18 条（522 raw），3 批 + 尾巴 6 条。
      // 假 provider 两级都报 5000（远大于任何一批的 raw，也远大于几条一级之和）：
      // 一级压不短 ⇒ 一级的内容是原文（verbatimAtLevel）；累积超过 T 触发合成，
      // 二级也压不短 ⇒ 二级取"那几条一级"这一侧，并且**必须把 verbatimAtLevel 往上传**，
      // 否则那 18 条原文会被当成一段拼接文本发出去（工具块、思考块全没了）。
      _setupAgentRegistry(maxContextTokens: 2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convWithToolRound(60, 29));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider =
          _AlwaysBiggerSummaryProvider(bigTokens: 5000, l2BigTokens: 5000);
      final nodeRepo = _FakeSummaryNodeRepository();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: nodeRepo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      var rawHits = 0;
      for (var seq = 1; seq <= 60; seq++) {
        if (projected.contains('m$seq:')) rawHits++;
      }
      // ignore: avoid_print
      print('  [OBS] ④ 二级压不短：summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          '投影里按原文出现的消息数=$rawHits/60 '
          '库里 level1=${nodeRepo.level1Count} level2=${nodeRepo.level2Count} '
          '含 L2 正文=${projected.contains('L2 rolled up')} '
          '含 L1 正文=${projected.contains('L1 summary')} '
          '含 tool_use=${projected.contains('tool_use')} '
          '含 thinking=${projected.contains('thinking')}');

      expect(projected.contains('L2 rolled up'), isFalse,
          reason: '二级不比那几条一级短 ⇒ 取压缩前那一侧，模型给的那条二级一个字都不许进投影');
      expect(projected.contains('L1 summary'), isFalse,
          reason: '二级的内容是那几条一级本身，但它渲染走原文 —— 不许把一级的文本当摘要发');
      expect(projected.contains('tool_use'), isTrue,
          reason: 'verbatimAtLevel 要往上传：二级也要按原文发，工具块必须还在');
      expect(projected.contains('thinking'), isTrue,
          reason: '同上，思考块必须还在');
      expect(nodeRepo.level2Count, 0,
          reason: '内容是原文的那一级不落盘（写进去下一趟会被当成普通二级摘要文本化渲染）');
    });

    testWidgets('2.2 这一段没重新生成摘要 ⇒ 不消费脏水位（clearDirty 不许被调用）', (tester) async {
      // R8-c：一段因为"压不短"而走了原文那一侧的区间，这一趟**没有重新生成摘要**，
      // 所以调用方不许消费脏水位 —— 否则下一趟会复用一条陈旧的缓存摘要。
      // 几何与用例① 相同（每一批都压不短），再预置一个脏水位 seq=1。
      _setupAgentRegistry(maxContextTokens: 1200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convWithToolRound(24, 29));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _AlwaysBiggerSummaryProvider(bigTokens: 5000);
      final nodeRepo = _FakeSummaryNodeRepository();
      // 预置脏水位：dirtySinceSeq = 1 ⇒ 任何 maxSeq >= 1 的"没重生成摘要"的区间都会置
      // persistFailed，从而跳过 clearDirty。
      await nodeRepo.markDirty('s1', 1);
      final dirtyBefore = await nodeRepo.dirtySinceSeq('s1');

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: nodeRepo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final dirtyAfter = await nodeRepo.dirtySinceSeq('s1');
      // ignore: avoid_print
      print('  [OBS] 2.2 脏水位：预置 dirtySince=$dirtyBefore '
          '结束后 dirtySince=$dirtyAfter '
          'clearDirtyCalls=${nodeRepo.clearDirtyCalls} '
          'summarizeCalls=${summaryProvider.summarizeCalls} '
          '库里 level1=${nodeRepo.level1Count}');

      expect(nodeRepo.clearDirtyCalls, 0,
          reason: '这一趟的每一批都走了"没重新生成摘要"那一支 ⇒ 脏水位不许被消费'
              '（把 onNotResummarized 那处断掉，这个数就会变成 1 —— 那条变异在 6.4 里跑）');
      expect(dirtyAfter, dirtyBefore,
          reason: '脏水位必须原样留着，下一趟才知道这一段是陈旧的');
    });

    testWidgets('②⑥ 超容量 ⇒ 只丢最旧的二级摘要；库里一行不少', (tester) async {
      // 几何：maxContextTokens=200 ⇒ T = 50；24 条、每条约 29 raw（合计约 700）。
      // 假 provider 一级二级都报 40：一级 40 < 58（每批 2 条）⇒ 摘要那一侧赢，是**真**一级；
      // 二级 40 < 80（两条一级）⇒ 也是真的二级。12 条一级 → 6 条二级，6 × 40 = 240 > 200
      // ⇒ 超容量，于是从**最旧**那条二级开始拿掉，拿到装得下。
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(24, 29));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider =
          _AlwaysBiggerSummaryProvider(bigTokens: 40, l2BigTokens: 40, echoL2: true);
      final nodeRepo = _FakeSummaryNodeRepository();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: nodeRepo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final l2Rows = nodeRepo.nodes.where((n) => n.level == 2).toList();
      // ignore: avoid_print
      print('  [OBS] ②⑥ 超容量：summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          '库里 level1=${nodeRepo.level1Count} level2=${nodeRepo.level2Count} '
          '投影含最旧区间(seq 1..)=${projected.contains('seq 1..')} '
          '投影含 seq 5..=${projected.contains('seq 5..')} '
          '库里还有覆盖 seq 1 起的二级行='
          '${l2Rows.any((n) => n.coveredMinSeq == 1)}');
      // ignore: avoid_print
      print('  [OBS] ②⑥ 投影长度=${projected.length} 开头 260 字：'
          '${projected.substring(0, projected.length < 260 ? projected.length : 260)}');

      // ② 被拿掉的是**最旧**的那几条二级：投影里剩下的区间标签，最小起点必须 > 1，
      // 而且标签总数必须少于这一趟真的压出来的二级条数（说明确实拿掉了几条）。
      final starts = RegExp(r'seq (\d+)\.\.')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toList()
        ..sort();
      // ignore: avoid_print
      print('  [OBS] ②⑥ 投影里剩下的区间起点=$starts（共 ${starts.length} 条二级）');
      expect(starts, isNotEmpty, reason: '全部被拿光说明几何或规则出了问题');
      expect(projected.contains('seq 1..'), isFalse,
          reason: '最旧的那条二级被拿掉 ⇒ 从 seq 1 起的那一段不该出现在投影里');
      expect(starts.first, greaterThan(1),
          reason: '剩下的区间必须从更晚的地方开始 —— 只许从最旧开始拿');
      expect(starts.length, lessThan(l2Rows.length),
          reason: '这一趟确实拿掉了几条（拿掉的条数 = 压出来的条数 − 投影里还剩的条数）');
      // ⑥ 库里一行不少：内容没发出去的那条二级行仍然在
      expect(l2Rows.any((n) => n.coveredMinSeq == 1), isTrue,
          reason: '拿掉只是这次不发：那条二级摘要在库里必须原样还在');
      expect(nodeRepo.nodes.length, greaterThan(l2Rows.length - 1),
          reason: '库里总行数不该因为这一趟的丢弃而减少');
    });

    testWidgets('③ 反向：压缩后更短 ⇒ 照旧用摘要，且不出现相邻两条 role:user', (tester) async {
      _setupAgentRegistry(maxContextTokens: 1200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(24, 29));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _AlwaysBiggerSummaryProvider(bigTokens: 1, l2BigTokens: 1);
      final nodeRepo = _FakeSummaryNodeRepository();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: nodeRepo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final decoded = (jsonDecode(projected) as List).cast<Map<String, dynamic>>();
      var adjacentUser = 0;
      for (var i = 1; i < decoded.length; i++) {
        if (decoded[i - 1]['role'] == 'user' && decoded[i]['role'] == 'user') {
          adjacentUser++;
        }
      }
      // ignore: avoid_print
      print('  [OBS] ③ 反向：消息条数=${decoded.length} '
          '含 L1 正文=${projected.contains('L1 summary')} '
          '相邻两条 role:user=$adjacentUser');

      expect(projected.contains('L1 summary'), isTrue,
          reason: '压缩后确实更短 ⇒ 照旧采用摘要那一侧（防止把规则改成"永远用原文"也能过）');
      expect(adjacentUser, 0,
          reason: '摘要块与正文块的合并规则要保住：不许出现相邻两条 role:user');
    });
  });
}
