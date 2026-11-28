// 工作路径的持久化与恢复（change `custom-workspace` 任务 3.3 / 4.1 / design D2、D3）。
//
// 形态：**真 sqlite**（`DatabaseService.openAt` 指向临时目录，绝不碰用户库）+
// `FakeSidecar`（不加载 DLL、不联网）。每个用例自己的临时根目录里放工作区目录、
// 配置路径与附件目录。
//
// 这一层验四件事：
//   ① `SessionRepository.create(workspace:)` 往返、省略写 NULL；
//   ② `updateWorkspace` 核对**恰好一行**（不存在 id 显式失败且不新增行）；
//   ③ `Session.toRow` 写出 workspace、`fromRow` 对缺列 / NULL 读成 null；
//   ④ 单聊重启恢复用持久化工作区（工厂把 `session.workspace` 传给 ensureContext）、
//      旧行 NULL 用缺省、失效路径可归因且**不建上下文**、模板切换保留工作区。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_session_controller.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/workspace.dart';

import 'group_harness.dart';
import 'group_test_support.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

void main() {
  group('SessionRepository.workspace 往返', () {
    late GroupTestSupport support;
    late Directory workspaceA;
    late Directory workspaceB;

    setUp(() async {
      support = await GroupTestSupport.create(prefix: 'workspace_persist_');
      workspaceA = Directory(p.join(support.root.path, 'ws-a'))
        ..createSync(recursive: true);
      workspaceB = Directory(p.join(support.root.path, 'ws-b'))
        ..createSync(recursive: true);
    });

    tearDown(() async {
      // 隔离断言：这组用例绝不写用户真实 ~/.aliasagent 的 db/config/core.lock。
      // ignore: avoid_print
      print(support.describeIsolation());
      expect(support.realUserDirDifferences(), isEmpty,
          reason: '测试绝不能写用户真实 ~/.aliasagent 的 db/config/core.lock');
      await support.dispose();
    });

    test('create(workspace:) 逐字读回；不传则 NULL', () async {
      final repo = support.sessionRepo;
      final withWorkspace =
          await repo.create(title: '带工作区', workspace: workspaceA.path);
      final withoutWorkspace = await repo.create(title: '不带工作区');

      final rereadA = await repo.get(withWorkspace.id);
      final rereadB = await repo.get(withoutWorkspace.id);
      _obs('create(workspace:) 读回', rereadA?.workspace);
      _obs('create(省略 workspace) 读回', rereadB?.workspace);

      expect(rereadA!.workspace, workspaceA.path);
      expect(withWorkspace.workspace, workspaceA.path,
          reason: 'create 返回的模型也要带 workspace（不是只写进库）');
      expect(rereadB!.workspace, isNull, reason: '省略 = 未设置（NULL，不是空串）');

      // 库里该列的文本与写入值逐字相同（不是规范化后的另一个形状）。
      final db = await DatabaseService.database;
      final row = (await db.query('sessions',
              where: 'id = ?', whereArgs: [withWorkspace.id]))
          .first;
      _obs('库里的 workspace 列', row['workspace']);
      expect(row['workspace'], workspaceA.path);
      final nullRow = (await db.query('sessions',
              where: 'id = ?', whereArgs: [withoutWorkspace.id]))
          .first;
      expect(nullRow['workspace'], isNull);
    });

    test('updateWorkspace：存在会话更新恰好 1 行并读回；不存在的 id 显式失败且不新增行', () async {
      final repo = support.sessionRepo;
      final session = await repo.create(title: '原地写', workspace: workspaceA.path);

      final updated = await repo.updateWorkspace(session.id, workspaceB.path);
      _obs('updateWorkspace 返回行数', updated);
      expect(updated, 1, reason: '必须返回受影响行数，调用方要核对恰好一行');
      final reread = await repo.get(session.id);
      _obs('改后读回', reread?.workspace);
      expect(reread!.workspace, workspaceB.path);

      final db = await DatabaseService.database;
      final before = (await db.query('sessions')).length;
      // 不存在的 id：显式失败（返回 0 行，由调用方据此失败），库里不产生新行。
      final missing = await repo.updateWorkspace('no-such-session', workspaceA.path);
      final after = (await db.query('sessions')).length;
      _obs('不存在 id 的返回值 / 行数变化',
          'missing=$missing before=$before after=$after');
      expect(missing, 0, reason: '0 行 = 会话不存在 / 已删，调用方必须显式失败');
      expect(after, before, reason: '写不存在的会话不得新增行');
      expect(await repo.get('no-such-session'), isNull);
    });

    test('Session.toRow 写出 workspace；fromRow 对缺列 / NULL 读成 null，带值时逐字读回', () {
      final base = {
        'id': 's-1',
        'title': 't',
        'agent_type': 'general',
        'created_at': 1,
        'updated_at': 1,
      };
      // 旧库 / 手工夹具：**缺列**。
      final withoutColumn = Session.fromRow(base);
      _obs('缺列读出的 workspace', withoutColumn.workspace);
      expect(withoutColumn.workspace, isNull,
          reason: '缺列必须读成 null（旧库 / 夹具不能因缺字段崩溃）');
      // 显式 NULL。
      final explicitNull = Session.fromRow({...base, 'workspace': null});
      expect(explicitNull.workspace, isNull);
      // 带值。
      final withValue = Session.fromRow({...base, 'workspace': workspaceA.path});
      _obs('带值读回', withValue.workspace);
      expect(withValue.workspace, workspaceA.path);

      // toRow 必须写出 workspace 键（值原样）；null 也照写（列可空）。
      expect(withValue.toRow()['workspace'], workspaceA.path);
      expect(withValue.toRow().containsKey('workspace'), isTrue);
      expect(withoutColumn.toRow().containsKey('workspace'), isTrue);
      expect(withoutColumn.toRow()['workspace'], isNull);

      // copyWith 不能静默丢掉 workspace。
      expect(withValue.copyWith(title: 'new').workspace, workspaceA.path,
          reason: 'copyWith 静默丢 workspace 会让复制出的会话读不到工作区');
      expect(withoutColumn.copyWith(title: 'new').workspace, isNull);
    });
  });

  group('单聊恢复：持久化工作区跨核心重启保留', () {
    late Directory root;
    late Directory workspaceA;
    late GroupHarness harness;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('workspace_restore_');
      workspaceA = Directory(p.join(root.path, 'ws-a'))..createSync(recursive: true);
      // 夹具自带临时库 / 临时 configPath / 临时锁 / 附件目录 + 假 sidecar（不联网），
      // 并注册 general / narrow 两个模板（模板切换用例要 narrow）。
      harness = await GroupHarness.create(createGroup: false);
    });

    tearDown(() async {
      await harness.dispose();
      if (root.existsSync()) {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    /// 建一套「真 AgentFactory + AgentRegistry」——在同一份库上重建即模拟核心重启
    /// （sidecar 上下文表在假 sidecar 里由 `simulateSidecarRestart` 显式清空）。
    AgentFactory buildFactory(AgentRegistry registry) => AgentFactory(
          templates: harness.templates,
          providerResolver: () => harness.factory.providerResolver(),
          config: harness.config,
          sidecar: harness.support.sidecar,
          sessionRepo: harness.support.sessionRepo,
          messageRepo: harness.support.messageRepo,
          summaryNodeRepo: harness.support.summaryNodeRepo,
          registry: registry,
          summaryProvider: harness.support.summary,
          backgroundFoldEnabled: false,
          summaryStoreOpen: () => true,
        );

    test('重启后 ensure 用持久化工作区建上下文（不是缺省主目录）', () async {
      final session = await harness.support.sessionRepo.create(
        title: '重启单聊',
        workspace: workspaceA.path,
      );
      // 模拟核心重启：清空假 sidecar 的上下文表（真实 DLL 重启后上下文全丢）。
      harness.support.sidecar.simulateSidecarRestart();

      final registry = AgentRegistry();
      final factory = buildFactory(registry);
      final agent = await factory.ensure(session);
      final ensureDefault =
          harness.support.sidecar.ensureContextDefaultWorkspaces.last;
      final readBack = harness.support.sidecar.getWorkspace(agent.handle);
      _obs('恢复时 ensureContext 的 defaultWorkspace', ensureDefault);
      _obs('getWorkspace(handle)', readBack);
      expect(ensureDefault, workspaceA.path,
          reason: '恢复必须把持久化工作区作为上下文缺省（不是 ConfigService.homeDir）');
      expect(readBack.ok, isTrue);
      expect(readBack.workspace, workspaceA.path);
      expect(readBack.workspace, isNot(ConfigService.homeDir));
      await registry.disposeAll();
    });

    test('旧行 workspace = NULL ⇒ 传给 ensureContext 的是 ConfigService.homeDir（缺省不变）', () async {
      final session = await harness.support.sessionRepo.create(title: '旧行单聊');
      harness.support.sidecar.simulateSidecarRestart();

      final registry = AgentRegistry();
      final factory = buildFactory(registry);
      final agent = await factory.ensure(session);
      final ensureDefault =
          harness.support.sidecar.ensureContextDefaultWorkspaces.last;
      _obs('旧行恢复的 defaultWorkspace', ensureDefault);
      _obs('ConfigService.homeDir', ConfigService.homeDir);
      expect(session.workspace, isNull, reason: '前置：这条会话的 workspace 是 NULL');
      expect(ensureDefault, ConfigService.homeDir,
          reason: 'NULL = 未设置，沿用既有缺省口径（本 change 不改 homeDir）');
      expect(harness.support.sidecar.getWorkspace(agent.handle).workspace,
          ConfigService.homeDir);
      await registry.disposeAll();
    });

    test('持久化路径失效（目录已删）⇒ WorkspaceUnavailableException，且不建上下文', () async {
      final gone = Directory(p.join(root.path, 'gone'))..createSync(recursive: true);
      final session = await harness.support.sessionRepo.create(
        title: '目录已删',
        workspace: gone.path,
      );
      gone.deleteSync(recursive: true);
      harness.support.sidecar.simulateSidecarRestart();

      final registry = AgentRegistry();
      final factory = buildFactory(registry);
      Object? thrown;
      try {
        await factory.ensure(session);
      } catch (error) {
        thrown = error;
      }
      _obs('失效路径抛出的异常', thrown);
      expect(thrown, isA<WorkspaceUnavailableException>());
      final exception = thrown as WorkspaceUnavailableException;
      expect(exception.path, gone.path);
      expect(exception.toString(), contains(gone.path));
      expect(exception.toString(), contains('已存在'),
          reason: '错误消息必须带「改到已存在目录」的出路');
      // 校验发生在建上下文之前：句柄没有被 ensureContext 记录（不留下空工作区上下文）。
      final ensureCallsForHandle = harness.support.sidecar.ensureContextCalls
          .where((handle) => handle == session.id)
          .length;
      _obs('该句柄的 ensureContext 调用次数', ensureCallsForHandle);
      expect(ensureCallsForHandle, 0,
          reason: '校验必须在建上下文之前：失败不得留下空工作区上下文（allow-all）');
      expect(registry.lookup(session.id), isNull, reason: '失败不得登记实例');
    });

    test('模板切换后上下文工作区仍是同一目录（切换保留工作区）', () async {
      final session = await harness.support.sessionRepo.create(
        title: '切模板',
        workspace: workspaceA.path,
      );
      harness.support.sidecar.simulateSidecarRestart();
      final registry = AgentRegistry();
      final factory = buildFactory(registry);
      final controller = AgentSessionController(
        factory: factory,
        sessionRepo: harness.support.sessionRepo,
      );
      final before = await factory.ensure(session);
      final beforeRead = harness.support.sidecar.getWorkspace(before.handle);
      _obs('切换前工作区', beforeRead);

      final switched = await controller.switchTemplate(
        await harness.support.sessionRepo.get(session.id) ?? session,
        'narrow',
        callbacks: const AgentCallbacks(),
      );
      final afterRead = harness.support.sidecar.getWorkspace(switched.handle);
      _obs('切换后工作区', afterRead);
      expect(switched.agentTypeName, 'narrow');
      expect(beforeRead.workspace, workspaceA.path);
      expect(afterRead.ok, isTrue);
      expect(afterRead.workspace, beforeRead.workspace,
          reason: '模板切换只换实例，不换工作区（退役不释放上下文）');
      await registry.disposeAll();
    });
  });
}
