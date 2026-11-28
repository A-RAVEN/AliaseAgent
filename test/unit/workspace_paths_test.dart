// 工作路径的纯逻辑（change `custom-workspace` 任务 2.1 / design D4、D5）。
//
// 这一层只测**纯 Dart**：输入规范化、四类不合法、系统提示段的文案形态。它不碰
// sidecar、不碰数据库、不读用户目录 —— 目录存在性用测试自己造的临时目录。
//
// 断言的判据是**文案**而不是"函数存在"：缺「没有沙箱」「不可撤销」或把相对路径
// 当合法输入，都必须在阶段 2.1 先红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/services/workspace.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

void main() {
  group('stripWorkspaceInput：去空白 / 去成对引号 / 折叠 ..', () {
    test('去掉首尾空白与一对匹配的双引号（Explorer「复制为路径」形态）', () {
      final target = p.join(p.separator, 'work', 'proj');
      // 带引号 + 前后空白的输入必须还原成同一个路径。
      final raw = '  "$target"  ';
      final stripped = stripWorkspaceInput(raw);
      _obs('原始输入', raw);
      _obs('去引号后', stripped);
      expect(stripped, target);
      // 只去掉**成对**的引号：只有一侧引号时按字面处理（不猜用户意思）。
      final oneSided = '$target"';
      expect(stripWorkspaceInput(oneSided), '$target"');
    });

    test('折叠 ..（平台无关：期望值由 package:path 给出）', () {
      final raw = p.join('a', '..', 'b');
      final expected = p.normalize(p.join('a', '..', 'b'));
      _obs('输入', raw);
      _obs('期望（p.normalize）', expected);
      expect(stripWorkspaceInput(raw), expected);
      expect(stripWorkspaceInput('  $raw  '), expected);
    });

    test('保留绝对路径的盘符 / 根', () {
      final absolute = p.normalize(p.absolute(p.join('some', 'dir')));
      _obs('absolute', absolute);
      expect(stripWorkspaceInput('  $absolute  '), absolute);
      expect(p.isAbsolute(stripWorkspaceInput(absolute)), isTrue);
    });
  });

  group('workspaceProblem：合法目录返回 null，四类不合法各带可归因原因', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('workspace_paths_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        try {
          tempRoot.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('合法目录返回 null', () {
      final valid = p.join(tempRoot.path, 'valid');
      Directory(valid).createSync();
      final problem = workspaceProblem(valid);
      _obs('合法目录的问题描述', problem);
      expect(problem, isNull);
    });

    test('空串含「空」', () {
      final problem = workspaceProblem('');
      _obs('空串的问题描述', problem);
      expect(problem, isNotNull);
      expect(problem, contains('空'));
    });

    test('相对路径含「绝对路径」', () {
      final problem = workspaceProblem(p.join('some', 'relative'));
      _obs('相对路径的问题描述', problem);
      expect(problem, isNotNull);
      expect(problem, contains('绝对路径'));
    });

    test('不存在的目录含「不存在」', () {
      final missing = p.join(tempRoot.path, 'nope-does-not-exist');
      final problem = workspaceProblem(missing);
      _obs('不存在目录的问题描述', problem);
      expect(problem, isNotNull);
      expect(problem, contains('不存在'));
    });

    test('指向文件含「不是目录」', () {
      final file = File(p.join(tempRoot.path, 'a-file.txt'))
        ..writeAsStringSync('x');
      final problem = workspaceProblem(file.path);
      _obs('文件路径的问题描述', problem);
      expect(problem, isNotNull);
      expect(problem, contains('不是目录'));
      // 文件存在 ≠ 目录可用：不能只说「不存在」。
      expect(problem, isNot(contains('不存在')));
    });
  });

  group('workspacePromptSection：稳定段落文案', () {
    final path = p.join(p.separator, 'work', 'proj');
    final section = workspacePromptSection(path);

    test('含标题常量、路径原文、相对路径与越界说明', () {
      _obs('整段', section);
      expect(section, contains(kWorkspacePromptHeading));
      expect(section, contains(path));
      expect(section, contains('相对路径'));
      expect(section, contains('越'));
      expect(section, contains('拒绝'));
    });

    test('逐字含「没有沙箱」「不可撤销」，且不作与实际权限不符的承诺', () {
      expect(section, contains('没有沙箱'));
      expect(section, contains('不可撤销'));
      // 工作区不是沙箱：不许写「只能访问该目录」这类承诺。
      expect(section, isNot(contains('只能访问该目录')));
      // 提示里要说明每轮以此为准（切换在下一轮生效的语义）。
      expect(section, contains('每一轮'));
    });
  });

  group('workspaceUnavailablePromptSection：读不到工作区时写明不可用', () {
    final reason = 'get_workspace 返回 ok:false（unknown_context）';
    final section = workspaceUnavailablePromptSection(reason);

    test('含「当前没有可用工作区」与原因，不含任何目录', () {
      _obs('整段', section);
      expect(section, contains('当前没有可用工作区'));
      expect(section, contains(reason));
      // 不伪装成某个目录：段落里不出现盘符 / 根路径形态。
      expect(section, isNot(matches(RegExp(r'[A-Za-z]:\\'))));
      expect(section, isNot(contains('/work/')));
    });
  });

  group('WorkspaceUnavailableException：可归因（路径 + 出路）', () {
    test('toString 含路径与改到已存在目录的出路', () {
      final path = p.join(p.separator, 'gone', 'work');
      final error = WorkspaceUnavailableException(
        path: path,
        reason: '不存在',
        sessionId: 'session-1',
      );
      _obs('异常文本', error.toString());
      expect(error.path, path);
      expect(error.reason, '不存在');
      expect(error.sessionId, 'session-1');
      expect(error.toString(), contains(path));
      expect(error.toString(), contains('存在'));
    });
  });

  // ---------------------------------------------------------------------------
  // 返工 12.11：「此电脑」虚拟根（Windows 多盘可达）
  //
  // 盘符枚举用**注入夹具**（`driveRoots`），不假设真机有哪些盘；真机只读列举
  // 放在 integration（`web_core_rpc_test.dart`）。drives 根不是真实目录：
  // `isDirectory=false`、parent=null，不能被 `workspaceProblem` 当成工作路径。
  // ---------------------------------------------------------------------------
  group('listWorkspaceDirectories：「此电脑」虚拟根（返工 12.11）', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('workspace_drives_');
    });

    tearDown(() {
      if (temp.existsSync()) {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('drives 根列出注入的盘符（按名字排序），parent=null，isDirectory=false', () {
      final listing = listWorkspaceDirectories(
        kWorkspaceDrivesRoot,
        defaultDir: temp.path,
        driveRoots: ['D:\\', 'C:\\'],
      );
      _obs('drives 根回包', listing.toJson());
      expect(listing.path, kWorkspaceDrivesRoot);
      expect(listing.parent, isNull);
      expect(listing.isDirectory, isFalse,
          reason: '「此电脑」不是目录：确认按钮据此禁用，不能被选成工作路径');
      expect([for (final entry in listing.directories) entry.name], ['C:', 'D:']);
      expect([for (final entry in listing.directories) entry.path], ['C:\\', 'D:\\']);
    });

    test('Windows 盘符根的 parent 是 drives 根；普通目录仍给上级', () {
      if (Platform.isWindows) {
        final root = p.rootPrefix(temp.path);
        final listing = listWorkspaceDirectories(root, defaultDir: temp.path);
        _obs('盘符根 $root 的 parent', listing.parent);
        expect(listing.parent, kWorkspaceDrivesRoot,
            reason: '盘符根必须能「上级」回「此电脑」，否则其它盘不可达');
      }
      final listing = listWorkspaceDirectories(temp.path, defaultDir: temp.path);
      expect(listing.parent, isNotNull, reason: '普通临时目录的上级必须给出来');
    });

    test('drives 根不能被当成工作路径提交（含盘符相对路径 C:）', () {
      final problem = workspaceProblem(kWorkspaceDrivesRoot);
      _obs('drives 根的校验结果', problem);
      expect(problem, isNotNull);
      expect(problem, contains('绝对路径'));
    });
  });
}
