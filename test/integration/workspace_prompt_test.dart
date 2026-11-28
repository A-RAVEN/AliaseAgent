// 系统提示词注入当前工作区（change `custom-workspace` 任务 6.1 / design D5 / D12）。
//
// 断言的输入通道是**实际发出的请求**：`FakeSidecar.sendRequests` 按句柄留下每一次
// `sendMessage` 的 systemPrompt / messagesJson / toolsJson。绝不读 Agent 的内部字段，
// 也不拿模型输出当判据。
//
// 五条：
//   ① 单聊：一轮请求含标题常量 + 工作区路径，且模板提示词仍在（追加不替换）；
//   ② 组成员：该成员这一轮的请求含组工作区 + 身份锚 / 组角色说明 / 反应提示；
//   ③ 切换：A 一轮 → `Agent.setWorkspace(B)` → B 一轮；第一轮含 A 不含 B，第二轮
//      含 B 不含 A；同一轮的工具轮 + 最终轮看到同一个值；
//   ④ `get_workspace` 失败 / 空串 ⇒ 请求里是「不可用」段（不伪造目录），该轮仍完成；
//   ⑤ 摘要请求的系统文本不含该段（真实 `ModelSummaryProvider` 的请求）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/group_prompts.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/workspace.dart';

import 'group_harness.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 某个句柄最近一轮的全部请求 systemPrompt（按发生顺序）。
List<String> _requestsFor(GroupHarness harness, String handle) => [
      for (final request in harness.support.sidecar.sendRequests)
        if (request.handle == handle) request.systemPrompt,
    ];

void main() {
  group('系统提示词注入工作区', () {
    late GroupHarness harness;
    late Directory workspaceA;
    late Directory workspaceB;

    setUp(() async {
      harness = await GroupHarness.create(createGroup: false);
      workspaceA = Directory(p.join(harness.support.root.path, 'prompt-ws-a'))
        ..createSync(recursive: true);
      workspaceB = Directory(p.join(harness.support.root.path, 'prompt-ws-b'))
        ..createSync(recursive: true);
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('① 单聊整轮 systemPrompt 含标题 + 工作区路径，模板提示词仍在', () async {
      final session = await harness.support.sessionRepo.create(
        title: '提示词单聊',
        workspace: workspaceA.path,
      );
      final agent = await harness.factory.ensure(session);
      harness.queueSimpleReply('收到了');
      final result = await agent.send('你好');
      final prompts = _requestsFor(harness, session.id);
      _obs('单聊请求数', prompts.length);
      _obs('单聊 systemPrompt 里工作区段上下文',
          prompts.isEmpty ? '(无请求)' : _sectionAround(prompts.last, kWorkspacePromptHeading));
      expect(result.isCompleted, isTrue, reason: '该轮必须正常完成：${result.error}');
      expect(prompts, isNotEmpty);
      for (final prompt in prompts) {
        expect(prompt, contains(kWorkspacePromptHeading));
        expect(prompt, contains(workspaceA.path),
            reason: '系统提示词必须含该轮的实际工作区路径');
        // 追加不替换：模板提示词原文仍在。
        expect(prompt, contains('你是测试模板。'));
      }
    });

    test('② 组成员这一轮继承组工作区，且身份锚 / 组角色说明 / 反应提示仍在', () async {
      final group = await harness.groups.createGroup(
        title: '提示词组',
        workspace: workspaceA.path,
        reactionsEnabled: true,
      );
      final member = await harness.groups.addMember(
          groupId: group.id, name: '甲', templateName: 'general');
      // 开启态 + speaker + 文本 ⇒ 该成员跑一个**必应反应轮**（含反应纪律）。
      harness.queueReact(pass: false, message: '甲在组里的回复');
      final outcome = await harness.groups.send(
        groupId: group.id,
        memberId: member.id,
        text: '请甲说说',
      );
      _obs('群发送回包', outcome.toJson());
      final chain = await harness.waitForChain(group.id);
      _obs('链状态', chain.status);
      expect(chain.status, 'completed', reason: '失败真因=${chain.error}');

      final prompts = _requestsFor(harness, member.handle);
      _obs('成员请求数', prompts.length);
      expect(prompts, isNotEmpty);
      for (final prompt in prompts) {
        expect(prompt, contains(kWorkspacePromptHeading));
        expect(prompt, contains(workspaceA.path),
            reason: '成员必须继承组的工作区（不是主目录、不是空串）');
        // 追加不替换：成员身份锚 + 组角色说明 + 当轮反应纪律都在。
        expect(prompt, contains(kGroupMemberIdentityPrompt('甲')));
        expect(prompt, contains(kGroupMemberRolePrompt));
        expect(prompt, contains(kGroupMustRespondPrompt),
            reason: '开启态 speaker 是必应反应轮：反应纪律必须与工作区段并存');
      }
    });

    test('③ 切换在下一轮生效；同一轮的工具轮与最终轮用同一个值', () async {
      final session = await harness.support.sessionRepo.create(
        title: '切换单聊',
        workspace: workspaceA.path,
      );
      final agent = await harness.factory.ensure(session);

      harness.queueSimpleReply('第一轮回复');
      await agent.send('第一轮');
      final firstRound = _requestsFor(harness, session.id);
      _obs('第一轮请求数', firstRound.length);

      // 切到 B（Agent.setWorkspace 是显式切换入口；RPC 之后复用同一条）。
      await agent.setWorkspace(workspaceB.path);
      final readBack = harness.support.sidecar.getWorkspace(agent.handle);
      _obs('切换后 getWorkspace', readBack);

      // 第二轮：先一个工具轮、再最终轮（同一轮内两个模型请求）。
      harness.queueToolTurn(
        toolName: 'read_file',
        id: 'ws-tool-1',
        input: {'path': 'README.md'},
      );
      harness.queueSimpleReply('第二轮回复');
      await agent.send('第二轮');
      final secondRound = _requestsFor(harness, session.id)
          .sublist(firstRound.length);
      _obs('第二轮请求数', secondRound.length);

      expect(firstRound.length, 1);
      expect(secondRound.length, 2, reason: '第二轮必须真的有两个模型请求（工具轮 + 最终轮）');
      expect(firstRound.single, contains(workspaceA.path));
      expect(firstRound.single, isNot(contains(workspaceB.path)),
          reason: '切换前的轮次不得提前看到新路径');
      for (final prompt in secondRound) {
        expect(prompt, contains(workspaceB.path),
            reason: '切换后**下一轮**的每个请求都要含新工作区（同一轮内值一致）');
        expect(prompt, isNot(contains(workspaceA.path)),
            reason: '切换后不得残留旧工作区');
      }
    });

    test('④ get_workspace 失败 / 空串 ⇒ 请求含「不可用」段且该轮仍完成', () async {
      final session = await harness.support.sessionRepo.create(
        title: '读不到工作区',
        workspace: workspaceA.path,
      );
      final agent = await harness.factory.ensure(session);

      // (a) ok:false。
      harness.support.sidecar.workspaceFailureCode = 'unknown_context';
      harness.queueSimpleReply('失败分支也能回复');
      final failedRead = await agent.send('读不到工作区时');
      final failurePrompts = _requestsFor(harness, session.id);
      _obs('ok:false 的请求段',
          _sectionAround(failurePrompts.last, kWorkspacePromptHeading));
      expect(failedRead.isCompleted, isTrue,
          reason: '读不到工作区不许丢弃整轮（失败真因=${failedRead.error}）');
      expect(failurePrompts.last, contains('当前没有可用工作区'));
      expect(failurePrompts.last, contains('unknown_context'),
          reason: '不可用段必须带原因，不静默省略');
      expect(failurePrompts.last, isNot(contains(workspaceA.path)),
          reason: '读不到时不许把某个目录伪装成实际工作区');
      harness.support.sidecar.workspaceFailureCode = null;

      // (b) ok + 空串。
      harness.support.sidecar.stubWorkspace(agent.handle, '');
      harness.queueSimpleReply('空串也能回复');
      final emptyRead = await agent.send('空工作区时');
      final emptyPrompts = _requestsFor(harness, session.id);
      _obs('空串的请求段',
          _sectionAround(emptyPrompts.last, kWorkspacePromptHeading));
      expect(emptyRead.isCompleted, isTrue);
      expect(emptyPrompts.last, contains('当前没有可用工作区'));
      expect(emptyPrompts.last, isNot(contains(workspaceA.path)),
          reason: '空工作区不得显示成旧路径');
      // 两轮各产生一条不可用段（不是只测一种形态）。
      expect(
        failurePrompts.where((prompt) => prompt.contains('当前没有可用工作区')).length,
        1,
      );
      expect(
        emptyPrompts.where((prompt) => prompt.contains('当前没有可用工作区')).length,
        2,
      );
    });

    test('⑤ 摘要请求的系统文本不含工作区段', () async {
      final template = harness.templates.lookup('general');
      expect(template, isNotNull);
      final provider = ModelSummaryProvider(
        sidecar: harness.support.sidecar,
        resolver: ProviderResolver(harness.config),
      );
      // 摘要调用走 sidecar：排一次 chunk + done。
      harness.support.sidecar.queueChunk('摘要正文');
      harness.support.sidecar.queueDone(inputTokens: 3, outputTokens: 2);
      final folded = [
        Message(
          id: 'm1',
          seq: 1,
          sessionId: 'summary-probe',
          role: 'user',
          content: '要压缩的一段历史',
          createdAt: 1,
        ),
      ];
      final summary = await provider.summarize(
        folded: folded,
        config: template!,
        sessionId: 'summary-probe',
      );
      final system = harness.support.sidecar.lastSystemPrompt ?? '';
      _obs('摘要系统文本', system);
      _obs('摘要正文', summary.text);
      expect(system, contains(kSummarySystemPrompt),
          reason: '前置：这次请求确实是摘要请求（系统文本是摘要器的）');
      expect(system, isNot(contains(kWorkspacePromptHeading)),
          reason: '摘要不是 Agent 轮：系统文本不得含工作区段');
      expect(system, isNot(contains(workspaceA.path)));
    });
  });
}

/// 取 [heading] 在 [text] 里那一段的上下文（观察用；找不到返回 "(没有该段)"）。
String _sectionAround(String text, String heading) {
  final at = text.indexOf(heading);
  if (at < 0) return '(没有该段)';
  final end = at + 320 > text.length ? text.length : at + 320;
  return text.substring(at, end);
}
