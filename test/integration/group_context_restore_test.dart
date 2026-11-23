// 群上下文跨核心重启存活（change `group-chat-layout` R.14；
// spec「群上下文跨核心重启存活」/ design D13）。
//
// 红靶：核心重启后对**存量群**发消息。修复前 `ensureMemberAgent` 直接
// `sidecar.getWorkspace(group.id)`，sidecar 内存上下文随重启丢失 ⇒ `unknown_context`
// ⇒ 链 `failed`、steps=0/一步都跑不了。修复后成员轮先按需重注册群上下文。
//
// 另外三条：
//   ② 同进程幂等（上下文仍在，`created:false`）不覆盖已设的自定义工作区；
//   ③ 自定义工作区不持久化：重启后回落缺省 `ConfigService.homeDir`（已知限制）；
//   ④ `ensureContext` 的 `StateError` 被包成可归因 `GroupException`；`get_workspace`
//      返回 ok 但空串时按可归因错误拒绝，不静默以空工作区建成员。
//
// 全程临时库 + 假 sidecar，真实 `~/.aliasagent` 不碰（夹具自带隔离断言）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/services/config_service.dart';

import 'helpers/group_core_harness.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 链的时间上界（测试侧，不是产品上限）：出处见 `kTestChainTimeout`。
const Duration kRestoreChainTimeout = kTestChainTimeout;

void main() {
  late GroupCoreHarness harness;

  setUp(() async {
    harness = await GroupCoreHarness.start();
  });

  tearDown(() async {
    await harness.stop();
  });

  /// 建组（显式开启自发反应）+ 加入成员，返回组 id 与成员 id。
  Future<({String groupId, List<String> memberIds})> seed({
    String? workspace,
    List<String> names = const ['甲', '乙'],
  }) async {
    final created = await harness.createGroup(
      title: '重启组',
      workspace: workspace,
      reactionsEnabled: true,
    );
    final groupId = (created['result'] as Map)['group']['id'] as String;
    final ids = <String>[];
    for (final name in names) {
      final member = await harness.addMember(groupId, name);
      ids.add((member['result'] as Map)['member']['id'] as String);
    }
    return (groupId: groupId, memberIds: ids);
  }

  /// 两位成员各跑一次 + 第二轮对甲的公开回复再沉默一次：链自然停。
  ///
  /// 三份事件是**必要**的：甲发言（replied）后触发变成甲那条公开回复，乙还要对新的
  /// 触发再反应一次（pass）；少一份会让第二轮缺 `group_react` → failed（与本条红靶
  /// 无关的错因红）。
  void queueReactionRound(String text) {
    harness.sidecar.queueGroupReact(pass: false, message: text);
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
    harness.sidecar.queueGroupReact(pass: true);
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
    harness.sidecar.queueGroupReact(pass: true);
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
  }

  test('R.14 重启后存量群成员轮仍能反应：chain completed 且步 replied/publicSeq 非空',
      () async {
    final seeded = await seed();
    final groupId = seeded.groupId;
    queueReactionRound('甲的第一次回复');

    await harness.ws.request('group.send', {
      'groupId': groupId,
      'text': '重启前的一条',
    });
    final before = await harness.waitForChain(groupId);
    _obs('重启前的链', before);
    expect(before['status'], 'completed', reason: '前置：重启前这条链必须真的跑通');
    final beforeSteps = before['steps'] as List;
    expect(
      beforeSteps.any((step) =>
          (step as Map)['status'] == 'replied' && step['publicSeq'] != null),
      isTrue,
      reason: '前置：重启前必须有一个真实公开回复步骤',
    );
    final ensureCallsBefore = harness.sidecar.ensureContextCalls.length;

    await harness.restart();
    _obs('重启后 sidecar 已注册句柄数（应为 0）',
        harness.sidecar.ensureContextCalls.length - ensureCallsBefore);

    // 重新排队：重启后新的一轮需要新的 group_react + done（否则链在缺 group_react
    // 的重试上限后 failed，修好了也还是红）。
    queueReactionRound('甲的第二次回复');
    await harness.ws.request('group.send', {
      'groupId': groupId,
      'text': '重启后的一条',
    });
    final after = await harness.waitForChain(groupId);
    _obs('重启后的链', after);
    _obs('重启后 ensureContext 调用',
        harness.sidecar.ensureContextCalls.sublist(ensureCallsBefore));
    expect(
      harness.sidecar.ensureContextCalls.length,
      greaterThan(ensureCallsBefore),
      reason: '重启后成员轮必须先按需重注册群上下文（统一入口 ensureGroupContext）',
    );
    expect(after['status'], 'completed',
        reason: '重启后存量群必须仍能跑通反应链（失败真因=${after['error']}）');
    expect(after['error'], isNull,
        reason: '成功链不得带失败真因（unknown_context 等）');
    final steps = after['steps'] as List;
    expect(
      steps.any((step) =>
          (step as Map)['status'] == 'replied' && step['publicSeq'] != null),
      isTrue,
      reason: '成功判据是 steps 里真有 replied + publicSeq 非空；'
          '不能用「非 steps=0」代替（失败步也让 steps>0）：$steps',
    );
  }, timeout: Timeout(kRestoreChainTimeout));

  test('R.14 同进程幂等：上下文仍在时再次 ensureGroupContext 不覆盖自定义工作区',
      () async {
    final custom = Directory(p.join(harness.root.path, 'custom-ws'))..createSync(recursive: true);
    expect(custom.path, isNot(ConfigService.homeDir),
        reason: '夹具必须用与缺省不同的自定义工作区，否则断言空转');
    final seeded = await seed(workspace: custom.path, names: const ['甲']);
    final groupId = seeded.groupId;

    final firstRead = harness.sidecar.getWorkspace(groupId);
    _obs('建组后的组工作区', firstRead);
    expect(firstRead.ok, isTrue);
    expect(firstRead.workspace, custom.path);

    // 同进程再触发一次成员创建（ensureMemberAgent → ensureGroupContext，缺省 homeDir）。
    final memberB = await harness.addMember(groupId, '乙');
    _obs('第二次成员加入', memberB['result']);
    // 只取**组句柄**的 ensureContext 序列（成员句柄那条是 createMember 用组工作区
    // 初始化的，混在一起会看不出统一入口传的是什么）。
    final groupEnsureIndexes = [
      for (var i = 0; i < harness.sidecar.ensureContextCalls.length; i++)
        if (harness.sidecar.ensureContextCalls[i] == groupId) i,
    ];
    final groupEnsureDefaults = [
      for (final index in groupEnsureIndexes)
        harness.sidecar.ensureContextDefaultWorkspaces[index],
    ];
    _obs('组句柄 ensureContext 收到的 defaultWorkspace 序列', groupEnsureDefaults);
    expect(groupEnsureIndexes.length, greaterThanOrEqualTo(2),
        reason: '建组 + 加成员都要经过组上下文的统一入口');
    expect(groupEnsureDefaults.first, custom.path,
        reason: 'createGroup 必须把自己的 resolvedWorkspace 交给统一入口');
    expect(groupEnsureDefaults.last, ConfigService.homeDir,
        reason: 'ensureMemberAgent 走缺省 homeDir；自定义工作区只能靠 created:false 不被覆盖');

    final readBack = harness.sidecar.getWorkspace(groupId);
    _obs('幂等重注册后的组工作区（读 getWorkspace）', readBack);
    expect(readBack.ok, isTrue);
    expect(readBack.workspace, custom.path,
        reason: '上下文还在（created:false）时重注册不得覆盖已有工作区；'
            '不能拿 fake 自己的 map 当断言');
  });

  test('R.14 重启后自定义工作区回落缺省 homeDir（已知限制）', () async {
    final custom = Directory(p.join(harness.root.path, 'custom-ws'))..createSync(recursive: true);
    final seeded = await seed(workspace: custom.path, names: const ['甲']);
    final groupId = seeded.groupId;

    await harness.restart();
    // 重启后触发该群成员轮（存量成员 + 存量群行）。
    harness.sidecar.queueGroupReact(pass: false, message: '重启后回落缺省的回复');
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
    await harness.ws.request('group.send', {
      'groupId': groupId,
      'text': '自定义工作区的群重启后发一条',
    });
    final chain = await harness.waitForChain(groupId);
    _obs('自定义工作区群重启后的链', chain);
    expect(chain['status'], 'completed',
        reason: '回落缺省也要能反应，不报 unknown_context（真因=${chain['error']}）');

    final readBack = harness.sidecar.getWorkspace(groupId);
    _obs('重启后组工作区（应回落缺省）', readBack);
    _obs('缺省工作区', ConfigService.homeDir);
    expect(readBack.ok, isTrue);
    expect(readBack.workspace, ConfigService.homeDir,
        reason: 'workspace 未持久化：重启后上下文新建（created:true）必用缺省 homeDir；'
            '断言读 getWorkspace，不读 fake 的 defaultWorkspaceByHandle map');
    expect(readBack.workspace, isNot(custom.path));
  }, timeout: Timeout(kRestoreChainTimeout));

  test('R.14 ensureContext 抛 StateError 被包成可归因 GroupException（不是 -32603）',
      () async {
    final seeded = await seed(names: const ['甲']);
    final groupId = seeded.groupId;
    await harness.restart();

    harness.sidecar.nextEnsureContextError =
        'create_context failed: fake_injected_boom';
    final response = await harness.ws.request('group.member.add', {
      'groupId': groupId,
      'name': '乙',
      'templateName': 'general',
    });
    _obs('ensureContext 失败后的 group.member.add 回包', response['error']);
    expect((response['error'] as Map)['code'], -32602,
        reason: 'StateError 没包成 GroupException 时会变成 -32603 internal error');
    final message = '${(response['error'] as Map)['message']}';
    expect(message, contains('fake_injected_boom'));
    expect(message, contains('群聊请求失败'),
        reason: '必须走 GroupException → _groupError 的映射，而不是内部错误');

    // 失败不留下"界面有成员、实际建不出实例"的半状态（addMember 自己软删）。
    final listed = ((await harness.ws.request('group.list'))['result']
        as Map)['groups'] as List;
    final group = listed.singleWhere((item) => (item as Map)['id'] == groupId) as Map;
    final members = group['members'] as List;
    _obs('失败加人后的成员行', members);
    final added = members.where((item) => (item as Map)['name'] == '乙').toList();
    expect(added.length <= 1, isTrue);
    for (final row in added) {
      expect((row as Map)['removedAt'], isNotNull,
          reason: '实例建不出来的成员必须被软删，不能留在活跃成员里');
    }
  });

  test('R.14 getWorkspace ok 但空串 ⇒ 可归因错误，不静默以空工作区建成员', () async {
    final seeded = await seed(names: const ['甲']);
    final groupId = seeded.groupId;
    // 上下文仍在（同进程、已 ensure），把该句柄的工作区改成空串。
    harness.sidecar.stubWorkspace(groupId, '');

    final response = await harness.ws.request('group.member.add', {
      'groupId': groupId,
      'name': '乙',
      'templateName': 'general',
    });
    _obs('空工作区下的 group.member.add 回包', response['error']);
    expect((response['error'] as Map)['code'], -32602,
        reason: '空工作区必须按可归因错误处理，不能静默继续建成员');
    expect('${(response['error'] as Map)['message']}', contains('工作区为空'));
    expect(harness.sidecar.ensureContextCalls, contains(groupId),
        reason: '读工作区前必须先走统一入口 ensureGroupContext');
  });
}
