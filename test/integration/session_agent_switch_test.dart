import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_session_controller.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/ui/input_bar.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 当前 Session 的 Agent 模板切换（任务 3.6）。
///
/// 从**界面**往返回切换并发送，核对：数据库 `sessions.agent_type`、实际请求的模型 /
/// 推理配置 / 系统提示词 / 工具、聊天区新消息、历史保留、旧 Agent 退役且不销毁上下文、
/// 旧占用快照清除、其它 Session 不变、无会话直接发送仍自动创建 `general`；切换中
/// 回车 / 点发送 / 直接调用数据层发送入口三条路径都被拒绝；退役、写库、创建失败分别
/// 显示阶段与候选名并回读数据库；真实文件证明旧 `read_spill` 引用仍可读、新溢出文件
/// 不覆盖旧引用。
void main() {
  setUp(() {
    _setupTemplates();
  });

  tearDown(() {
    registry.clear();
  });

  testWidgets('从界面切换模板：数据库、实际请求、聊天区、历史、快照与其它会话', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sessions = [_session('s1'), _session('s2')];
    final sessionRepo = _SwitchSessionRepo(sessions);
    final msgRepo = FakeMessageRepository();
    final sidecar = FakeSidecar();
    final agents = AgentRegistry();

    await tester.pumpWidget(_app(
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      msgRepo: msgRepo,
      agents: agents,
    ));
    await tester.pumpAndSettle();
    final otherBefore = agents.lookup('s2');
    expect(otherBefore, isNotNull, reason: '启动时每个会话都应有实例');

    // 第一轮：general 模板。
    sidecar.queueChunk('通用回复');
    sidecar.queueDone();
    await tester.enterText(find.byType(TextField), '第一问');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
    final oldAgent = state.currentAgent!;
    // ignore: avoid_print
    print('  [OBS] 切换前：实例模板=${oldAgent.agentTypeName} 请求 model=${sidecar.lastModel} '
        'ensureContext=${sidecar.ensureContextCalls}');
    expect(sidecar.lastModel, 'general-model');
    expect(find.text('第一问'), findsOneWidget);
    expect(find.text('通用回复'), findsOneWidget);

    // 从界面切换：点控件 → 选 reviewer。
    await tester.tap(find.byKey(const ValueKey('session-agent-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('reviewer').last);
    await tester.pumpAndSettle();

    final fresh = state.currentAgent!;
    // ignore: avoid_print
    print('  [OBS] 切换后：新实例=${fresh.agentTypeName} 旧实例退役=${oldAgent.isRetiring} '
        '数据库=${sessionRepo.sessions.first.agentType} 快照=${state.contextSnapshot} '
        'disposeContext=${sidecar.disposeContextCalls} '
        'ensureContext=${sidecar.ensureContextCalls} 其它会话实例一致='
        '${identical(agents.lookup('s2'), otherBefore)}');
    expect(identical(fresh, oldAgent), isFalse, reason: '必须换成新实例');
    expect(fresh.agentTypeName, 'reviewer');
    expect(oldAgent.isRetiring, isTrue, reason: '旧 Agent 对象必须已退役');
    expect(oldAgent.isDisposed, isFalse, reason: '退役不等于销毁');
    expect(sessionRepo.sessions.first.agentType, 'reviewer',
        reason: '数据库 sessions.agent_type 必须已更新');
    expect(state.contextSnapshot, isNull, reason: '旧实例的占用快照必须清除');
    expect(sidecar.disposeContextCalls, isEmpty,
        reason: '退役不得调用 disposeContext（那会删掉溢出目录）');
    expect(sidecar.ensureContextCalls.where((h) => h == 's1').length, 2,
        reason: '新实例沿用同一 Session 句柄（created:false）');
    expect(identical(agents.lookup('s2'), otherBefore), isTrue,
        reason: '其它 Session 的实例不受影响');
    expect(otherBefore!.isRetiring, isFalse);
    expect(sessionRepo.sessions[1].agentType, 'general');
    // 界面 Session 也更新了：选择框显示新模板名。
    final switchedDropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    expect(switchedDropdown.value, 'reviewer',
        reason: '切换后界面 Session 必须同步成新模板');

    // 第二轮：新模板真的生效。
    sidecar.queueChunk('评审回复');
    sidecar.queueDone();
    await tester.enterText(find.byType(TextField), '第二问');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 切换后请求：model=${sidecar.lastModel} '
        'thinking=${sidecar.lastThinkingMode}/${sidecar.lastThinkingEffort} '
        'system=${sidecar.lastSystemPrompt} tools=${sidecar.lastToolsJson}');
    expect(sidecar.lastModel, 'reviewer-model');
    // 系统提示词会被产品附加"当前日期"一段（既有行为），所以判据是"含本模板的
    // 系统提示词、且不含 general 的"。
    expect(sidecar.lastSystemPrompt, contains('REVIEWER'));
    expect(sidecar.lastSystemPrompt, isNot(contains('GENERAL')));
    expect(sidecar.lastThinkingMode, 'adaptive');
    expect(sidecar.lastThinkingEffort, 'max');
    expect(sidecar.lastToolsJson, contains('run_command'));
    // 聊天区：历史保留 + 切换后新消息出现（通过界面回调）。
    expect(find.text('第一问'), findsOneWidget);
    expect(find.text('通用回复'), findsOneWidget);
    expect(find.text('第二问'), findsOneWidget);
    expect(find.text('评审回复'), findsOneWidget);
    expect(state.finalAssistantReply, '评审回复');
  });

  testWidgets('没有当前会话：只禁用选择控件，直接发送仍自动创建 general', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sessions = <Session>[];
    final sessionRepo = _SwitchSessionRepo(sessions);
    final msgRepo = FakeMessageRepository();
    final sidecar = FakeSidecar();

    await tester.pumpWidget(_app(
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      msgRepo: msgRepo,
      agents: AgentRegistry(),
    ));
    await tester.pumpAndSettle();

    final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    // ignore: avoid_print
    print('  [OBS] 无会话时选择控件 onChanged=${dropdown.onChanged} '
        'items=${dropdown.items?.length}');
    expect(dropdown.onChanged, isNull, reason: '没有当前会话时只禁用选择控件');

    sidecar.queueChunk('首条回复');
    sidecar.queueDone();
    await tester.enterText(find.byType(TextField), '首条消息');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    // ignore: avoid_print
    print('  [OBS] 无会话直接发送：sessions=${sessionRepo.sessions.length} '
        'agentType=${sessionRepo.sessions.isEmpty ? null : sessionRepo.sessions.first.agentType} '
        'sendHandles=${sidecar.sendHandles}');
    expect(sessionRepo.sessions, hasLength(1), reason: '直接发送仍要自动创建会话');
    expect(sessionRepo.sessions.first.agentType, 'general');
    expect(sidecar.sendHandles, [sessionRepo.sessions.first.id],
        reason: '发送不能因为新增守卫而被拒绝');
    expect(find.text('首条消息'), findsOneWidget);
    expect(find.text('首条回复'), findsOneWidget);
  });

  testWidgets('切换中按回车、点发送、直接调用发送入口都被拒绝', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sessions = [_session('s1')];
    final sessionRepo = _SwitchSessionRepo(sessions);
    final msgRepo = FakeMessageRepository();
    final sidecar = FakeSidecar();
    final agents = AgentRegistry();
    final gate = Completer<void>();
    final started = Completer<void>();
    final controller = AgentSessionController(
      factory: _factory(
        sidecar: sidecar,
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        agents: agents,
      ),
      sessionRepo: sessionRepo,
      retireAgent: (agent) async {
        started.complete();
        await gate.future;
        await agent.retire();
      },
    );

    await tester.pumpWidget(_app(
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      msgRepo: msgRepo,
      agents: agents,
      controller: controller,
    ));
    await tester.pumpAndSettle();
    final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
    final sentBefore = sidecar.sendHandles.length;

    await tester.tap(find.byKey(const ValueKey('session-agent-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('reviewer').last);
    // 让菜单 pop 与 onChanged 都跑完：切换进入"等待退役"这一段（闸门还没开）。
    await tester.pumpAndSettle();
    expect(started.isCompleted, isTrue, reason: '切换必须已经走到退役步骤');
    await started.future;
    await tester.pump();

    // ignore: avoid_print
    print('  [OBS] 切换中：isSwitchingTemplate=${state.isSwitchingTemplate} '
        '发送按钮提示=${find.byTooltip('正在切换 Agent 模板…').evaluate().length}');
    expect(state.isSwitchingTemplate, isTrue);
    expect(find.byTooltip('正在切换 Agent 模板…'), findsOneWidget,
        reason: '切换中发送按钮必须禁用');

    // ① 回车。
    await tester.enterText(find.byType(TextField), '切换中回车');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sidecar.sendHandles.length, sentBefore, reason: '回车不能在切换中穿透');
    expect(find.text('切换中回车'), findsOneWidget, reason: '被拒绝后输入内容不能被清掉');

    // ② 点发送按钮（已禁用）。
    await tester.tap(find.byTooltip('正在切换 Agent 模板…'));
    await tester.pump();
    expect(sidecar.sendHandles.length, sentBefore, reason: '禁用的按钮不能发送');

    // ③ 直接调用 InputBar 的提交入口（绕过禁用按钮与回车）：_submitInput 也要拦。
    final bar = tester.widget<InputBar>(find.byType(InputBar));
    bar.onSubmit();
    await tester.pump();
    expect(sidecar.sendHandles.length, sentBefore,
        reason: '_submitInput 数据层必须再拦一次');

    // ④ 直接调用数据层发送入口（_sendMessage）。
    await state.sendMessageDirectly('直接调用');
    await tester.pump();
    expect(sidecar.sendHandles.length, sentBefore, reason: '数据层必须再拦一次');
    expect(find.byKey(const ValueKey('switch-blocked-notice')), findsOneWidget,
        reason: '被拒绝要有可见提示，不能静默');

    gate.complete();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 切换结束后：新实例=${state.currentAgent?.agentTypeName} '
        'sendHandles=${sidecar.sendHandles} 期间发送数=${sidecar.sendHandles.length - sentBefore}');
    expect(state.currentAgent!.agentTypeName, 'reviewer');
    expect(sidecar.sendHandles.length, sentBefore,
        reason: '整个切换期间没有任何发送落到旧实例或新实例');

    // 正向对照：切换结束后同样的"回车"必须真的能发出去 —— 证明上面那条拒绝不是
    // 因为回车事件根本没到输入行（否则用例会假绿）。
    sidecar.queueChunk('切换后回车发送成功');
    sidecar.queueDone();
    await tester.enterText(find.byType(TextField), '切换后回车');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 切换后回车：sendHandles=${sidecar.sendHandles} '
        '请求 model=${sidecar.lastModel}');
    expect(sidecar.sendHandles.length, sentBefore + 1,
        reason: '切换结束后回车必须能发送（正向对照）');
    expect(sidecar.lastModel, 'reviewer-model');
  });

  testWidgets('退役失败：红条显示阶段与候选名，选择框回读数据库（仍是旧值）', (tester) async {
    await _pumpFailureApp(tester,
        controllerBuilder: (factory, repo) => AgentSessionController(
              factory: factory,
              sessionRepo: repo,
              retireAgent: (_) async => throw StateError('退役注入失败'),
            ));
    await _switchTo(tester, 'reviewer');

    final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
    final error = find.byKey(const ValueKey('agent-error-notice'));
    final errorText = _textOf(error);
    final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    // ignore: avoid_print
    print('  [OBS] 退役失败：错误=$errorText 选择框=${dropdown.value} '
        '实例模板=${state.currentAgent?.agentTypeName}');
    expect(error, findsOneWidget);
    expect(errorText, contains('退役旧实例'));
    expect(errorText, contains('reviewer'));
    expect(dropdown.value, 'general', reason: '失败后选择框必须显示数据库里的实际值');
    expect(state.currentAgent!.agentTypeName, 'general',
        reason: '退役失败时旧实例仍在运行');
  });

  testWidgets('写库失败：红条显示阶段与候选名，选择框回读数据库（仍是旧值）', (tester) async {
    final repo = await _pumpFailureApp(tester);
    repo.failUpdate = true;
    await _switchTo(tester, 'reviewer');

    final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    final errorText = _textOf(find.byKey(const ValueKey('agent-error-notice')));
    // ignore: avoid_print
    print('  [OBS] 写库失败：错误=$errorText 选择框=${dropdown.value} '
        '数据库=${repo.sessions.first.agentType}');
    expect(errorText, contains('持久化 agent_type'));
    expect(errorText, contains('reviewer'));
    expect(dropdown.value, 'general');
    expect(repo.sessions.first.agentType, 'general', reason: '写库失败时数据库不得变成新模板');
  });

  testWidgets('创建失败：红条显示阶段与候选名，选择框显示已保存的新模板', (tester) async {
    final repo = await _pumpFailureApp(tester,
        failCreate: true);
    await _switchTo(tester, 'reviewer');

    final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
    final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    final errorText = _textOf(find.byKey(const ValueKey('agent-error-notice')));
    // ignore: avoid_print
    print('  [OBS] 创建失败：错误=$errorText 选择框=${dropdown.value} '
        '数据库=${repo.sessions.first.agentType} 当前实例=${state.currentAgent}');
    expect(errorText, contains('创建新实例'));
    expect(errorText, contains('reviewer'));
    expect(repo.sessions.first.agentType, 'reviewer', reason: '写库已经成功');
    expect(dropdown.value, 'reviewer',
        reason: '选择框显示数据库实际保存值（但红条说明实例没建起来）');
    expect(state.currentAgent, isNull, reason: '新实例没创建成功，不能假装它已经在跑');
  });

  test('模板切换等旧实例在途整轮自然结束：不取消请求，发送结果仍是完成', () async {
    final sessions = [_session('s1')];
    final sessionRepo = _SwitchSessionRepo(sessions);
    final msgRepo = FakeMessageRepository();
    final sidecar = FakeSidecar();
    final agents = AgentRegistry();
    final factory = _factory(
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      msgRepo: msgRepo,
      agents: agents,
    );
    final old = await factory.create(sessions.first);
    sidecar.gateNextSend();
    sidecar.queueChunk('切换期间的自然回复-独特');
    sidecar.queueDone();
    final sendFuture = old.send('切换期间的问题-独特');
    for (var i = 0; i < 100 && !old.isStreaming; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(old.isStreaming, isTrue,
        reason: '旧实例必须先真的在途，用例才测得到退役等待');

    final cancelsBefore = sidecar.cancelCount;
    final controller =
        AgentSessionController(factory: factory, sessionRepo: sessionRepo);
    final switchFuture = controller.switchTemplate(sessions.first, 'reviewer',
        callbacks: const AgentCallbacks());
    // 让退役路径跑到"等在途整轮"这一步。
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // ignore: avoid_print
    print('  [OBS] 退役等待中：旧实例退役=${old.isRetiring} '
        '取消增量=${sidecar.cancelCount - cancelsBefore} '
        '仍在切换=${controller.isSwitching('s1')} 注册表=${agents.handles}');
    expect(old.isRetiring, isTrue, reason: '切换必须已经进到退役步骤');
    expect(sidecar.cancelCount, cancelsBefore,
        reason: '退役不得取消在途整轮（那是切换会做的事之外的破坏）');
    expect(agents.contains('s1'), isTrue,
        reason: '整轮没结束前旧实例仍在注册表里');

    sidecar.releaseGate();
    final result = await sendFuture;
    final fresh = await switchFuture;
    // ignore: avoid_print
    print('  [OBS] 自然结束：发送结果=${result.status.name} '
        'finalText=${result.finalText} 新实例=${fresh.agentTypeName} '
        '消息=${msgRepo.messages.map((m) => '${m.role}:${m.content}').toList()} '
        'sendHandles=${sidecar.sendHandles}');

    expect(result.status, AgentRunStatus.completed,
        reason: '在途整轮必须自然结束为完成，不能因为切换被取消');
    expect(result.finalText, '切换期间的自然回复-独特');
    expect(fresh.agentTypeName, 'reviewer');
    expect(identical(fresh, old), isFalse);
    expect(old.isRetiring, isTrue);
    expect(msgRepo.messages.where((m) => m.role == 'assistant').length, 1,
        reason: '自然结束只写一条助手消息，不重复');
    expect(sidecar.sendHandles.length, 1,
        reason: '整个切换过程没有额外模型请求');
  });

  test('真实文件：切换后旧 read_spill 引用仍可读，新溢出文件不覆盖旧引用', () async {
    final bridge = SidecarBridge.instance;
    const ctx = 'it-switch-spill';
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    expect(home.isNotEmpty, isTrue, reason: '拿不到用户主目录就没法定位 spill 根');
    final spillDir = Directory('$home/.aliasagent/spill/$ctx');

    Future<Map<String, dynamic>> runBig(String marker) async {
      final raw = await bridge.runCommand(
        ctx,
        jsonEncode({
          'command':
              "1..400 | ForEach-Object { Write-Output ('$marker' + ('x' * 40)) }",
          'preview_chars': 200,
        }),
      );
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    try {
      if (spillDir.existsSync()) spillDir.deleteSync(recursive: true);
      await bridge.ensureContext(ctx, defaultWorkspace: '.');
      bridge.setWorkspace(ctx, '.');

      // ① 旧实例产生溢出文件与引用。
      final first = await runBig('OLD-');
      final oldSpill = (first['spill'] as Map?)?['stdout'] as Map?;
      expect(oldSpill, isNotNull, reason: '大输出必须产生 spill 引用：$first');
      final oldRef = oldSpill!['ref'] as String;
      final oldTotal = oldSpill['total_bytes'] as int;
      final oldBytes = File(oldRef).readAsBytesSync();
      expect(oldBytes.length, oldTotal);
      final before = jsonDecode(
              bridge.readSpill(ctx, jsonEncode({'ref': oldRef, 'offset': 0, 'limit': 64})))
          as Map<String, dynamic>;
      expect(before['ok'], isTrue, reason: '切换前旧引用必须可读：$before');
      // ignore: avoid_print
      print('  [OBS] 旧 spill 引用=$oldRef total=$oldTotal '
          '文件存在=${File(oldRef).existsSync()}');

      // ② 切换模板：旧 Agent 对象退役，新实例沿用同一句柄。
      registry.clear();
      _setupTemplates();
      final sessionRepo = _SwitchSessionRepo([_session(ctx)]);
      final factory = _factory(
        sidecar: bridge,
        sessionRepo: sessionRepo,
        msgRepo: FakeMessageRepository(),
        agents: AgentRegistry(),
      );
      final oldAgent = await factory.create(sessionRepo.sessions.first);
      final controller =
          AgentSessionController(factory: factory, sessionRepo: sessionRepo);
      final fresh = await controller.switchTemplate(sessionRepo.sessions.first,
          'reviewer', callbacks: const AgentCallbacks());
      // ignore: avoid_print
      print('  [OBS] 切换后：新实例=${fresh.agentTypeName} 旧实例退役=${oldAgent.isRetiring} '
          '溢出目录仍存在=${spillDir.existsSync()}');

      expect(fresh.agentTypeName, 'reviewer');
      expect(oldAgent.isRetiring, isTrue);
      expect(spillDir.existsSync(), isTrue,
          reason: '退役不得调用 disposeContext（它会删掉溢出目录）');
      expect(File(oldRef).existsSync(), isTrue, reason: '旧溢出文件必须还在');

      final after = jsonDecode(
              bridge.readSpill(ctx, jsonEncode({'ref': oldRef, 'offset': 0, 'limit': 64})))
          as Map<String, dynamic>;
      // ignore: avoid_print
      print('  [OBS] 切换后读旧引用：ok=${after['ok']} text=${after['text']}');
      expect(after['ok'], isTrue, reason: '切换后旧 read_spill 引用仍必须可读：$after');
      expect(after['text'], before['text']);
      expect(File(oldRef).readAsBytesSync(), oldBytes, reason: '旧文件字节不得被改写');

      // ③ 新输出产生新溢出文件，且不覆盖旧引用。
      final second = await runBig('NEW-');
      final newSpill = (second['spill'] as Map)['stdout'] as Map;
      final newRef = newSpill['ref'] as String;
      // ignore: avoid_print
      print('  [OBS] 新 spill 引用=$newRef 与旧引用相同=${newRef == oldRef}');
      expect(newRef, isNot(oldRef), reason: '新溢出文件必须用新引用，不能覆盖旧文件');
      expect(File(newRef).existsSync(), isTrue);
      final oldAgain = jsonDecode(
              bridge.readSpill(ctx, jsonEncode({'ref': oldRef, 'offset': 0, 'limit': 64})))
          as Map<String, dynamic>;
      expect(oldAgain['ok'], isTrue, reason: '新输出之后旧引用仍必须可读：$oldAgain');
      expect(File(oldRef).readAsBytesSync(), oldBytes);
      expect(utf8.decode(File(newRef).readAsBytesSync().sublist(0, 4)), 'NEW-');
    } finally {
      try {
        bridge.cancelRequest(ctx);
      } catch (_) {}
      await bridge.disposeContext(ctx);
    }
    // disposeContext 是真正销毁路径：到这里目录必须被删掉 —— 证明上面保留旧文件
    // 确实是"退役不 disposeContext"，而不是碰巧没人删。
    expect(spillDir.existsSync(), isFalse,
        reason: 'disposeContext 应删掉溢出目录（与退役路径形成对照）');
  });
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

Session _session(String id) => Session(
      id: id,
      title: 'Session $id',
      agentType: 'general',
      createdAt: 1,
      updatedAt: 1,
    );

void _setupTemplates() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'general-model',
    systemPrompt: 'GENERAL',
    tools: ['read_file'],
    maxContextTokens: 100000,
  ));
  registry.register(const AgentTypeConfig(
    name: 'reviewer',
    provider: 'test',
    model: 'reviewer-model',
    systemPrompt: 'REVIEWER',
    tools: ['read_file', 'run_command'],
    thinkingEffort: 'max',
    maxContextTokens: 64000,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
    },
  ));
}

AgentFactory _factory({
  required ISidecar sidecar,
  required SessionRepository sessionRepo,
  required MessageRepository msgRepo,
  required AgentRegistry agents,
  bool backgroundFoldEnabled = false,
  bool failNextCreate = false,
}) =>
    _TestFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: backgroundFoldEnabled,
      summaryStoreOpen: () => false,
      failNextCreate: failNextCreate,
    );

Widget _app({
  required ISidecar sidecar,
  required SessionRepository sessionRepo,
  required MessageRepository msgRepo,
  required AgentRegistry agents,
  AgentSessionController? controller,
}) =>
    MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: sessionRepo,
          msgRepo: msgRepo,
          sidecar: sidecar,
          summaryProvider: FakeSummaryProvider(),
          backgroundFoldEnabled: false,
          agentRegistry: agents,
          agentSessionController: controller,
        ),
      ),
    );

/// 点开选择框并选中 [name]。
Future<void> _switchTo(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('session-agent-switcher')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

String _textOf(Finder finder) {
  final inner = find.descendant(of: finder, matching: find.byType(Text));
  if (inner.evaluate().isNotEmpty) {
    return (inner.evaluate().first.widget as Text).data ?? '';
  }
  final widget = finder.evaluate().first.widget;
  return widget is Text ? (widget.data ?? '') : '';
}

/// 带失败注入能力的会话仓库（记事件、可让写库失败）。
class _SwitchSessionRepo extends FakeSessionRepository {
  _SwitchSessionRepo(super.sessions);

  bool failUpdate = false;
  int updateCalls = 0;

  @override
  Future<Session> updateAgentType(String id, String agentType) async {
    updateCalls++;
    if (failUpdate) throw StateError('写库注入失败');
    return super.updateAgentType(id, agentType);
  }
}

/// 可以注入"创建失败"的工厂（只覆盖 [AgentFactory.create]）。
class _TestFactory extends AgentFactory {
  _TestFactory({
    required super.templates,
    required super.providerResolver,
    required super.config,
    required super.sidecar,
    required super.sessionRepo,
    required super.messageRepo,
    required super.summaryNodeRepo,
    required super.registry,
    super.summaryProvider,
    super.backgroundFoldEnabled,
    super.summaryStoreOpen,
    this.failNextCreate = false,
  });

  bool failNextCreate;

  @override
  Future<Agent> create(Session session,
      {AgentCallbacks callbacks = const AgentCallbacks(),
      ChildRunOptions? child}) {
    if (failNextCreate) {
      failNextCreate = false;
      throw StateError('创建注入失败');
    }
    return super.create(session, callbacks: callbacks, child: child);
  }
}

/// 组装一个带失败注入的界面，返回会话仓库（用例要在两处设置失败）。
Future<_SwitchSessionRepo> _pumpFailureApp(
  WidgetTester tester, {
  AgentSessionController Function(AgentFactory factory, _SwitchSessionRepo repo)?
      controllerBuilder,
  bool failCreate = false,
}) async {
  tester.view.physicalSize = const Size(1500, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final sessions = [_session('s1')];
  final repo = _SwitchSessionRepo(sessions);
  final msgRepo = FakeMessageRepository();
  final sidecar = FakeSidecar();
  final agents = AgentRegistry();
  final factory = _factory(
    sidecar: sidecar,
    sessionRepo: repo,
    msgRepo: msgRepo,
    agents: agents,
    failNextCreate: failCreate,
  );
  final controller = controllerBuilder != null
      ? controllerBuilder(factory, repo)
      : AgentSessionController(factory: factory, sessionRepo: repo);
  await tester.pumpWidget(_app(
    sidecar: sidecar,
    sessionRepo: repo,
    msgRepo: msgRepo,
    agents: agents,
    controller: controller,
  ));
  await tester.pumpAndSettle();
  return repo;
}
