// 群聊 integration 测试的统一在线夹具（change `agent-group-chat` §4~§7）。
//
// 把「真 SQLite + 假 sidecar + 假摘要 provider + 真 AgentFactory + 真 GroupService」
// 装成一套可直接发言的组，测试只关心断言。
import 'dart:convert';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/group_member.dart';
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

import 'group_test_support.dart';

class GroupHarness {
  GroupHarness._({
    required this.support,
    required this.config,
    required this.templates,
    required this.agents,
    required this.factory,
    required this.groups,
    required this.members,
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

  /// 摘要节点仓储（真库）。
  SummaryNodeRepository get summaryNodeRepo => support.summaryNodeRepo;

  /// 建一套可发言的组环境：临时库 + 两个模板（general / narrow）+ 两个成员。
  static Future<GroupHarness> create({
    String groupTitle = '测试组',
    String? workspace,
    int window = 200000,
    List<String> tools = const ['read_file', 'list_dir', 'run_command', 'write_file'],
    bool createGroup = true,
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
    );
    final harness = GroupHarness._(
      support: support,
      config: config,
      templates: templates,
      agents: agents,
      factory: factory,
      groups: groups,
      members: memberRepo,
    );
    if (createGroup) {
      harness.group = await groups.createGroup(
        title: groupTitle,
        workspace: workspace ?? support.workspaceDir,
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
    await agents.disposeAll();
    await support.dispose();
  }
}
