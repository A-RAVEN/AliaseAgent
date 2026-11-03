// 启动恢复只遍历顶层会话（add-spawn-subagent-tool 任务 2.3）。
//
// 用**真实 SQLite** 预置父子会话，再真实 pumpWidget 启动 ChatScreen：
//   - 侧栏只出现父会话标题，子运行标题不出现；
//   - AgentRegistry 只有父会话句柄，且父实例按自己存储的模板恢复；
//   - 子会话没有被自动建成运行实例，也没有发起任何模型请求。
// 恢复成旧版"列出全部 sessions"时，子标题与子句柄都会出现，这些断言必须失败；
// 这里不使用直传列表的纯 SessionSidebar 用例，也不只调工厂。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import 'helpers/fake_sidecar.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  late Directory tempDir;
  late FakeSidecar sidecar;
  late AgentRegistry agents;
  late String parentId;
  late String childId;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('subagent_restore_');
    await DatabaseService.openAt(tempDir.path);
    ToolCatalog.instance.seed({
      for (final n in ['read_file', 'list_dir', 'write_file', 'run_command'])
        n: def(n),
    });
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
      tools: ['read_file'],
      maxContextTokens: 64000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar();
    agents = AgentRegistry();

    // 真实 SQLite：父会话用自己的模板（reviewer），子运行记录用 general。
    final sessionRepo = SessionRepository();
    final parent =
        await sessionRepo.create(title: '父会话标题', agentType: 'reviewer');
    final child = await sessionRepo.create(
        title: '子运行标题', agentType: 'general', parentSessionId: parent.id);
    parentId = parent.id;
    childId = child.id;
    await MessageRepository()
        .insert(sessionId: parentId, role: 'user', content: '父会话的历史消息');
  });

  tearDown(() async {
    await DatabaseService.close();
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
    agents.clear();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('真实 SQLite 启动：侧栏与 AgentRegistry 都只处理父会话', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: SessionRepository(),
          msgRepo: MessageRepository(),
          sidecar: sidecar,
          summaryProvider: FakeSummaryProvider(),
          summaryNodeRepo: SummaryNodeRepository(),
          backgroundFoldEnabled: false,
          agentRegistry: agents,
        ),
      ),
    ));

    // 真实的 sqflite I/O 只能在真实异步区完成：每次 runAsync 放行一轮事件循环，
    // 再 pump 一次让 initState 里那些 await 的后续继续跑。
    var loaded = false;
    for (var i = 0; i < 200; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      if (agents.contains(parentId) &&
          find.textContaining('父会话的历史消息').evaluate().isNotEmpty) {
        loaded = true;
        break;
      }
    }
    // 再多放行几轮：如果实现把子记录也列出来，这段窗口足够让它渲染与建实例。
    for (var i = 0; i < 20; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }

    final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
    final parentAgent = agents.lookup(parentId);
    // ignore: avoid_print
    print('[OBS] loaded=$loaded currentSessionId=${state.currentSessionId} '
        'agentHandles=${agents.handles} '
        '父实例模板=${parentAgent?.config.templateName} '
        '父实例模型=${parentAgent?.config.model} '
        'sidecar 请求句柄=${sidecar.sendHandles} '
        '侧栏父标题=${find.text('父会话标题').evaluate().length} '
        '侧栏子标题=${find.text('子运行标题').evaluate().length}');

    expect(find.text('子运行标题'), findsNothing,
        reason: '子运行记录不得出现在侧栏');
    expect(agents.contains(childId), isFalse,
        reason: '子记录不得在启动时被自动建成运行 Agent');
    expect(loaded, isTrue, reason: '启动恢复必须真的把父会话与历史读出来');
    expect(state.currentSessionId, parentId, reason: '默认选中父会话');
    expect(find.text('父会话标题'), findsOneWidget,
        reason: '侧栏必须显示父会话');
    expect(find.textContaining('父会话的历史消息'), findsWidgets,
        reason: '父会话的历史必须按自己的会话恢复');
    expect(agents.contains(parentId), isTrue);
    expect(parentAgent!.config.templateName, 'reviewer',
        reason: '父会话仍按自己存储的模板恢复');
    expect(parentAgent.config.model, 'reviewer-model');
    expect(sidecar.sendHandles, isEmpty,
        reason: '启动恢复不得自行发起模型请求');
    expect(tester.takeException(), isNull);
  });
}
