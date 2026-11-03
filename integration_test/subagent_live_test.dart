@Tags(['live'])
library;

// 真实模型下的子 Agent 验收（change `add-spawn-subagent-tool` 任务 7.2）。
//
// 假 sidecar 用例已经证明父子执行链路与本地资源行为；这条用例只回答一个假 sidecar
// 回答不了的问题：**真实父模型愿不愿意按任务真的调用 `spawn_subagent`**，以及真实
// 子模型的结论是不是原样回到父会话、子中间消息有没有漏进父历史。
//
// 覆盖四件事（共用同一次真实运行）：
//   ① 父模板 tools 含 `spawn_subagent`、子模板不含；父提示明确要求创建子 Agent，
//      子任务里带一条本次运行独有的结论标记并要求子 Agent 原样返回；
//   ② 真实父模型真的调用 `spawn_subagent`（已完成的工具卡），结果含该结论，
//      父会话的工具调用记录带 `child_session_id` / 实际模板 / 模型 / 子计量；
//   ③ 子会话存在且 `parent_session_id` 指向父会话；子中间消息只在子会话；
//   ④ 父最终回复正常落地；父历史（数据库 + 真正发给模型的那份快照）不含子中间
//      消息的独特标记。
//
// 失败口径（任务 7.2 / spec「真实模型调用子 Agent 的过程必须可观察和验收」）：
// 模型不调用工具、调用错误模板、子运行失败、结论缺失都算失败，**不许**当跳过；
// 只有配置不完整或 `Error:` 前缀的接口错误按既有 live 规则 `markTestSkipped`。
// 进入真实运行后的所有出口（通过 / 失败 / 跳过 / 超时）都在 try/finally 里
// `captureLiveShot` 到 `test/live_visual/subagent_live.png`，供主循环 `read_image`
// 做视觉验收；配置不完整的提前跳过发生在开始运行之前，由 setUp 的
// `clearLiveVisualDir()` 保证不会留下上一轮的旧图冒充这次结果。
//
// 运行方式（真机执行，需要真实模型与窗口）：
//   flutter test --tags live --run-skipped integration_test/subagent_live_test.dart -d windows
// 前提：仓库根的 sidecar.dll 已按项目入口刷新；`~/.aliasagent/config.json` 里有
// `general` 模板的 api_key / base_url / model / max_context_tokens，且能联网。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import 'live_observability.dart';

/// 父模板沿用它，才能通过 `AppShell._loadConfig` 对 `general.max_context_tokens`
/// 的启动检查（缺窗口会弹首启补问对话框，挡住对话输入）。
const String _parentTemplate = 'general';

/// 子模板名字：父提示里必须点名它，用来验证"调用的是不含 `spawn_subagent` 的那个
/// 模板"，而不是省略参数继承父模板。
const String _childTemplate = 'subagent-live-child';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // integration_test 跑的是本文件自己的 main()，`lib/main.dart` 里的 `main()`
  // 不执行，所以全局 `databaseFactory` 需要在测试里显式设好（与既有 live 用例
  // real_api_test.dart / compact_quality_live_test.dart 一致）。
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_subagent_live_');
    // 独立临时数据库：不碰用户唯一那份库；tearDown 关库并删目录。
    await DatabaseService.openAt(tempDir.path);
    // 先清掉上一次运行留下的截图，免得跳过路径（配置不完整时还没进 try/finally）
    // 让旧 PNG 看起来像这次的结果（沿用 live_observability.dart 的既有清理口径）。
    clearLiveVisualDir();
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上文件可能还被占着，交给系统清理临时目录。
      }
    }
  });

  testWidgets(
    '真实父模型创建子 Agent：spawn_subagent 完成、结论回传、子记录关联父会话',
    (tester) async {
      // ------------------------------------------------------------------
      // ① 真实 provider 解析（沿用既有 live 口径：环境变量优先，其次产品配置）。
      final cfg = _resolveLiveConfig();
      if (cfg == null) {
        markTestSkipped('配置不完整（${ConfigService.configPath}）：真实子 Agent 验收'
            '需要 api_key + base_url + model + max_context_tokens 都可用；缺任一项'
            '按既有 live 规则跳过，不伪造结果。');
        return;
      }

      // ------------------------------------------------------------------
      // ② 本次运行独有的结论标记：父提示要求父模型把它放进子任务，并让子 Agent
      // 原样返回；整条用例的"结论到了没有"都以这个串为准。
      final runId = const Uuid().v4();
      final conclusionMarker = 'SUBAGENT-LIVE-$runId';
      final conclusionLine = '结论标记：$conclusionMarker';

      // 父模板 = 基础工具全量（含 spawn_subagent）；子模板 = 基础工具去掉
      // spawn_subagent（第一版不能嵌套）。清单来自产品常量，不手写第二份。
      final parentTools = List<String>.of(ToolCatalog.kBaseToolNames);
      final childTools = [
        for (final name in ToolCatalog.kBaseToolNames)
          if (name != 'spawn_subagent') name,
      ];

      final parentSystemPrompt = '你是父 Agent，负责把子任务交给一次性子 Agent。\n'
          '只要用户要求创建子 Agent，你就必须调用 spawn_subagent 工具，不要自己'
          '完成子任务，也不要用文字描述代替工具调用。\n'
          '调用时 agent_type 必须是用户点名的模板名，task 必须完整包含用户给出的'
          '结论标记与执行要求。\n'
          '工具返回后，把子 Agent 的结论原文写进你的最终回复。';
      final childSystemPrompt = '你是一次性子 Agent：你看不到父对话，本次任务就是'
          '你收到的全部输入。\n'
          '开始前必须调用 get_current_time 工具确认当前时间（这是本次任务的固定'
          '第一步，不要跳过）。\n'
          '最终结论的第一行必须原样写出任务里给出的结论标记整行，然后再用一两句话'
          '补充；不要改写、不要省略这个标记。\n'
          '你的上下文会在结束时销毁：需要持续保留的内容要写进当前工作区的文件，'
          '不要只留下 read_spill 引用。';

      final parentPrompt = '请通过调用 spawn_subagent 工具创建一次性子 Agent 来完成'
          '下面这件事，不要自己直接回答：\n'
          '1. 必须真的调用 spawn_subagent（只描述不调用算失败）。\n'
          '2. agent_type 参数必须填 "$_childTemplate"。\n'
          '3. task 参数里必须完整包含下面这一行结论标记，并要求子 Agent 原样返回它：\n'
          '   $conclusionLine\n'
          '4. task 里还要要求子 Agent：动手前先调用 get_current_time 工具确认当前时间。\n'
          '5. 拿到子 Agent 的结论后，把结论原文写进你的最终回复。';

      // 两个模板都挂真实 provider / 模型 / 窗口；窗口取自真实配置（不是新造的
      // 数字），这样不会因为阈值过小而触发压缩、干扰工具循环。
      final config = AppConfig(
        version: 1,
        providers: {
          cfg.providerName: ProviderConfig(
            apiKey: cfg.apiKey,
            baseUrl: cfg.baseUrl,
          ),
        },
        agentTypes: {
          _parentTemplate: AgentTypeConfig(
            name: _parentTemplate,
            provider: cfg.providerName,
            model: cfg.model,
            systemPrompt: parentSystemPrompt,
            tools: parentTools,
            maxContextTokens: cfg.maxContextTokens,
          ),
          _childTemplate: AgentTypeConfig(
            name: _childTemplate,
            provider: cfg.providerName,
            model: cfg.model,
            systemPrompt: childSystemPrompt,
            tools: childTools,
            maxContextTokens: cfg.maxContextTokens,
          ),
        },
      );

      // 夹具自检：两个模板的工具清单必须一个含、一个不含 spawn_subagent。
      expect(parentTools, contains('spawn_subagent'),
          reason: '父模板的工具清单必须含 spawn_subagent（被测功能的入口）');
      expect(childTools, isNot(contains('spawn_subagent')),
          reason: '子模板的工具清单必须不含 spawn_subagent（第一版不能嵌套）');

      debugPrint('[OBS] 真实 provider=${cfg.providerName} model=${cfg.model} '
          'apiKey长度=${cfg.apiKey.length} 窗口=${cfg.maxContextTokens}');
      debugPrint('[OBS] 父模板=$_parentTemplate 工具=${parentTools.length} 项 '
          '含spawn=${parentTools.contains('spawn_subagent')}');
      debugPrint('[OBS] 子模板=$_childTemplate 工具=${childTools.length} 项 '
          '含spawn=${childTools.contains('spawn_subagent')}');
      debugPrint('[OBS] 本次运行独有结论标记：$conclusionLine');

      // ------------------------------------------------------------------
      // ③ 父会话建在独立临时库里；它是唯一的顶层会话，AppShell 启动后选中的就是它。
      final parentSession = await SessionRepository().create(
        title: 'subagent-live-parent',
        agentType: _parentTemplate,
      );

      // ------------------------------------------------------------------
      // ④ 启动真实 AppShell（configLoader 注入这份配置，其它一切走产品路径）。
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            home: AppShell(configLoader: () => ConfigResult.ok(config)),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2)); // AppShell 初始化 + 会话加载

      // 所有出口（通过/失败/跳过/超时）都在 finally 里截图，且此刻界面树还挂着。
      try {
        final textField = find.byType(TextField);
        expect(textField, findsOneWidget, reason: '对话输入框必须存在');
        await tester.enterText(textField, parentPrompt);

        // 工具清单没装好时输入行的提示是「正在准备工具…」而不是 'Send'，所以先等
        // 它出现再点（120 秒沿用 compact_quality_live_test.dart 的既有口径）。
        final sendButton = find.byTooltip('Send');
        for (var i = 0; i < 120 && sendButton.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(sendButton, findsOneWidget,
            reason: '发送按钮必须出现（工具就绪最多等 120 秒，沿用既有 live 口径）');
        await tester.tap(sendButton);
        await tester.pump();

        // 等待整轮结束：300 秒沿用 compact_quality_live_test.dart 的
        // `pumpUntilReplyOrTurnDone`，不新增超时数字。
        try {
          await pumpUntilReplyOrTurnDone(tester, timeoutSec: 300);
        } on TimeoutException {
          await dumpToolCards(tester, phase: 'subagent_live 等待父回复超时');
          dumpContext(tester, 'subagent_live 等待父回复超时');
          fail('300 秒内父对话没有出现最终回复（沿用既有 live 等待口径）：'
              '父模型或子运行把整轮卡住了');
        }

        // ------------------------------------------------------------------
        // ⑤ 回复门禁：静默结束是失败；只有 `Error:` 前缀的接口错误按既有口径跳过。
        final reply = readFinalAssistantReply(tester);
        if (reply == null) {
          await dumpToolCards(tester, phase: 'subagent_live 父回复静默结束');
          dumpContext(tester, 'subagent_live 父回复静默结束');
          fail('没有父最终回复（静默结束）：模型空回复或内部异常，'
              '见上面的 [OBS] 与 sidecar 日志');
        }
        if (reply.startsWith('Error:')) {
          await dumpToolCards(tester, phase: 'subagent_live 接口错误回复');
          dumpContext(tester, 'subagent_live 接口错误回复');
          markTestSkipped('API 不可用：$reply');
          return;
        }

        // ------------------------------------------------------------------
        // ⑥ 读库 + 读界面：断言前先把实际工具名、完整输入、状态、结果、最终回复、
        // 真实上下文与父子数据库记录全部打出来（CLAUDE.md「测试输出可观察」）。
        final parentMessages =
            await MessageRepository().queryBySession(parentSession.id);
        final childSessions =
            await SessionRepository().listChildren(parentSession.id);
        final childMessagesById = <String, List<Message>>{};
        for (final child in childSessions) {
          childMessagesById[child.id] =
              await MessageRepository().queryBySession(child.id);
        }

        await dumpToolCards(tester, phase: 'subagent_live 父工具卡（真实运行）');
        dumpContext(tester, 'subagent_live 父真实上下文（这一轮最后一次请求）');
        debugPrint('[OBS] 父最终回复（${reply.length} 字符）：\n$reply');
        debugPrint('[OBS] 父最终回复含本次结论标记='
            '${reply.contains(conclusionMarker)}');
        _dumpParentChildRecords(
          parentSession: parentSession,
          parentMessages: parentMessages,
          childSessions: childSessions,
          childMessagesById: childMessagesById,
        );

        final chatState = tester.state<ChatScreenState>(find.byType(ChatScreen));
        final snapshot = chatState.contextSnapshot;

        // ------------------------------------------------------------------
        // ⑦ 断言 1/4：父工具卡必须是已完成的 spawn_subagent，输入点名子模板并带
        // 本次结论标记，结果含子 Agent 原样返回的结论与子运行元数据。
        final cards = await _scanToolActivities(tester);
        final spawnCards = [
          for (final activity in cards)
            if (activity.toolName == 'spawn_subagent') activity,
        ];
        expect(spawnCards, isNotEmpty,
            reason: '父模型必须在真实运行中调用 spawn_subagent；聊天列表里没有任何 '
                'spawn_subagent 工具卡说明它没调用工具（不是环境跳过，是失败）');
        final doneSpawnCards = [
          for (final activity in spawnCards)
            if (activity.status == ToolCallStatus.done &&
                (((activity.input['task'] as String?) ?? '')
                    .contains(conclusionMarker)))
              activity,
        ];
        expect(doneSpawnCards, isNotEmpty,
            reason: '必须有一张已完成的 spawn_subagent 工具卡，且它的任务里带本次'
                '运行的结论标记；实际卡状态/结果=${[
          for (final a in spawnCards)
            '${a.status.name}:${a.result ?? a.resultPreview ?? ''}',
        ]}');
        final spawnCard = doneSpawnCards.first;
        final cardTask = (spawnCard.input['task'] as String?) ?? '';
        expect(spawnCard.input['agent_type'], _childTemplate,
            reason: '父模型必须点名不含 spawn_subagent 的子模板；省略参数或填父'
                '模板都算调用错误模板');
        expect(cardTask, contains(conclusionMarker),
            reason: '父模型写给子 Agent 的任务必须带上本次运行的独特结论标记');
        expect(spawnCard.result ?? '', contains(conclusionMarker),
            reason: '父工具卡结果必须含子 Agent 原样返回的独特结论');
        expect(spawnCard.childSessionId, isNotNull,
            reason: '工具卡必须带子运行元数据 child_session_id');
        expect(spawnCard.childAgentType, _childTemplate,
            reason: '工具卡必须带实际子模板名');
        expect(spawnCard.childModel, cfg.model,
            reason: '工具卡必须带子的实际模型名');
        expect(spawnCard.childMetering, isNotNull,
            reason: '工具卡必须带子计量元数据');

        // ------------------------------------------------------------------
        // ⑧ 断言 2/4：父会话消息里的工具调用记录含同样的子运行元数据，且结果含结论。
        final parentRecords = _toolCallRecords(parentMessages);
        final persistedRecords = [
          for (final record in parentRecords)
            if ((record['toolName'] ?? record['name']) == 'spawn_subagent' &&
                record['status'] == ToolCallStatus.done.name &&
                _recordTask(record).contains(conclusionMarker))
              record,
        ];
        expect(persistedRecords, isNotEmpty,
            reason: '父会话消息里必须有已完成的 spawn_subagent 调用记录，且任务里'
                '带本次运行的结论标记；实际记录=$parentRecords');
        final record = persistedRecords.first;
        debugPrint('[OBS] 父会话里落库的 spawn_subagent 记录（完整）：\n'
            '${const JsonEncoder.withIndent('  ').convert(record)}');
        expect(record['result'] ?? '', contains(conclusionMarker),
            reason: '父会话里的工具调用结果必须含子 Agent 原样返回的独特结论');
        final childSessionId = record['child_session_id'] as String?;
        expect(childSessionId, isNotNull,
            reason: '父会话的工具调用记录必须含子运行元数据 child_session_id');
        expect(record['child_agent_type'], _childTemplate,
            reason: '父会话记录必须写实际子模板名（调用错误模板时这里红）');
        expect(record['child_model'], cfg.model,
            reason: '父会话记录必须写子的实际模型名');
        final recordMetering = record['child_metering'];
        expect(recordMetering, isA<Map>(),
            reason: '父会话记录必须写子计量对象 child_metering');
        expect(recordMetering is Map && recordMetering.isNotEmpty, isTrue,
            reason: '子计量对象不能是空的；实际=$recordMetering');
        expect(spawnCard.childSessionId, childSessionId,
            reason: '工具卡与父会话记录必须指向同一个子会话');
        expect(spawnCard.childMetering, isNotNull,
            reason: '工具卡与父会话记录必须带同一批子运行元数据');

        // ------------------------------------------------------------------
        // ⑨ 断言 3/4：子会话存在且 parent_session_id 指向父会话；子中间消息只在
        // 子会话；父历史（数据库 + 真正发出的快照）不含子中间消息独特标记。
        final childId = childSessionId!;
        final matchedChildren = [
          for (final child in childSessions)
            if (child.id == childId) child,
        ];
        expect(matchedChildren, hasLength(1),
            reason: '子会话必须存在（按产品只读入口 listChildren 查父会话下的子记录）');
        final childSession = matchedChildren.first;
        expect(childSession.parentSessionId, parentSession.id,
            reason: '子会话的 parent_session_id 必须指向父会话');
        expect(childSession.agentType, _childTemplate,
            reason: '子会话必须用不含 spawn_subagent 的子模板创建');

        final childMessages = childMessagesById[childId] ?? const <Message>[];
        expect(childMessages, isNotEmpty,
            reason: '子会话必须有自己的消息历史（子 Agent 的独立历史）');
        final childAssistants = [
          for (final message in childMessages)
            if (message.role == 'assistant') message,
        ];
        expect(childAssistants, isNotEmpty,
            reason: '子会话必须有助手消息（至少是最终结论）');
        final childFinal = childAssistants.last;
        expect(childFinal.content, contains(conclusionMarker),
            reason: '子 Agent 的最终结论必须原样含本次运行的独特结论标记'
                '（结论缺失算失败）');
        final childToolNames = [
          for (final call in _toolCallRecords(childMessages))
            (call['toolName'] ?? call['name']).toString(),
        ];
        expect(childToolNames, isNot(contains('spawn_subagent')),
            reason: '子模板不含 spawn_subagent，子 Agent 不能嵌套创建下一层；'
                '实际子工具=$childToolNames');

        // 子中间消息的独特标记：子模型生成的工具调用 id / 工具结果 / 思考文本。
        // 子会话最后一条助手消息就是要回传的结论，子会话的用户消息就是父模型的
        // 工具输入 —— 这两类不算"子中间消息"，不拿来对比。
        //
        // 再排掉一种假阳性：sidecar 没给工具调用 id 时，父子的回退 id 可能都是
        // `tool_0_0`，而父历史里本来就该有它自己的那次调用 id。所以只保留"不属于
        // 父自己任何一次工具调用 id"的标记（子结果/思考文本不受影响，仍会对比）。
        final parentOwnToolCallIds = {
          for (final call in parentRecords) (call['id'] ?? '').toString(),
        }..remove('');
        final markers = [
          for (final marker in _childIntermediateMarkers(childMessages, childFinal))
            if (!parentOwnToolCallIds.contains(marker)) marker,
        ];
        debugPrint('[OBS] 子中间消息独特标记共 ${markers.length} 条：');
        for (final marker in markers) {
          debugPrint('[OBS]   标记：$marker');
        }
        expect(markers, isNotEmpty,
            reason: '子会话里必须留下可对比的中间痕迹（本次子任务明确要求先调用 '
                'get_current_time）：没有中间标记就无法证明父历史隔离，按失败处理'
                '而不是静默通过');

        final parentIds = {for (final m in parentMessages) m.id};
        final childIds = {for (final m in childMessages) m.id};
        expect(parentIds.intersection(childIds), isEmpty,
            reason: '父会话与子会话不能是同一批消息记录（子中间消息不得写进父会话）');

        final parentTexts = _messageTexts(parentMessages);
        for (final marker in markers) {
          expect(parentTexts.any((text) => text.contains(marker)), isFalse,
              reason: '父历史里出现了只属于子中间消息的独特标记（父历史不得含子'
                  '中间消息）：$marker');
        }

        expect(snapshot, isNotNull,
            reason: '父这一轮必须留下真实上下文快照（要用它证明真正发出去的父历史'
                '也不含子中间消息）');
        final snap = snapshot!;
        final snapshotTexts = <String>[];
        _collectStrings(snap.messages, snapshotTexts);
        for (final marker in markers) {
          expect(snapshotTexts.any((text) => text.contains(marker)), isFalse,
              reason: '父这一轮真正发给模型的历史里出现了子中间消息独特标记：$marker');
        }
        final snapshotToolNames = <String>[];
        try {
          for (final raw in (jsonDecode(snap.toolsJson) as List)) {
            final name = (raw as Map<String, dynamic>)['name'];
            if (name is String) snapshotToolNames.add(name);
          }
        } catch (e) {
          fail('父真实上下文的工具清单不是合法 JSON 数组：$e');
        }
        debugPrint('[OBS] 父真实请求的工具清单=$snapshotToolNames');
        expect(snapshotToolNames, contains('spawn_subagent'),
            reason: '父模板含 spawn_subagent，真实请求的工具清单里必须有它');

        // ------------------------------------------------------------------
        // ⑩ 断言 4/4：父最终回复正常落地到父会话历史（不是只挂在界面状态里）。
        expect(reply.trim(), isNotEmpty, reason: '父最终回复不能是空的');
        final parentAssistants = [
          for (final message in parentMessages)
            if (message.role == 'assistant') message,
        ];
        expect(parentAssistants, isNotEmpty,
            reason: '父会话必须有助手消息');
        expect(parentAssistants.last.content, reply,
            reason: '父最终回复必须正常落地到父会话的历史里（与界面读到的最终回复'
                '一致）');
        expect(parentMessages.first.role, 'user',
            reason: '父会话第一条消息必须是用户发出的任务');
        debugPrint('[OBS] 断言全部通过：父工具卡=${spawnCard.status.name} '
            '子会话=$childId 父消息数=${parentMessages.length} '
            '子消息数=${childMessages.length}');
      } finally {
        // 所有出口都截一张，路径固定为 test/live_visual/subagent_live.png。
        await captureLiveShot(tester, captureKey, 'subagent_live');
      }
    },
    timeout: const Timeout(Duration(seconds: 900)),
  );
}

/// 取一条工具调用记录里父模型写给子 Agent 的 `task`（不存在或非字符串时返回空串）。
String _recordTask(Map<String, dynamic> record) {
  final input = record['input'];
  if (input is Map) {
    final task = input['task'];
    if (task is String) return task;
  }
  return '';
}

/// 解析一次会话里所有 `toolCallsJson` 记录（父子的通用读取）。
List<Map<String, dynamic>> _toolCallRecords(List<Message> messages) {
  final records = <Map<String, dynamic>>[];
  for (final message in messages) {
    final raw = message.toolCallsJson;
    if (raw == null || raw.isEmpty) continue;
    try {
      for (final element in (jsonDecode(raw) as List)) {
        if (element is Map<String, dynamic>) records.add(element);
      }
    } catch (e) {
      debugPrint('[OBS] 解析 toolCallsJson 失败（message=${message.id}）：$e');
    }
  }
  return records;
}

/// 子会话里"只属于子上下文"的独特标记：子模型生成的工具调用 id、工具结果与思考
/// 文本。子会话最后一条助手消息（要回传的结论）与用户消息（父模型的工具输入）
/// 不参与对比；子模型自己把工具结果抄进结论时，那份文本回到父会话是允许的。
List<String> _childIntermediateMarkers(
    List<Message> childMessages, Message childFinal) {
  final markers = <String>[];
  final finalText = childFinal.content;
  for (final message in childMessages) {
    if (message.id == childFinal.id) continue;
    if (message.role == 'user') continue;
    final thinking = message.thinkingJson;
    if (thinking != null && thinking.isNotEmpty) {
      try {
        for (final block in (jsonDecode(thinking) as List)) {
          final text = (block as Map<String, dynamic>)['thinking'];
          if (text is String &&
              text.trim().isNotEmpty &&
              !finalText.contains(text)) {
            markers.add(text);
          }
        }
      } catch (e) {
        debugPrint('[OBS] 解析子思考失败（message=${message.id}）：$e');
      }
    }
    final toolCalls = message.toolCallsJson;
    if (toolCalls == null || toolCalls.isEmpty) continue;
    try {
      for (final element in (jsonDecode(toolCalls) as List)) {
        final call = element as Map<String, dynamic>;
        final id = (call['id'] ?? '').toString();
        // 子模型自己把调用 id 抄进最终结论时，这个串回到父会话是允许的。
        if (id.isNotEmpty && !finalText.contains(id)) markers.add(id);
        final result = (call['result'] ?? '').toString();
        if (result.isNotEmpty && !finalText.contains(result)) {
          markers.add(result);
        }
      }
    } catch (e) {
      debugPrint('[OBS] 解析子工具调用失败（message=${message.id}）：$e');
    }
  }
  return markers;
}

/// 把一条消息里所有可读文本摊平（content / 思考 / 工具输入与结果），供"父历史里
/// 没有子中间消息独特标记"的对比使用。用解码后的字符串而不是 JSON 原文比较，
/// 避免换行、引号被转义后既漏报又误判。
List<String> _messageTexts(List<Message> messages) {
  final texts = <String>[];
  for (final message in messages) {
    texts.add(message.content);
    for (final raw in [message.thinkingJson, message.toolCallsJson]) {
      if (raw == null || raw.isEmpty) continue;
      try {
        _collectStrings(jsonDecode(raw), texts);
      } catch (e) {
        debugPrint('[OBS] 解析消息 JSON 失败（message=${message.id}）：$e');
      }
    }
  }
  return texts;
}

void _collectStrings(Object? value, List<String> out) {
  if (value is String) {
    if (value.isNotEmpty) out.add(value);
  } else if (value is List) {
    for (final element in value) {
      _collectStrings(element, out);
    }
  } else if (value is Map) {
    for (final element in value.values) {
      _collectStrings(element, out);
    }
  }
}

/// 断言前把父子数据库记录逐条打出来（父会话消息、工具调用记录、子会话
/// `parent_session_id` 与子会话自己的消息/工具输出），失败时可归因。
void _dumpParentChildRecords({
  required Session parentSession,
  required List<Message> parentMessages,
  required List<Session> childSessions,
  required Map<String, List<Message>> childMessagesById,
}) {
  debugPrint('════════ [OBS] 父子数据库记录 ════════');
  debugPrint('[OBS] 父会话 id=${parentSession.id} agentType=${parentSession.agentType} '
      'parentSessionId=${parentSession.parentSessionId}');
  for (final message in parentMessages) {
    debugPrint('[OBS] 父消息 seq=${message.seq} role=${message.role} '
        'id=${message.id} content=${message.content}');
    if (message.toolCallsJson != null && message.toolCallsJson!.isNotEmpty) {
      debugPrint('[OBS] 父消息 toolCallsJson=\n${message.toolCallsJson}');
    }
  }
  debugPrint('[OBS] 父会话下的子会话条数=${childSessions.length}');
  for (final child in childSessions) {
    debugPrint('[OBS] 子会话 id=${child.id} '
        'parent_session_id=${child.parentSessionId} agent_type=${child.agentType} '
        'title=${child.title}');
    final messages = childMessagesById[child.id] ?? const <Message>[];
    for (final message in messages) {
      debugPrint('[OBS] 子消息 seq=${message.seq} role=${message.role} '
          'id=${message.id} content=${message.content}');
      if (message.toolCallsJson != null && message.toolCallsJson!.isNotEmpty) {
        debugPrint('[OBS] 子消息 toolCallsJson=\n${message.toolCallsJson}');
      }
    }
  }
}

/// 真实 provider 解析（沿用 compact_quality_live_test.dart 的既有形状）：
/// 环境变量优先，其次 `ConfigService.load()`。返回 null 表示配置不完整 → 跳过。
///
/// 比既有解析多要一项 `max_context_tokens`：模板没有合法窗口时
/// `AgentFactory.resolveCandidate` 会拒绝创建实例，AppShell 也会弹首启补问框，
/// 这两种情况都不该拿"模型没调用工具"去红。窗口取自真实配置，不新造数字。
({String providerName, String apiKey, String baseUrl, String model,
    int maxContextTokens})? _resolveLiveConfig() {
  final loaded = ConfigService.load();
  int? realWindow;
  if (loaded.status == ConfigStatus.ok && loaded.config != null) {
    final types = loaded.config!.agentTypes;
    final base = types['general'] ?? (types.isNotEmpty ? types.values.first : null);
    final window = base?.maxContextTokens;
    if (window != null && window > 0) realWindow = window;
  }

  final overrideKey = Platform.environment['ALIASAGENT_API_KEY']?.trim();
  final overrideBase = Platform.environment['ALIASAGENT_BASE_URL']?.trim();
  final overrideModel = Platform.environment['ALIASAGENT_MODEL']?.trim();
  if (overrideKey != null && overrideKey.isNotEmpty) {
    // 严格判定：api_key + base_url + model 缺一不可（不回落到缺省端点）。
    if (overrideBase == null ||
        overrideBase.isEmpty ||
        overrideModel == null ||
        overrideModel.isEmpty) {
      return null;
    }
    if (realWindow == null) return null;
    return (
      providerName: 'live',
      apiKey: overrideKey,
      baseUrl: overrideBase,
      model: overrideModel,
      maxContextTokens: realWindow,
    );
  }

  if (loaded.status != ConfigStatus.ok || loaded.config == null) return null;
  final appConfig = loaded.config!;
  final base = appConfig.agentTypes['general'] ??
      (appConfig.agentTypes.isNotEmpty
          ? appConfig.agentTypes.values.first
          : null);
  if (base == null) return null;
  final providerCfg = appConfig.providers[base.provider];
  if (providerCfg == null || providerCfg.apiKey.trim().isEmpty) return null;
  if (providerCfg.baseUrl.trim().isEmpty || base.model.trim().isEmpty) {
    return null;
  }
  final window = base.maxContextTokens;
  if (window == null || window <= 0) return null;
  return (
    providerName: base.provider,
    apiKey: providerCfg.apiKey,
    baseUrl: providerCfg.baseUrl,
    model: base.model,
    maxContextTokens: window,
  );
}

/// 扫描聊天列表里的工具卡片（按 id 去重、保留最后一次活动）。
///
/// `integration_test/live_observability.dart` 里同形态的扫描是私有的（`_scanToolCards`，
/// 只用于打印）；断言需要活动对象本身，所以按同一形态复制：同样的 12 次向下拖动、
/// 每次 400 像素 / 200 毫秒，最后用 `jumpTo` 恢复到底部（避免遗留手势动画影响后续
/// 用例）。这几个数字与那边完全一致，没有新增口径。
Future<List<ToolCallActivity>> _scanToolActivities(WidgetTester tester) async {
  final chatList = find.descendant(
    of: find.byType(ChatArea),
    matching: find.byType(ListView),
  );
  final seen = <String, ToolCallActivity>{};
  final order = <String>[];
  var drags = 0;
  while (true) {
    for (final card
        in tester.widgetList<ToolCallCard>(find.byType(ToolCallCard))) {
      final activity = card.activity;
      // 去重键：正常走活动 id；sidecar 没给 id 时退化成"工具名 + 完整输入"，
      // 这样重复构建同一张卡不会重复计数，也不会因为空 id 把卡丢掉。
      final key = activity.id.isNotEmpty
          ? activity.id
          : '${activity.toolName}:${jsonEncode(activity.input)}';
      if (!seen.containsKey(key)) order.add(key);
      seen[key] = activity;
    }
    if (chatList.evaluate().isEmpty || drags >= 12) break;
    try {
      await tester.drag(chatList, const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 200));
    } catch (_) {
      break; // 手势模拟不可用：按已扫到的卡断言
    }
    drags++;
  }
  if (chatList.evaluate().isNotEmpty) {
    try {
      final controller = tester.widget<ListView>(chatList).controller;
      if (controller != null && controller.hasClients) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pump();
      }
    } catch (_) {
      // 控制器已脱离（收尾中）——恢复底部只是尽力而为
    }
  }
  return [
    for (final id in order) seen[id]!,
  ];
}

/// 等整轮结束：出现最终回复，或流式结束后没有最终回复（静默结束），或超时。
///
/// **与 compact_quality_live_test.dart 的同名函数逐行一致**（那边已经过多轮真机
/// 验证）；调用方传 `timeoutSec: 300`，即既有 live 的等待口径，不新增超时数字。
Future<void> pumpUntilReplyOrTurnDone(WidgetTester tester,
    {int timeoutSec = 150}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  var sawStreaming = false;
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    final stillStreaming = areas.isNotEmpty && areas.last.isStreaming;
    if (stillStreaming) sawStreaming = true;
    if (readFinalAssistantReply(tester) != null) return; // 已存下最终回复
    if (sawStreaming && !stillStreaming) {
      // 流式已停：给挂起的 _storeError 落库留一点时间，再确认一次。
      await tester.pump(const Duration(milliseconds: 500));
      if (readFinalAssistantReply(tester) != null) return;
      return;
    }
    // 还没见过流式：仍在发送前的写库阶段，继续等。
  }
  throw TimeoutException('Conversation still streaming after ${timeoutSec}s');
}
