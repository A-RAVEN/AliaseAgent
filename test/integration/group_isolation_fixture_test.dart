// 群聊集成测试隔离夹具的自检（change `agent-group-chat` 任务 1.1）。
//
// 这条用例证明三件事：
//   ① 夹具把 configPath / attachmentsDir / DatabaseService / lockPath 四项都指到临时目录；
//   ② 往这套夹具里真的写数据（建会话 + 插消息），用户真实 `~/.aliasagent` 下的
//      db / config / core.lock 的 mtime 与大小一律未变；
//   ③ `logs/` 只记录基线（已知副作用），不参与"必须不变"的断言。
//
// 红证据：夹具文件不存在时本用例编译失败（`group_test_support.dart` 找不到）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';

import 'group_test_support.dart';

void main() {
  group('群聊集成测试隔离夹具', () {
    late GroupTestSupport support;

    setUp(() async {
      support = await GroupTestSupport.create();
    });

    tearDown(() async {
      await support.dispose();
    });

    test('四项注入都指向临时目录，且写数据不碰用户真实 db/config/core.lock', () async {
      final realConfigDir = p.normalize(ConfigService.configDir);

      // ① 路径全在临时根目录下（逐项打印，失败可归因）。
      final paths = <String, String>{
        'configPath': support.configPath,
        'attachmentsDir': support.attachmentsDir,
        'databaseDir': support.databaseDir,
        'lockPath': support.lockPath,
        'workspaceDir': support.workspaceDir,
      };
      // ignore: avoid_print
      print(support.describeIsolation());
      for (final entry in paths.entries) {
        // ignore: avoid_print
        print('[隔离] ${entry.key} = ${entry.value}');
        expect(p.isWithin(support.root.path, entry.value), isTrue,
            reason: '${entry.key} 必须在临时根目录内：${entry.value}');
        expect(p.normalize(entry.value), isNot(p.normalize(realConfigDir)),
            reason: '${entry.key} 不许指向用户真实配置目录');
      }

      // DatabaseService 真的开在临时目录：写入后真实 db 文件不出现在用户目录
      // （如果出现，说明 openAt 没生效）。
      expect(DatabaseService.isOpen, isTrue);
      final tempDb = File(p.join(support.databaseDir, 'aliasagent.db'));
      expect(tempDb.existsSync(), isTrue, reason: '临时目录里应有 aliasagent.db');

      // ② 真的写数据：建会话 + 插消息（走产品仓储，不手写 SQL）。
      final session = await support.sessionRepo.create(title: '隔离自检');
      await support.messageRepo.insert(
        sessionId: session.id,
        role: 'user',
        content: '这条消息只许落在临时库里',
      );
      final rows = await support.messageRepo.queryBySession(session.id);
      expect(rows.length, 1);

      // ③ 用户真实 db / config / core.lock 的 mtime + 大小未变。
      final diffs = support.realUserDirDifferences();
      // ignore: avoid_print
      print('[隔离] 真实目录差异 = ${diffs.isEmpty ? "无" : diffs.join(" ; ")}');
      expect(diffs, isEmpty,
          reason: '测试写到了用户真实 ~/.aliasagent：${diffs.join(" ; ")}');

      // 临时锁文件在临时目录，且不是真实锁文件。
      expect(File(support.lockPath).existsSync(), isTrue);
      expect(p.normalize(support.lockPath),
          isNot(p.normalize(p.join(realConfigDir, 'core.lock'))));
    });
  });
}
