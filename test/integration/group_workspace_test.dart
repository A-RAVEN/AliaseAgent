// 组上下文与共享工作区（change `agent-group-chat` 任务 5.1 / 5.8 /
// spec「组会话与成员」「共享工作区继承」）。
//
// 三条路径断言：
//   ① `group.create` 带 workspace ⇒ 组上下文的工作区就是它；
//   ② 不带 workspace ⇒ 复用产品既有缺省（`ConfigService.homeDir`，不发明第二个缺省）；
//   ③ 成员创建经 `sidecar.getWorkspace(groupId)` **继承**组工作区（走生产路径，
//      不靠夹具手工 setWorkspace）。
// 5.8：两个成员的上下文工作区逐字相同，真实临时目录里的文件两边读到同一内容。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/services/config_service.dart';

import 'group_harness.dart';

void main() {
  test('group.create 带 workspace：组上下文工作区就是它', () async {
    final harness = await GroupHarness.create(workspace: null);
    // create 用了 support.workspaceDir（见 harness 默认），换一个显式路径再建一个组。
    final explicit = p.join(harness.support.root.path, 'explicit-ws');
    Directory(explicit).createSync(recursive: true);
    final group = await harness.groups.createGroup(title: '带工作区', workspace: explicit);

    final ensureCall = harness.support.sidecar.ensureContextDefaultWorkspaces.last;
    final readBack = harness.support.sidecar.getWorkspace(group.id);
    // ignore: avoid_print
    print('[OBS] ensureContext defaultWorkspace=$ensureCall '
        'getWorkspace=${readBack.workspace}');
    expect(ensureCall, explicit);
    expect(readBack.ok, isTrue);
    expect(readBack.workspace, explicit,
        reason: '组上下文保存的工作区必须等于传入值（成员要靠它继承）');

    await harness.dispose();
  });

  test('group.create 不带 workspace：缺省是产品既有缺省工作区', () async {
    final harness = await GroupHarness.create(workspace: null);
    final group = await harness.groups.createGroup(title: '缺省工作区');
    final ensureCall = harness.support.sidecar.ensureContextDefaultWorkspaces.last;
    // ignore: avoid_print
    print('[OBS] 缺省工作区=$ensureCall ConfigService.homeDir=${ConfigService.homeDir}');
    expect(ensureCall, ConfigService.homeDir,
        reason: '缺省必须复用 Agent.ensureContext 的既有口径，不发明第二个缺省值');
    expect(harness.support.sidecar.getWorkspace(group.id).workspace,
        ConfigService.homeDir);
    await harness.dispose();
  });

  test('成员经 getWorkspace(groupId) 继承组工作区（生产路径）', () async {
    final harness = await GroupHarness.create(workspace: null);
    final workspace = harness.support.workspaceDir;
    final memberA = await harness.addMember('甲');
    final memberB = await harness.addMember('乙');

    // ignore: avoid_print
    print('[OBS] getWorkspace 调用=${harness.support.sidecar.getWorkspaceCalls}');
    // ignore: avoid_print
    print('[OBS] 甲的上下文缺省工作区='
        '${harness.support.sidecar.defaultWorkspaceByHandle[memberA.handle]} '
        '乙=${harness.support.sidecar.defaultWorkspaceByHandle[memberB.handle]}');

    expect(harness.support.sidecar.getWorkspaceCalls, contains(harness.group.id),
        reason: '成员创建必须读组上下文的工作区');
    expect(harness.support.sidecar.defaultWorkspaceByHandle[memberA.handle],
        workspace,
        reason: '甲的上下文工作区 = 组上下文保存的工作区（不是默认主目录）');
    expect(harness.support.sidecar.defaultWorkspaceByHandle[memberB.handle],
        workspace);
    await harness.dispose();
  });

  test('5.8 共享工作区读写：甲写的文件乙读到同一内容', () async {
    final harness = await GroupHarness.create(workspace: null);
    final memberA = await harness.addMember('甲');
    final memberB = await harness.addMember('乙');

    final wsA =
        harness.support.sidecar.defaultWorkspaceByHandle[memberA.handle]!;
    final wsB =
        harness.support.sidecar.defaultWorkspaceByHandle[memberB.handle]!;
    expect(wsA, wsB, reason: '两个成员必须落在同一个目录');

    // 真实临时目录里的真实文件（不碰用户 homeDir）。
    final file = File(p.join(wsA, 'shared-note.txt'));
    file.writeAsStringSync('甲写的协调内容 93f1');
    final readByB = File(p.join(wsB, 'shared-note.txt')).readAsStringSync();
    // ignore: avoid_print
    print('[OBS] 工作区=$wsA 文件=${file.path} 乙读到=「$readByB」');
    expect(readByB, '甲写的协调内容 93f1');
    await harness.dispose();
  });
}
