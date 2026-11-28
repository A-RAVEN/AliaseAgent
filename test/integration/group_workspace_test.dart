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
import 'package:alias_agent/services/group_service.dart';

import 'group_harness.dart';
import 'helpers/group_core_harness.dart';

/// 轮询等待（测试侧上界，不是产品上限；只用于"等异步链进入某状态"）。
Future<void> _waitUntil(bool Function() predicate, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('等待超时：$what');
}

/// 同上，但判据本身是异步的（WS 侧要发 `group.list`）。
Future<void> _waitUntilAsync(
    Future<bool> Function() predicate, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('等待超时：$what');
}

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

  // ---------------------------------------------------------------------------
  // change `custom-workspace` 5.1：组工作区的落库 / 切换传播 / busy / 成员轮对齐
  // ---------------------------------------------------------------------------

  test('createGroup(workspace:) 落库；未传 / 只有空白 ⇒ NULL（用缺省）', () async {
    final harness = await GroupHarness.create(workspace: null);
    final explicit = p.join(harness.support.root.path, 'explicit-ws');
    Directory(explicit).createSync(recursive: true);

    final group =
        await harness.groups.createGroup(title: '带工作区落库', workspace: explicit);
    final row = await harness.support.sessionRepo.get(group.id);
    // ignore: avoid_print
    print('[OBS] createGroup(workspace: $explicit) 模型/库='
        '${group.workspace} / ${row?.workspace}');
    expect(group.workspace, explicit);
    expect(row!.workspace, explicit, reason: '带 workspace 的建组必须落库');

    final omitted = await harness.groups.createGroup(title: '省略工作区');
    final omittedRow = await harness.support.sessionRepo.get(omitted.id);
    // ignore: avoid_print
    print('[OBS] 省略 workspace：模型/库=${omitted.workspace} / ${omittedRow?.workspace}');
    expect(omitted.workspace, isNull);
    expect(omittedRow!.workspace, isNull,
        reason: '省略 = 未设置（NULL），不是把缺省主目录写进库');

    final blank =
        await harness.groups.createGroup(title: '空白工作区', workspace: '   ');
    final blankRow = await harness.support.sessionRepo.get(blank.id);
    // ignore: avoid_print
    print('[OBS] 空白 workspace：模型/库=${blank.workspace} / ${blankRow?.workspace}');
    expect(blank.workspace, isNull, reason: '只有空白 = 省略');
    expect(blankRow!.workspace, isNull);
    await harness.dispose();
  });

  test('createGroup(workspace: 不存在) ⇒ 可归因错误且不建会话行', () async {
    final harness = await GroupHarness.create(workspace: null);
    final before = (await harness.support.sessionRepo.list()).length;
    final missing = p.join(harness.support.root.path, 'no-such-dir-9f1');
    Object? thrown;
    try {
      await harness.groups.createGroup(title: '坏工作区', workspace: missing);
    } catch (error) {
      thrown = error;
    }
    // ignore: avoid_print
    print('[OBS] createGroup(不存在) 抛出=$thrown');
    expect(thrown, isA<GroupException>());
    final exception = thrown as GroupException;
    expect(exception.code, 'invalid_workspace');
    expect(exception.message, contains(missing),
        reason: '错误必须含路径与原因（可归因）');
    final after = (await harness.support.sessionRepo.list()).length;
    // ignore: avoid_print
    print('[OBS] 建组失败前后的会话行数=$before -> $after');
    expect(after, before, reason: '校验失败不得创建组会话行');
    await harness.dispose();
  });

  test('group.setWorkspace 更新组上下文 + 两个成员 handle + 库值', () async {
    final harness = await GroupHarness.create(workspace: null);
    final memberA = await harness.addMember('甲');
    final memberB = await harness.addMember('乙');
    final target = Directory(p.join(harness.support.root.path, 'ws-target'))
      ..createSync(recursive: true);

    final updated =
        await harness.groups.setWorkspace(harness.group.id, target.path);
    final groupRead = harness.support.sidecar.getWorkspace(harness.group.id);
    final readA = harness.support.sidecar.getWorkspace(memberA.handle);
    final readB = harness.support.sidecar.getWorkspace(memberB.handle);
    final row = await harness.support.sessionRepo.get(harness.group.id);
    final propagated = [
      for (final call in harness.support.sidecar.setWorkspaceCalls)
        '${call.handle}=${call.path}',
    ];
    // ignore: avoid_print
    print('[OBS] setWorkspace 返回=${updated.workspace} 库=${row?.workspace} '
        '组上下文=${groupRead.workspace} 甲=${readA.workspace} 乙=${readB.workspace}');
    // ignore: avoid_print
    print('[OBS] setWorkspace 调用序列=$propagated');

    expect(updated.workspace, target.path);
    expect(row!.workspace, target.path);
    expect(groupRead.ok, isTrue);
    expect(p.equals(groupRead.workspace!, target.path), isTrue);
    expect(readA.ok, isTrue);
    expect(p.equals(readA.workspace!, target.path), isTrue,
        reason: '切换必须传播到在册成员的上下文（不是只换显示）');
    expect(readB.ok, isTrue);
    expect(p.equals(readB.workspace!, target.path), isTrue);
    await harness.dispose();
  });

  test('链运行中 group.setWorkspace ⇒ busy 且库 / 组上下文 / 成员都不改', () async {
    final harness = await GroupHarness.create(workspace: null);
    final memberA = await harness.addMember('甲');
    final beforeRow = await harness.support.sessionRepo.get(harness.group.id);
    final beforeGroup = harness.support.sidecar.getWorkspace(harness.group.id);
    // 把成员这一轮挂住：gateNextSend 让 sendMessage 等释放。
    harness.support.sidecar.gateNextSend();
    harness.queueSimpleReply('运行中的回复');
    await harness.groups.send(
        groupId: harness.group.id, memberId: memberA.id, text: '开始');
    await _waitUntil(
        () => harness.groups.isGroupBusy(harness.group.id), '链进入运行中');
    // 只看到 busy 可能只是执行器刚启动：再等这一轮的 sendMessage 真的被闸门挂住，
    // 否则后面的 releaseGate 会落空（链永远不结束 → 用例超时，红因与本用例无关）。
    await _waitUntil(() => harness.support.sidecar.awaitingGateCount == 1,
        '成员轮被发送闸门挂住');
    final target = Directory(p.join(harness.support.root.path, 'ws-while-busy'))
      ..createSync(recursive: true);

    Object? thrown;
    try {
      await harness.groups.setWorkspace(harness.group.id, target.path);
    } catch (error) {
      thrown = error;
    }
    // ignore: avoid_print
    print('[OBS] 链运行中 setWorkspace 抛出=$thrown');
    expect(thrown, isA<GroupException>());
    expect((thrown as GroupException).code, 'busy');
    expect(harness.support.sidecar.getWorkspace(harness.group.id).workspace,
        beforeGroup.workspace);
    expect((await harness.support.sessionRepo.get(harness.group.id))!.workspace,
        beforeRow!.workspace);
    expect(
        harness.support.sidecar.setWorkspaceCalls
            .any((call) => p.equals(call.path, target.path)),
        isFalse,
        reason: 'busy 时不得排队、不得中途改根');

    harness.support.sidecar.releaseGate();
    await harness.waitForChain();
    await harness.dispose();
  });

  test('非法路径 ⇒ 可归因错误且组上下文 / 成员 / 库都不变', () async {
    final harness = await GroupHarness.create(workspace: null);
    final memberA = await harness.addMember('甲');
    final beforeRow = await harness.support.sessionRepo.get(harness.group.id);
    final beforeGroup = harness.support.sidecar.getWorkspace(harness.group.id);
    final beforeMember = harness.support.sidecar.getWorkspace(memberA.handle);
    final file = File(p.join(harness.support.root.path, 'not-a-dir.txt'))
      ..writeAsStringSync('x');
    final badPaths = <String>[
      p.join(harness.support.root.path, 'missing-dir-9f1'),
      'relative/whatever',
      file.path,
      '',
    ];
    for (final bad in badPaths) {
      Object? thrown;
      try {
        await harness.groups.setWorkspace(harness.group.id, bad);
      } catch (error) {
        thrown = error;
      }
      // ignore: avoid_print
      print('[OBS] 非法路径「$bad」抛出=$thrown');
      expect(thrown, isA<GroupException>(), reason: '非法路径 $bad 必须显式失败');
      expect((thrown as GroupException).code, 'invalid_workspace');
    }
    expect(harness.support.sidecar.getWorkspace(harness.group.id).workspace,
        beforeGroup.workspace);
    expect(harness.support.sidecar.getWorkspace(memberA.handle).workspace,
        beforeMember.workspace);
    expect((await harness.support.sessionRepo.get(harness.group.id))!.workspace,
        beforeRow!.workspace);
    await harness.dispose();
  });

  test('成员轮开始对齐：把成员上下文改歪后跑一轮会回正', () async {
    final harness = await GroupHarness.create(workspace: null);
    final memberA = await harness.addMember('甲');
    final stale = Directory(p.join(harness.support.root.path, 'stale-ws'))
      ..createSync(recursive: true);
    // 模拟"切换时即时传播失败 / 上下文被别处改过"。
    harness.support.sidecar.stubWorkspace(memberA.handle, stale.path);
    final before = harness.support.sidecar.getWorkspace(memberA.handle);
    // ignore: avoid_print
    print('[OBS] 对齐前的成员工作区=${before.workspace}（组=${harness.support.workspaceDir}）');
    expect(p.equals(before.workspace!, stale.path), isTrue);

    harness.queueSimpleReply('对齐后的一轮');
    await harness.groups.send(
        groupId: harness.group.id, memberId: memberA.id, text: '对齐');
    final chain = await harness.waitForChain();
    final after = harness.support.sidecar.getWorkspace(memberA.handle);
    final alignedCalls = [
      for (final call in harness.support.sidecar.setWorkspaceCalls)
        if (call.handle == memberA.handle) call.path,
    ];
    // ignore: avoid_print
    print('[OBS] 对齐后的成员工作区=${after.workspace} 链=${chain.status} '
        '对齐 setWorkspace 调用=$alignedCalls');
    expect(chain.status, 'completed', reason: '对齐后该轮仍要正常完成');
    expect(p.equals(after.workspace!, harness.support.workspaceDir), isTrue,
        reason: '成员轮装配前必须对齐到组当前工作区（不沿旧目录干活）');
    expect(
        alignedCalls.any((path) => p.equals(path, harness.support.workspaceDir)),
        isTrue,
        reason: '对齐必须真的调 sidecar.setWorkspace（留一行日志的另一半）');
    await harness.dispose();
  });

  test('WS 级：group.setWorkspace 成功回 {group}；非法路径 / kind 不符 / 链运行中 busy',
      () async {
    final harness = await GroupCoreHarness.start();
    try {
      final created =
          await harness.createGroup(title: 'WS 工作区组', workspace: harness.root.path);
      final group = (created['result'] as Map)['group'] as Map;
      final groupId = group['id'] as String;
      final member =
          await harness.addMember(groupId, '甲');
      final memberId =
          ((member['result'] as Map)['member'] as Map)['id'] as String;

      final target = Directory(p.join(harness.root.path, 'ws-ws-target'))
        ..createSync(recursive: true);
      final ok =
          await harness.ws.request('group.setWorkspace', {
        'groupId': groupId,
        'workspace': target.path,
      });
      // ignore: avoid_print
      print('[OBS] WS group.setWorkspace 成功回包=$ok');
      expect(ok['error'], isNull);
      final returned = (ok['result'] as Map)['group'] as Map;
      expect(returned['workspace'], target.path);
      final listed = ((await harness.ws.request('group.list'))['result']
          as Map)['groups'] as List;
      final listedGroup = listed
          .singleWhere((item) => (item as Map)['id'] == groupId) as Map;
      expect(listedGroup['workspace'], target.path, reason: 'group.list 必须序列化 workspace');

      final bad = await harness.ws.request('group.setWorkspace', {
        'groupId': groupId,
        'workspace': p.join(harness.root.path, 'missing-9f1'),
      });
      // ignore: avoid_print
      print('[OBS] WS group.setWorkspace 非法路径=$bad');
      expect((bad['error'] as Map)['code'], -32602);
      expect('${(bad['error'] as Map)['message']}', contains('missing-9f1'));

      final single = await harness.ws.request('session.create', {'title': '单聊'});
      final singleId =
          ((single['result'] as Map)['session'] as Map)['id'] as String;
      final wrongKind = await harness.ws.request('group.setWorkspace', {
        'groupId': singleId,
        'workspace': target.path,
      });
      // ignore: avoid_print
      print('[OBS] WS group.setWorkspace(单聊 id)=$wrongKind');
      expect((wrongKind['error'] as Map)['code'], -32602);
      final wrongMethod = await harness.ws.request('session.setWorkspace', {
        'sessionId': groupId,
        'workspace': target.path,
      });
      // ignore: avoid_print
      print('[OBS] WS session.setWorkspace(组 id)=$wrongMethod');
      expect((wrongMethod['error'] as Map)['code'], -32602);

      // 链运行中：把该成员这一轮挂住，busy 期间切换被拒，值不变。
      harness.sidecar.gateNextSend();
      harness.sidecar.queueChunk('运行中');
      harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
      await harness.ws.request('group.send', {
        'groupId': groupId,
        'speaker': memberId,
        'text': '开始',
      });
      await _waitUntilAsync(() async {
        final list = ((await harness.ws.request('group.list'))['result']
            as Map)['groups'] as List;
        final item = list
            .singleWhere((entry) => (entry as Map)['id'] == groupId) as Map;
        return item['busy'] == true;
      }, 'WS 侧 group.list busy=true');
      // 同时确认这一轮的 sendMessage 真的被闸门挂住（否则 releaseGate 会落空）。
      await _waitUntilAsync(
          () async => harness.sidecar.awaitingGateCount == 1, 'WS 侧发送闸门挂住');
      final other = Directory(p.join(harness.root.path, 'ws-busy-target'))
        ..createSync(recursive: true);
      final busy = await harness.ws.request('group.setWorkspace', {
        'groupId': groupId,
        'workspace': other.path,
      });
      // ignore: avoid_print
      print('[OBS] WS group.setWorkspace(链运行中)=$busy');
      expect((busy['error'] as Map)['code'], -32602);
      expect('${(busy['error'] as Map)['message']}', contains('busy'));
      final afterBusy = ((await harness.ws.request('group.list'))['result']
          as Map)['groups'] as List;
      final afterGroup = afterBusy
          .singleWhere((item) => (item as Map)['id'] == groupId) as Map;
      expect(afterGroup['workspace'], target.path, reason: 'busy 不改值');
      harness.sidecar.releaseGate();
      await harness.waitForChain(groupId);
    } finally {
      await harness.stop();
    }
  }, timeout: Timeout(kTestChainTimeout));
}
