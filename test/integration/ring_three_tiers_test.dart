import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_reference.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/ui/context_ring.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

/// 用**自造的三层数据**验证"压缩机制 + 环上三瓣"的正确性（2026-10-18 用户要求）。
///
/// 用户原话：「或者你可以自造原文，一级，二级摘要来测，我只要验证机制的正确性，
/// 比如压缩返回内容和长度」。
///
/// 这条用例不连云、不调真模型：
/// * **原文**：`_conv(n, rawPerMsg)` 造一段长度可控的历史；
/// * **一级摘要**：假 `SummaryProvider` 对每次折叠返回**固定长度** `l1Tokens`，并记录
///   "被折叠了多少条 / 返回多少 token"；
/// * **二级摘要**：一级的 tokenCost 累积超过 `T` 就会触发 roll-up（`l2GroupCount`），
///   于是库里出现一条 `level == 2`。
///
/// 尺寸的算法（每个数都能自己复核）：
///   窗口 W=8000 ⇒ T=W/4=2000、2T=4000
///   历史 600 条 × 50 token = 30000 原文
///   折叠批 ≈ T=2000 ⇒ 约 15 条一级摘要，每条 `l1Tokens=200`
///   roll-up 门槛：一串一级的累积 > T=2000 ⇒ 需要 11 条（200×11=2200）⇒ 一条二级
///   二级覆盖 ≈ 11 批 ≈ 22000 原文 ⇒ 它之后还剩 30000−22000 = 8000 > 2T=4000 ⇒ **进投影**
/// 于是环上三段都非零：二级 200 / 一级 4×200=800 / 原文约 2000。
void _setupAgentRegistry({required int maxContextTokens}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

/// 每条消息的估算 token 数 = [rawPerMsg]（与既有用例同一个算式）。
List<Message> _conv(int n, int rawPerMsg) {
  final len = (rawPerMsg - 4) * 4 - 3;
  return [
    for (var i = 0; i < n; i++)
      Message(
        id: 'p$i',
        seq: i + 1,
        sessionId: 's1',
        role: i.isEven ? 'user' : 'assistant',
        content: 'm${i + 1}:${'A' * (len - 'm${i + 1}:'.length)}',
        createdAt: i,
      ),
  ];
}

/// 固定长度的假摘要：一级与二级都返回 [tokens] 个 token，并记录调用。
class _FixedSummaryProvider implements SummaryProvider {
  _FixedSummaryProvider({this.tokens = 200});

  final int tokens;

  /// 每次一级折叠的输入条数（用于核对"压缩的输入是什么"）。
  final List<int> l1Inputs = [];

  /// 每次二级收拢的输入长度（字符数）与返回的 token 数。
  final List<int> l2InputChars = [];

  int get l1Calls => l1Inputs.length;
  int get l2Calls => l2InputChars.length;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
  }) async {
    l1Inputs.add(folded.length);
    return SummaryResult(text: 'L1(${folded.length})', tokens: tokens);
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    l2InputChars.add(text.length);
    return SummaryResult(text: 'L2', tokens: tokens);
  }
}

void main() {
  group('自造三层：压缩机制与环上三瓣', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('一级与二级都被造出来，且环上三段都非零、弧度按 token 成比例', (tester) async {
      const window = 8000; // T=2000、2T=4000
      _setupAgentRegistry(maxContextTokens: window);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_conv(600, 50)); // ≈30000 原文
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _FixedSummaryProvider(tokens: 200);

      final captureKey = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          home: Scaffold(
            body: ChatScreen(
              config: const AppConfig(version: 1),
              sessionRepo: sessionRepo,
              msgRepo: msgRepo,
              sidecar: sidecar,
              summaryProvider: provider,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '你好');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      // 折叠可能走"内联"也可能走"空闲后台"，所以按拍推进直到二级出现（最多 40 拍）。
      var rings = <ContextRing>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        rings = tester.widgetList<ContextRing>(find.byType(ContextRing)).toList();
        final b = rings.isEmpty ? null : rings.last.breakdown;
        if (b != null && b.level2Tokens > 0) break;
      }

      final b = rings.isEmpty ? null : rings.last.breakdown;
      // ignore: avoid_print
      print('  [OBS] 假 provider：一级折叠 ${provider.l1Calls} 次 '
          '（每次条数=${provider.l1Inputs}）；二级收拢 ${provider.l2Calls} 次 '
          '（每次输入字符=${provider.l2InputChars}），每次返回 ${provider.tokens} token');
      // ignore: avoid_print
      print('  [OBS] 环上三段：level2=${b?.level2Tokens} level1=${b?.level1Tokens} '
          'raw=${b?.rawTokens} 窗口=${b?.windowTokens} '
          '弧度=${b?.ringSegments.map((s) => s.sweepRadians.toStringAsFixed(4)).toList()}');

      expect(provider.l1Calls, greaterThan(0), reason: '一级摘要必须真的被造出来');
      expect(provider.l2Calls, greaterThan(0), reason: '累积超过 T 必须触发二级收拢');
      expect(b, isNotNull, reason: '发过一次请求 ⇒ 必须有占用拆分');
      // 2026-10-18 定稿口径：环量"这一次实际发出去那份请求"的构成。这条用例把窗口设成
      // 历史的一半（8000 对 30000），二级摘要因此真的进了投影 ⇒ 三瓣都非零。
      expect(b!.level2Tokens, greaterThan(0),
          reason: '二级覆盖段两端都超过 2T ⇒ 它进投影，环上必须有蓝瓣');
      expect(b.level1Tokens, greaterThan(0), reason: '一级那瓣也要有量');
      expect(b.rawTokens, greaterThan(0), reason: '原文那瓣也要有量');

      // 弧度按 token 成比例；但**整圈不许被画过** —— 三段之和可以大于窗口（历史总量
      // 本来就可能比窗口大），那时按顺序累加到整圈为止、超出的不画。
      final segs = b.ringSegments;
      var remaining = 2 * math.pi;
      for (final s in segs) {
        final want = math.min(s.tokens / b.windowTokens * 2 * math.pi, remaining);
        expect(s.sweepRadians, closeTo(want, 1e-9),
            reason: '每段扫过的角度 = 该段 token ÷ 窗口 × 360°，且不许超过剩下的圈');
        remaining -= s.sweepRadians;
      }

      // 截一张真图 —— 走的是上面这条真实压缩链路（只把模型换成假 provider）。
      // `toImage()` 必须放在 `runAsync` 里，否则 `flutter test` 会挂死（踩过两次）。
      final boundary =
          captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ImageByteFormat.png);
        File('test/live_visual/ring_three_tiers.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });
      // ignore: avoid_print
      print('  [OBS] 截图已写到 test/live_visual/ring_three_tiers.png');
    });
  });
}
