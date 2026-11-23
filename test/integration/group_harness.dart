// 群聊 integration 测试的统一在线夹具（change `agent-group-chat` §4~§7）。
//
// 把「真 SQLite + 假 sidecar + 假摘要 provider + 真 AgentFactory + 真 GroupService」
// 装成一套可直接发言的组，测试只关心断言。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/group_member.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/group_member_repository.dart';
import 'package:alias_agent/services/group_service.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import 'helpers/group_core_harness.dart' show kTestChainTimeout;
import 'group_test_support.dart';

export 'helpers/group_core_harness.dart' show kTestChainTimeout;

class GroupHarness {
  GroupHarness._({
    required this.support,
    required this.config,
    required this.templates,
    required this.agents,
    required this.factory,
    required this.groups,
    required this.members,
    required this.userMessageEvents,
    required this.titleEvents,
    required this.chainEvents,
    required this.turnFailedEvents,
  });

  final GroupTestSupport support;
  final AppConfig config;
  final AgentTypeRegistry templates;
  final AgentRegistry agents;
  final AgentFactory factory;
  final GroupService groups;
  final GroupMemberRepository members;

  late final Session group;

  bool get backgroundFold => false;

  /// 组服务自己写入用户消息的回调记录（change `group-reactive-mode` 任务 3.4）：
  /// 只带 groupId，**不带 memberId**（这条消息没有成员作者）。
  final List<({String groupId, Message message})> userMessageEvents;

  /// 组服务自己写标题的回调记录。
  final List<({String groupId, String title})> titleEvents;

  /// 链结束事件（`group.chain.completed` 的回调记录；change
  /// `group-reactive-mode` R.2：唯一新增的事件类型）。
  final List<GroupChainSnapshot> chainEvents;

  /// `turn.failed` 的回调记录（只按**真实失败**的步骤发）。
  final List<({String groupId, GroupSendStep step})> turnFailedEvents;

  /// 摘要节点仓储（真库）。
  SummaryNodeRepository get summaryNodeRepo => support.summaryNodeRepo;

  /// 建一套可发言的组环境：临时库 + 两个模板（general / narrow）+ 两个成员。
  ///
  /// **夹具口径，不是产品默认**（change `group-reactive-mode` 任务 0.3 / design D12
  /// 的 Risks）：产品新建组默认自发反应**开启**，但既有群聊用例依赖「点名后只有一个人
  /// 跑」的旧语义，所以夹具 [reactionsEnabled] **缺省 `false`**（安静态）。要验自发
  /// 反应的用例显式传 `true`。
  static Future<GroupHarness> create({
    String groupTitle = '测试组',
    String? workspace,
    int window = 200000,
    List<String> tools = const ['read_file', 'list_dir', 'run_command', 'write_file'],
    bool createGroup = true,
    bool reactionsEnabled = false,
    int? maxRounds,
  }) async {
    final support = await GroupTestSupport.create(prefix: 'group_harness_');
    // 工具目录是唯一来源：模板里写的工具必须先播种进目录，否则创建实例时会按
    // 「未知工具」显式失败（那是产品既有判据）。
    ToolCatalog.instance.seed({
      for (final name in tools) name: {'name': name},
    });
    final config = support.minimalConfig(
      window: window,
      tools: tools,
      systemPrompt: '你是测试模板。',
    );
    // 第二个模板（窗口 200k），用来验"每成员各用自己的窗口"。
    final templates = AgentTypeRegistry();
    for (final template in config.agentTypes.values) {
      templates.register(template);
    }
    templates.register(AgentTypeConfig(
      name: 'narrow',
      provider: 'test-provider',
      model: 'test-model',
      systemPrompt: '你是窄窗口模板。',
      tools: tools,
      maxContextTokens: 200000,
    ));
    final agents = AgentRegistry();
    final factory = AgentFactory(
      templates: templates,
      providerResolver: () => ProviderResolver(config),
      config: config,
      sidecar: support.sidecar,
      sessionRepo: support.sessionRepo,
      messageRepo: support.messageRepo,
      summaryNodeRepo: support.summaryNodeRepo,
      registry: agents,
      summaryProvider: support.summary,
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => true,
    );
    final memberRepo = GroupMemberRepository();
    // 事件记录容器：GroupService 的回调带 groupId（不带 memberId），这里直接收集。
    final userMessageEvents = <({String groupId, Message message})>[];
    final titleEvents = <({String groupId, String title})>[];
    final chainEvents = <GroupChainSnapshot>[];
    final turnFailedEvents = <({String groupId, GroupSendStep step})>[];
    late final GroupService groups;
    groups = GroupService(
      sidecar: support.sidecar,
      sessionRepo: support.sessionRepo,
      memberRepo: memberRepo,
      messageRepo: support.messageRepo,
      summaryNodeRepo: support.summaryNodeRepo,
      agents: agents,
      factory: factory,
      templates: templates,
      callbacksForMember: (member) => const AgentCallbacks(),
      knownTools: () => ToolCatalog.instance.nameSet,
      onUserMessage: (groupId, message) =>
          userMessageEvents.add((groupId: groupId, message: message)),
      onTitleChanged: (groupId, title) =>
          titleEvents.add((groupId: groupId, title: title)),
      onChainCompleted: (chain) => chainEvents.add(chain),
      onTurnFailed: (groupId, step) =>
          turnFailedEvents.add((groupId: groupId, step: step)),
    );
    final harness = GroupHarness._(
      support: support,
      config: config,
      templates: templates,
      agents: agents,
      factory: factory,
      groups: groups,
      members: memberRepo,
      userMessageEvents: userMessageEvents,
      titleEvents: titleEvents,
      chainEvents: chainEvents,
      turnFailedEvents: turnFailedEvents,
    );
    if (createGroup) {
      harness.group = await groups.createGroup(
        title: groupTitle,
        workspace: workspace ?? support.workspaceDir,
        reactionsEnabled: reactionsEnabled,
        maxRounds: maxRounds,
      );
    }
    return harness;
  }

  /// 让工具目录知道测试模板里的工具（覆盖层校验读它）。
  static void seedToolCatalog(List<String> tools) {
    ToolCatalog.instance.seed({
      for (final name in tools) name: {'name': name},
    });
  }

  Future<GroupMember> addMember(String name, {String template = 'general'}) =>
      groups.addMember(groupId: group.id, name: name, templateName: template);

  /// 等该组当前链进入终态；返回终态快照（change `group-reactive-mode` R.7）。
  ///
  /// 异步发送后测试**必须**先等终态再断言 / 清理（否则断言会查到半条链、清理会
  /// 在链未结束时销毁侧车）。上界见 [kTestChainTimeout]。
  Future<GroupChainSnapshot> waitForChain(
    [String? groupId, Duration limit = kTestChainTimeout]) async {
    final id = groupId ?? group.id;
    try {
      await groups.waitForChain(id).timeout(limit);
    } on TimeoutException {
      final partial = groups.chainOf(id);
      throw TimeoutException(
          '等待组 "$id" 的反应链进入终态超时（$limit）：'
          '当前 status=${partial.status} rounds=${partial.rounds} '
          'steps=${partial.steps.map((step) => '${step.source}/${step.status}').toList()}',
          limit);
    }
    return groups.chainOf(id);
  }

  /// 当前 / 最近一条链的只读快照（`idle` = 本进程内还没跑过链）。
  GroupChainSnapshot chainOf([String? groupId]) =>
      groups.chainOf(groupId ?? group.id);

  /// 一次**工具轮**的模型回复：可选 thinking + 一个工具调用 + 结束（这台请求的文本为空）。
  void queueToolTurn({
    required String toolName,
    required String id,
    Map<String, dynamic> input = const {},
    String? thinking,
    String stubResult = '{"ok":true,"content":"fake content","total_lines":1,"start_line":1,"end_line":1}',
  }) {
    if (thinking != null) {
      support.sidecar.queueThinking(
          '{"type":"thinking","index":0,"thinking":"$thinking","signature":"sig-$id"}');
    }
    support.sidecar.queueToolCall(
        '{"type":"tool_use","id":"$id","name":"$toolName","input":${_json(input)}}');
    support.sidecar.queueDone(inputTokens: 8, outputTokens: 4);
    // 工具执行走假 sidecar 的桩：按工具名登记结果。
    switch (toolName) {
      case 'read_file':
        support.sidecar.stubReadFile(stubResult);
      case 'write_file':
        support.sidecar.stubWriteFile(stubResult);
      case 'edit_file':
        support.sidecar.stubEditFile(stubResult);
      case 'list_dir':
        support.sidecar.stubListDir(stubResult);
      case 'run_command':
        support.sidecar.stubRunCommand(stubResult);
    }
  }

  /// 一次**最终回复**的模型回复（可带 thinking）。
  void queueFinal(
    String text, {
    String? thinking,
    int inputTokens = 10,
    int outputTokens = 5,
  }) {
    if (thinking != null) {
      support.sidecar.queueThinking(
          '{"type":"thinking","index":0,"thinking":"$thinking","signature":"sig-final"}');
    }
    support.sidecar.queueChunk(text);
    support.sidecar.queueDone(
        inputTokens: inputTokens, outputTokens: outputTokens);
  }

  /// 一轮最简单的回复（没有工具轮）。
  void queueSimpleReply(String text, {String? thinking}) =>
      queueFinal(text, thinking: thinking);

  /// 一轮**结构化**反应决定（R.10）：调用 `group_react` 后结束该请求。
  ///
  /// [pass] 对应 `group_react.pass`；[message] 只在 `pass=false` 时成为公开内容。
  void queueReact({
    required bool pass,
    String message = '',
    String? thinking,
    int inputTokens = 10,
    int outputTokens = 5,
  }) {
    if (thinking != null) {
      support.sidecar.queueThinking(
          '{"type":"thinking","index":0,"thinking":"$thinking","signature":"sig-react"}');
    }
    support.sidecar.queueGroupReact(pass: pass, message: message);
    support.sidecar.queueDone(
        inputTokens: inputTokens, outputTokens: outputTokens);
  }

  /// 结构化沉默（`group_react {pass:true}`）。
  void queuePass({String? thinking}) => queueReact(pass: true, thinking: thinking);
  static String _json(Object? value) => jsonEncode(value ?? const <String, dynamic>{});

  /// 直接往组会话里种历史（走真实仓储，seq 由数据库分配）。
  ///
  /// [authorOf] 决定每条消息的作者：null = 用户消息；成员 id = 该成员的公开回复。
  Future<void> seedHistory({
    required int count,
    int chars = 120,
    String? Function(int index)? authorOf,
  }) async {
    for (var i = 0; i < count; i++) {
      final author = authorOf?.call(i);
      await support.messageRepo.insert(
        sessionId: group.id,
        role: author == null ? 'user' : 'assistant',
        content: '第 $i 条历史 ${'A' * chars}',
        author: author,
        visibility: 'public',
      );
    }
  }

  /// 种一条成员的**私有**证据行（带唯一标记），用于隐私红靶。
  Future<void> seedPrivateRow({
    required String memberId,
    required String marker,
  }) async {
    await support.messageRepo.insert(
      sessionId: group.id,
      role: 'assistant',
      content: '',
      thinkingJson:
          '[{"type":"thinking","thinking":"$marker 的私有思考","signature":"sig"}]',
      toolCallsJson:
          '[{"id":"tool-$marker","type":"tool_use","name":"read_file",'
              '"toolName":"read_file","input":{"path":"lib/$marker.dart"},'
              '"result":"$marker 的私有结果"}]',
      author: memberId,
      visibility: 'private-to-author',
    );
  }

  Future<void> dispose() async {
    // R.7 的硬约束：**异步链未结束不得销毁侧车 / 删临时目录**。先等所有在跑的链
    // 进入终态（上界 `kTestChainTimeout`，让"忘了等终态"变成红而不是竞态）。
    for (final groupId in groups.runningGroupIds) {
      await groups.waitForChain(groupId).timeout(kTestChainTimeout);
    }
    await agents.disposeAll();
    // 隔离断言（R.7）：链跑完前后的真实用户目录 db/config/core.lock 指纹必须不变。
    // ignore: avoid_print
    print(support.describeIsolation());
    expect(support.realUserDirDifferences(), isEmpty,
        reason: '测试绝不能写用户真实 ~/.aliasagent 的 db/config/core.lock');
    await support.dispose();
  }
}
