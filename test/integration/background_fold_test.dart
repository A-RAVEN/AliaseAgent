import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

void _setupAgentRegistry(int maxContextTokens) {
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

/// Summary provider whose summarize can be made to hang on a Completer, so a test
/// can hold a background fold "in flight" and then release it (simulating a cancel
/// via completeError). When [gate] is null the call completes immediately — used
/// for inline folds that must not hang.
class _GatedSummaryProvider implements SummaryProvider {
  int summarizeCalls = 0;
  Completer<SummaryResult>? gate;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    summarizeCalls++;
    final g = gate;
    if (g == null) {
      return SummaryResult(
          text: 'GATED summary (${folded.length} msgs)', tokens: folded.length);
    }
    return g.future; // hang until the test releases it
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    final g = gate;
    if (g == null) {
      return SummaryResult(text: 'GATED L2', tokens: text.length);
    }
    return g.future;
  }
}

void main() {
  group('Background folding (2.6, idle-gated + preemptible)', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    Future<void> growConversation(FakeMessageRepository repo, int n) async {
      final len = repo.messages.length;
      for (var i = 0; i < n; i++) {
        await repo.insert(
          sessionId: 's1',
          role: (len + i).isEven ? 'user' : 'assistant',
          content: 'A' * 100,
        );
      }
    }

    Widget buildApp({
      required FakeSidecar sidecar,
      required SummaryProvider summaryProvider,
      required FakeMessageRepository msgRepo,
      List<Session>? sessions,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            config: const AppConfig(version: 1),
            sessionRepo: FakeSessionRepository(sessions ?? testSessions(1)),
            msgRepo: msgRepo,
            sidecar: sidecar,
            summaryProvider: summaryProvider,
            backgroundFoldEnabled: true,
          ),
        ),
      );
    }

    testWidgets('background fold runs when idle and folds the far span',
        (tester) async {
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = FakeSummaryProvider();
      // Seed a couple of messages so turn 1 is UNDER the model context allowance
      // (no inline fold), then grow the conversation out-of-band so the IDLE fold
      // sees a history that has passed the threshold.
      await growConversation(mgr, 2);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar, summaryProvider: summaryProvider, msgRepo: mgr));
      await tester.pump();
      await tester.pump();

      // Turn 1: under budget -> NO inline fold, so the provider is never called.
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] after turn-1 (under-budget) inline send: '
          'lastFolded=${summaryProvider.lastFolded} '
          '[expect null — no inline fold]');
      expect(summaryProvider.lastFolded, isNull,
          reason: 'an under-budget turn must NOT fold inline, so any provider '
              'call below is evidence of the BACKGROUND fold');

      // Grow the history out-of-band (no user turn) so the idle fold over-budgets.
      await growConversation(mgr, 80);

      // Idle: fire the 2s debounce timer; the background fold runs and folds.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] after idle background fold: lastFolded='
          '${summaryProvider.lastFolded != null} '
          'foldedMsgs=${summaryProvider.lastFolded?.length}');
      expect(summaryProvider.lastFolded, isNotNull,
          reason: 'the idle background fold must drive the summary provider '
              '(reuse the same fold path as the inline send)');
    });

    testWidgets('a user send during a background fold fires the preempt path and the user turn completes',
        (tester) async {
      // HONEST SCOPING: this hermetic test uses a FakeSidecar that is SYNCHRONOUS
      // and does NOT serialize requests (unlike the real SidecarBridge._chain gate),
      // so it CANNOT assert the real "the fold's in-flight request delayed/serialized
      // behind the user" effect, nor directly observe the fold object aborting. What
      // it DOES genuinely verify is narrower: (a) the background fold was IN FLIGHT
      // (it reached a summarize call) when the user sent, (b) `_sendMessage` invoked
      // the preempt path (the ONLY place that bumps cancelCount while a fold is in
      // flight — asserted with a reset so it FAILS if the preempt block were removed),
      // and (c) the user's turn still completed. This is an honest subset, not a claim
      // of "not delayed" (which a serializing sidecar would be needed to prove).
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _GatedSummaryProvider();
      await growConversation(mgr, 2);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar, summaryProvider: summaryProvider, msgRepo: mgr));
      await tester.pump();
      await tester.pump();

      // Turn 1 (under budget -> no inline fold, no provider call).
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Grow the history out-of-band, gate the provider, then fire the idle
      // debounce so the BACKGROUND fold starts and hangs on the gate (in flight).
      await growConversation(mgr, 80);
      summaryProvider.gate = Completer<SummaryResult>();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      // The background fold must have genuinely started: it reached a summarize
      // call BEFORE the user sends. At this point turn 1 (under budget) and turn 2
      // (not sent yet) have both called summarize zero times, so a count >= 1 can
      // only be the BACKGROUND fold's summary call — proving it is really in flight.
      // (The full-history fold reads _msgRepo.queryBySession, which includes the 80
      // grown messages -> over budget; the widget's _chatItems is unaffected.)
      // ignore: avoid_print
      print('  [OBS] before user send: summarizeCalls=${summaryProvider.summarizeCalls} '
          '[expect >=1 — background fold reached its summary call]');
      expect(summaryProvider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: 'the background fold must have reached a summarize call before the '
              'user sends (only the fold could have bumped the count so far)');

      // Reset the cancel counter so the ONLY cancelRequest that can occur between
      // here and the assertion is (preempt path) + (turn-2 _endStreaming). Asserting
      // >= 2 therefore FAILS if _sendMessage's preempt block were removed (then only
      // _endStreaming would fire once). This makes the preempt guard non-vacuous.
      // The fold is in flight; user sends -> the preempt path bumps _foldGen +
      // calls cancelRequest (modelling production: cancelRequest makes the fold's
      // ModelSummaryProvider.summarize throw). Release the gate with an error to let
      // the preempted fold unwind cleanly.
      // NOTE: FakeSidecar consumes its event queue up to the FIRST done on each
      // sendMessage; turn 1 already consumed the single queued 'Reply'+done, so the
      // queue is EMPTY. We re-queue a DISTINCT chunk for turn 2 so that a rendered
      // 'Turn2 done' text is unambiguous proof turn-2 actually replied+completed
      // (find.text('Reply') would wrongly match turn-1's already-rendered reply).
      sidecar.cancelCount = 0;
      sidecar..queueChunk('Turn2 done')..queueDone();
      await tester.enterText(find.byType(TextField), 'second');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      summaryProvider.gate!.completeError(StateError('preempted/fold cancelled'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] preempt: cancelCount=${sidecar.cancelCount} '
          'turn2ReplyPresent=${find.text('Turn2 done').evaluate().isNotEmpty} '
          '[expect cancelCount>=2 (preempt + turn-endStreaming); turn2 reply present]');
      // The background fold was genuinely in-flight at send-time (proven by the >=1
      // summarizeCalls assertion right before the send). The preempt path fired: its
      // cancelRequest (1) + the turn-completion _endStreaming cancel (2). _endStreaming
      // is only reached on a NORMALLY-completed turn, so >=2 also evidences turn 2
      // reached completion. Removing the preempt block drops this below 2 -> non-vacuous.
      expect(sidecar.cancelCount, greaterThanOrEqualTo(2),
          reason: 'a send while a fold is in flight must fire _sendMessage preempt '
              '(cancel) AND the turn-completion _endStreaming cancel; removing the '
              'preempt block would drop this below 2 -> the assertion is non-vacuous');
      // turn 2 rendered its OWN reply -> it completed (not stuck behind the fold).
      expect(find.text('Turn2 done'), findsOneWidget,
          reason: 'a user message sent during a background fold must still complete '
              '(turn 2 renders a distinct reply)');
    });

    testWidgets('压缩期间对话视图出现提示，结束后消失（后台这条路径）', (tester) async {
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(const Key('compaction-status-banner'));
      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _GatedSummaryProvider();
      await growConversation(mgr, 2);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar, summaryProvider: summaryProvider, msgRepo: mgr));
      await tester.pump();
      await tester.pump();

      // ① 什么都没发生：不许有提示。
      // ignore: avoid_print
      print('  [OBS] 启动后 banner=${banner.evaluate().length} [expect 0]');
      expect(banner, findsNothing,
          reason: '没有任何压缩在进行时，界面不许出现压缩提示');

      // ② 低于预算的一轮：不触发压缩，整轮都不许出现提示。
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 未触发压缩的发送之后 banner=${banner.evaluate().length} '
          'summarizeCalls=${summaryProvider.summarizeCalls} [expect 0 / 0]');
      expect(summaryProvider.summarizeCalls, 0,
          reason: '这一轮低于预算，摘要提供者不该被调用');
      expect(banner, findsNothing,
          reason: '没触发压缩的普通发送不许出现压缩提示');

      // ③ 把历史撑过阈值、卡住摘要，等 2 秒防抖让后台压缩起来：提示必须出现。
      await growConversation(mgr, 80);
      summaryProvider.gate = Completer<SummaryResult>();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 后台压缩卡住期间 banner=${banner.evaluate().length} '
          'summarizeCalls=${summaryProvider.summarizeCalls} '
          '文案="${_bannerText(tester)}" [expect banner=1]');
      expect(summaryProvider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: '后台压缩必须真的跑到生成摘要这一步，这条断言才不是空跑');
      expect(banner, findsOneWidget,
          reason: '压缩正在跑，对话视图必须出现提示');
      expect(find.textContaining('正在压缩'), findsWidgets,
          reason: '提示里要写明当前在压缩');
      expect(find.textContaining('让路'), findsWidgets,
          reason: '后台压缩的提示要说明发消息会让它让路');

      // 状态本身（不只是界面）：压缩期间必须非空闲，且标着"这是后台那趟"。
      final during =
          tester.state<ChatScreenState>(find.byType(ChatScreen)).compactionStatus;
      // ignore: avoid_print
      print('  [OBS] 压缩期间状态：isIdle=${during.isIdle} label="${during.label}" '
          'note="${during.note}" [expect false]');
      expect(during.isIdle, isFalse, reason: '压缩进行中，状态必须非空闲');
      expect(during.background, isTrue,
          reason: '这是后台那趟压缩，状态要标出来（界面据此显示"让路"那句）');

      // ④ 放行之后：提示必须消失。
      summaryProvider.gate!.complete(SummaryResult(text: 'gated', tokens: 1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 放行之后 banner=${banner.evaluate().length} [expect 0]');
      expect(banner, findsNothing,
          reason: '压缩结束后提示必须消失');

      // 状态本身（不只是界面）：压缩期间必须非空闲、结束后必须回到空闲。
      final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
      // ignore: avoid_print
      print('  [OBS] 结束后状态空闲=${state.compactionStatus.isIdle} '
          '文案=${state.compactionStatus.label} [expect true / null]');
      expect(state.compactionStatus.isIdle, isTrue,
          reason: '压缩结束后状态必须回到空闲，界面与测试读的是同一个值');
      expect(state.compactionStatus.label, isNull);
    });

    testWidgets('压缩提示：后台压缩无事可做时不亮（历史没到阈值）', (tester) async {
      // 容量 2000 ⇒ 阈值 500。两条 100 raw 的预置消息 + 一轮短对话 ≈ 215 raw，
      // 远低于阈值 ⇒ 每轮结束后那次后台压缩都会跑一遍"发现没事做就返回"。
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(const Key('compaction-status-banner'));
      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _GatedSummaryProvider();
      await growConversation(mgr, 2);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar, summaryProvider: summaryProvider, msgRepo: mgr));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // 等过 2 秒防抖：后台压缩会启动、发现没到阈值、直接返回。
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
      // ignore: avoid_print
      print('  [OBS] 后台压缩无事可做：summarizeCalls=${summaryProvider.summarizeCalls} '
          'banner=${banner.evaluate().length} '
          '状态空闲=${state.compactionStatus.isIdle} [expect 0 / 0 / true]');
      expect(summaryProvider.summarizeCalls, 0,
          reason: '前提：历史没到阈值，这一趟确实无事可做（否则这条用例是空跑）');
      expect(banner, findsNothing,
          reason: '无事可做的那一趟不许亮提示 —— 否则每次空闲都会闪一下');
      expect(state.compactionStatus.isIdle, isTrue,
          reason: '压缩结束后状态必须是空闲');
    });

    testWidgets('压缩提示：压缩期间界面被销毁，收尾不许抛异常', (tester) async {
      // 这一步抛出来的异常会被后台折叠自己的 catch 吞掉（只打一行日志），所以不能只看
      // "测试有没有红" —— 直接接管 debugPrint，查日志里有没有 `called after dispose`。
      // 还原必须发生在**测试体里面**：框架在测试体结束后会校验"没有调试变量被改过"，
      // 放在 addTearDown 里太晚（实测会报 "The value of a foundation debug variable
      // was changed by the test"）。
      final logs = <String>[];
      final originalPrint = debugPrint;
      final banner = find.byKey(const Key('compaction-status-banner'));
      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _GatedSummaryProvider();

      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        _setupAgentRegistry(2000);
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;

        await growConversation(mgr, 2);
        await tester.pumpWidget(buildApp(
            sidecar: sidecar, summaryProvider: summaryProvider, msgRepo: mgr));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'first');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        // 撑过阈值 + 卡住摘要，让后台压缩停在"压缩中"。
        await growConversation(mgr, 80);
        summaryProvider.gate = Completer<SummaryResult>();
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        // ignore: avoid_print
        print('  [OBS] 销毁之前：banner=${banner.evaluate().length} '
            'summarizeCalls=${summaryProvider.summarizeCalls} [expect 1 / >=1]');
        expect(banner, findsOneWidget);
        expect(summaryProvider.summarizeCalls, greaterThanOrEqualTo(1));

        // 销毁界面（相当于切换会话 / 关窗口），然后放行这一趟压缩。
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        summaryProvider.gate!.complete(SummaryResult(text: 'gated', tokens: 1));
        await tester.pump();
        await tester.pump();
      } finally {
        debugPrint = originalPrint;
      }

      final disposeErrors =
          logs.where((l) => l.contains('called after dispose')).toList();
      // ignore: avoid_print
      print('  [OBS] 界面已销毁、压缩已放行：日志 ${logs.length} 行，'
          '其中含"called after dispose"的 ${disposeErrors.length} 行 '
          '(第一条="${logs.isEmpty ? '' : logs.first}") [expect 0]');
      expect(disposeErrors, isEmpty,
          reason: '压缩在界面已经销毁之后收尾，不许对已销毁的界面调 setState —— '
              '这一步抛出来的异常会被后台折叠的 catch 吞掉，所以必须查日志，'
              '光看测试红不红是查不出来的');
      expect(find.byType(ChatScreen), findsNothing);
    });

    testWidgets('8.11① 后台那趟被抢占后收尾，不许清掉发送前那趟正在显示的提示',
        (tester) async {
      // 两趟压缩同时存在：空闲 2 秒后后台那趟先跑起来（第 1 次摘要调用被卡住），
      // 用户随后发送 ⇒ 抢占它、并开始自己的发送前压缩（第 2 次调用被卡住）。
      // 这时让后台那趟以"被取消"结束：它收尾时**不许**清掉用户那趟正在显示的提示。
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(const Key('compaction-status-banner'));
      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar();
      final provider = _PerCallGatedSummaryProvider()..gateOnlyFirst = 2;
      // 40 条 × 29 raw（`growConversation` 每条是 'A'×100 ⇒ 估算 29，不是 100）≈ 1160：
      // 已经超过压缩阈值（容量 2000 ⇒ 阈值 500），但占容量的 58% < 75% ⇒ 第 1 轮不会被
      // "发送前压缩"拦住；而空闲后的后台折叠读的是库里的历史（> 500）⇒ 它照样会压。
      // 这样才构造得出"两趟同时存在"。
      await growConversation(mgr, 40);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar, summaryProvider: provider, msgRepo: mgr));
      await tester.pump();
      await tester.pump();

      // 第 1 轮：占比 60% ⇒ 不该压；回复一条 2000 字的，把界面历史撑到 75% 以上。
      sidecar
        ..queueChunk('R' * 2000)
        ..queueDone();
      await tester.enterText(find.byType(TextField), 'a');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.11① 第 1 轮（占比 60%）：调用次数=${provider.calls} '
          'banner=${banner.evaluate().length} [expect 0 / 0]');
      expect(provider.calls, 0,
          reason: '前提：第 1 轮占比不到 75% ⇒ 这一轮不压（走"不等"那条路径）');

      // 空闲 2 秒 ⇒ 后台那趟启动，卡在第 1 次摘要调用上。
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.11① 后台那趟起来后：调用次数=${provider.calls} '
          'banner=${banner.evaluate().length} [expect >=1 / 1]');
      expect(provider.calls, greaterThanOrEqualTo(1),
          reason: '前提：后台那趟真的跑到了生成摘要这一步');
      expect(banner, findsOneWidget, reason: '后台那趟在跑 ⇒ 提示应该在');

      // 用户发送 ⇒ 抢占后台那趟，并开始自己的发送前压缩（第 2 次调用）。
      await tester.enterText(find.byType(TextField), 'second');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.11① 用户这趟开始压：调用次数=${provider.calls} '
          'banner=${banner.evaluate().length} '
          '文案="${_bannerText(tester)}" '
          '已发给模型=${sidecar.lastMessagesJson != null} [expect >=2 / 1]');
      expect(provider.calls, greaterThanOrEqualTo(2),
          reason: '前提：用户这一轮也在压（两趟同时在跑）');
      expect(banner, findsOneWidget);

      // 模拟"取消到达"：后台那趟以异常结束 ⇒ 它收尾时不许清掉用户那趟的状态。
      provider.gates.first.completeError(StateError('preempted/fold cancelled'));
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.11① 后台那趟收尾之后：banner=${banner.evaluate().length} '
          '[expect 1 —— 用户那趟还在跑]');
      expect(banner, findsOneWidget,
          reason: '后台那趟被抢占后收尾，不许把用户那趟正在显示的提示清掉'
              '（状态要有归属：谁置位谁清）');

      // 放行用户那趟，让这一轮正常结束。
      for (final g in provider.gates) {
        if (!g.isCompleted) g.complete(SummaryResult(text: 'L1', tokens: 1));
      }
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.11① 两趟都收尾后：banner=${banner.evaluate().length} [expect 0]');
      expect(banner, findsNothing, reason: '两趟都结束后提示要回到空闲');
    });

    testWidgets('8.11② 压缩期间切到另一个会话：新会话界面上不许留着提示',
        (tester) async {
      // 发送前那趟压缩被卡住（提示在），然后切到另一个会话 —— 那个提示属于旧会话，
      // 不许挂在新会话界面上。
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(const Key('compaction-status-banner'));
      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _PerCallGatedSummaryProvider()..gateOnlyFirst = 1;
      // 60 条 × 29 raw ≈ 1740 ⇒ 占容量 2000 的 87% > 75% ⇒ 这一轮该等（会压）。
      await growConversation(mgr, 60);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar,
          summaryProvider: provider,
          msgRepo: mgr,
          sessions: testSessions(2)));
      await tester.pump();
      await tester.pump();

      // 明确选中"有历史那一条"：两个会话的 updatedAt 可能同毫秒，默认选中哪条不确定。
      await tester.tap(find.text('Session 1'));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.11② 发送后（压缩卡住）：调用次数=${provider.calls} '
          'banner=${banner.evaluate().length} 文案="${_bannerText(tester)}" '
          '已发给模型=${sidecar.lastMessagesJson != null} '
          '库里本会话消息数=${mgr.messages.length} [expect >=1 / 1]');
      expect(banner, findsOneWidget, reason: '前提：这一轮在为压缩等待，提示在');

      // 切到另一个会话。
      await tester.tap(find.text('Session 2'));
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.11② 切到 Session 2 之后：banner=${banner.evaluate().length} '
          '[expect 0 —— 旧会话的压缩提示不许跟过来]');
      expect(banner, findsNothing,
          reason: '压缩状态属于一个会话：切走之后旧会话的提示不许挂在新会话界面上');

      // 放行那趟压缩，收尾。
      for (final g in provider.gates) {
        if (!g.isCompleted) g.complete(SummaryResult(text: 'L1', tokens: 1));
      }
      await tester.pump();
      await tester.pump();
      expect(banner, findsNothing);
    });
  });
}

/// 读出提示里的文案（现场证据用）。提示还不存在时返回空串。
String _bannerText(WidgetTester tester) {
  final f = find.byKey(const Key('compaction-status-banner'));
  if (f.evaluate().isEmpty) return '';
  final texts = find
      .descendant(of: f, matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .toList();
  return texts.join(' | ');
}

/// 每次摘要调用一个自己的闸门（`gates[i]` 对应第 i+1 次调用），用来构造"两趟压缩
/// 同时在跑"：第 1 次是空闲后台那趟、第 2 次是用户发送触发的那趟。测试可以只放行
/// 其中一趟（或只让某一趟以异常收尾），从而复现"谁先结束谁清状态"那类交错。
class _PerCallGatedSummaryProvider implements SummaryProvider {
  final List<Completer<SummaryResult>> gates = [];
  int calls = 0;

  /// 第几次调用之后不再挂住（默认一直挂住）：一趟压缩可能要生成好几段，收尾时
  /// 只放行已存在的闸门是不够的 —— 后续段会新建闸门，所以用这个开关让它自然跑完。
  int? gateOnlyFirst;

  bool _gated() {
    final limit = gateOnlyFirst;
    return limit == null || calls <= limit;
  }

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) {
    calls++;
    if (!_gated()) return Future.value(SummaryResult(text: 'L1', tokens: 1));
    final g = Completer<SummaryResult>();
    gates.add(g);
    return g.future;
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) {
    calls++;
    if (!_gated()) return Future.value(SummaryResult(text: 'L2', tokens: 1));
    final g = Completer<SummaryResult>();
    gates.add(g);
    return g.future;
  }
}
