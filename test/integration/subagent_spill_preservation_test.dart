// 子运行结束后父 spill 仍可用（add-spawn-subagent-tool 任务 5.3）。
//
// 用**真实 sidecar** 与两个临时工作区：父、子各跑一条大输出命令产生自己的 spill，
// 然后按生产清理路径销毁子上下文。断言：
//   - 子 spill 目录按契约删掉，父 spill 文件与引用仍可读（字节一致）；
//   - 父后续输出用新序号、不覆盖旧文件，旧引用仍读到旧内容；
//   - 子上下文销毁后，用父句柄读子的引用必须失败（不跨句柄泄漏）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

void main() {
  test('父子各产生 spill：子销毁后父引用仍可读，父后续输出不覆盖旧文件', () async {
    final bridge = SidecarBridge.instance;
    const parentHandle = 'it-subagent-spill-parent';
    const childHandle = 'it-subagent-spill-child';
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    expect(home.isNotEmpty, isTrue, reason: '拿不到用户主目录就没法定位 spill 根');
    final parentSpillDir = Directory('$home/.aliasagent/spill/$parentHandle');
    final childSpillDir = Directory('$home/.aliasagent/spill/$childHandle');
    final parentWs = Directory.systemTemp.createTempSync('spill_parent_');
    final childWs = Directory.systemTemp.createTempSync('spill_child_');

    Future<Map<String, dynamic>> runBig(String handle, String marker) async {
      final raw = await bridge.runCommand(
        handle,
        jsonEncode({
          'command':
              "1..400 | ForEach-Object { Write-Output ('$marker' + ('x' * 40)) }",
          'preview_chars': 200,
        }),
      );
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> readRef(String handle, String ref) async {
      final raw = bridge.readSpill(
          handle, jsonEncode({'ref': ref, 'offset': 0, 'limit': 64}));
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    try {
      // 从干净状态开始（这些句柄只属于本用例）。
      await bridge.disposeContext(childHandle);
      await bridge.disposeContext(parentHandle);
      if (parentSpillDir.existsSync()) parentSpillDir.deleteSync(recursive: true);
      if (childSpillDir.existsSync()) childSpillDir.deleteSync(recursive: true);

      await bridge.ensureContext(parentHandle, defaultWorkspace: parentWs.path);
      await bridge.ensureContext(childHandle, defaultWorkspace: childWs.path);

      // ① 父产生自己的溢出文件。
      final parentFirst = await runBig(parentHandle, 'PARENT-ONE-');
      final parentFirstSpill =
          (parentFirst['spill'] as Map?)?['stdout'] as Map?;
      expect(parentFirstSpill, isNotNull,
          reason: '大输出必须产生 spill 引用：$parentFirst');
      final parentRef = parentFirstSpill!['ref'] as String;
      final parentBytes = File(parentRef).readAsBytesSync();
      expect(parentBytes.length, parentFirstSpill['total_bytes']);
      expect(parentRef, contains('000001'),
          reason: '父第一次输出必须用自己上下文的 1 号序号');
      final parentReadFirst = await readRef(parentHandle, parentRef);
      expect(parentReadFirst['ok'], isTrue,
          reason: '父自己的引用必须可读：$parentReadFirst');

      // ② 子产生自己的溢出文件（独立上下文与独立目录）。
      final childFirst = await runBig(childHandle, 'CHILD-ONE-');
      final childFirstSpill = (childFirst['spill'] as Map?)?['stdout'] as Map?;
      expect(childFirstSpill, isNotNull,
          reason: '子的大输出也必须产生自己的 spill 引用：$childFirst');
      final childRef = childFirstSpill!['ref'] as String;
      final childBytes = File(childRef).readAsBytesSync();
      // ignore: avoid_print
      print('[OBS] 父引用=$parentRef 子引用=$childRef '
          '父目录存在=${parentSpillDir.existsSync()} '
          '子目录存在=${childSpillDir.existsSync()}');
      expect(childRef, isNot(parentRef));
      expect(childRef, contains(childHandle));
      expect(parentRef, contains(parentHandle));
      expect(childBytes.length, childFirstSpill['total_bytes']);
      // 子引用确实在子上下文自己的目录里。
      expect(
          childRef.replaceAll('\\', '/').toLowerCase(),
          startsWith(childSpillDir.path
              .replaceAll('\\', '/')
              .toLowerCase()));

      // 子上下文还在时，用父句柄读子引用也必须失败：引用只按自己的目录认。
      final crossReadAlive = await readRef(parentHandle, childRef);
      // ignore: avoid_print
      print('[OBS] 子还在时父句柄读子引用：${jsonEncode(crossReadAlive)}');
      expect(crossReadAlive['ok'], isFalse,
          reason: '父句柄不得读到另一个上下文的 spill 引用（即使文件还在）');
      expect(crossReadAlive['error'], contains('不属于该上下文'),
          reason: '失败原因必须是跨上下文的目录判定，而不是文件恰好不存在');

      // ③ 子结束：走生产的销毁路径（子 Agent 清理就是 disposeContext）。
      await bridge.disposeContext(childHandle);
      // ignore: avoid_print
      print('[OBS] 子销毁后：子目录存在=${childSpillDir.existsSync()} '
          '子文件存在=${File(childRef).existsSync()} '
          '父文件存在=${File(parentRef).existsSync()}');
      expect(childSpillDir.existsSync(), isFalse,
          reason: '子上下文销毁必须按契约删掉自己的 spill 目录');
      expect(File(childRef).existsSync(), isFalse);
      expect(File(parentRef).existsSync(), isTrue,
          reason: '父 spill 文件不得因子上下文销毁而消失');

      // 父引用仍可读，且字节完全一致。
      final parentReadAfter = await readRef(parentHandle, parentRef);
      // ignore: avoid_print
      print('[OBS] 子销毁后父读自己的引用：ok=${parentReadAfter['ok']} '
          'text=${parentReadAfter['text']}');
      expect(parentReadAfter['ok'], isTrue,
          reason: '子销毁后父引用必须仍可读：$parentReadAfter');
      expect(parentReadAfter['text'], parentReadFirst['text']);
      expect(File(parentRef).readAsBytesSync(), parentBytes,
          reason: '父文件字节不得被改写');

      // 子上下文已销毁：用父句柄读子的引用必须失败（不跨句柄泄漏）。
      final crossRead = await readRef(parentHandle, childRef);
      // ignore: avoid_print
      print('[OBS] 父句柄读子引用：${jsonEncode(crossRead)}');
      expect(crossRead['ok'], isFalse,
          reason: '子上下文销毁后，父句柄不得读到子的 spill 引用');

      // ④ 父后续输出：用新序号，不覆盖旧文件。
      final parentSecond = await runBig(parentHandle, 'PARENT-TWO-');
      final parentSecondSpill =
          (parentSecond['spill'] as Map?)?['stdout'] as Map?;
      final parentRef2 = parentSecondSpill!['ref'] as String;
      // ignore: avoid_print
      print('[OBS] 父第二次引用=$parentRef2 与旧引用相同=${parentRef2 == parentRef} '
          '旧文件存在=${File(parentRef).existsSync()}');
      expect(parentRef2, isNot(parentRef),
          reason: '父后续输出必须用新序号，不能覆盖旧引用');
      expect(File(parentRef).readAsBytesSync(), parentBytes,
          reason: '旧 spill 文件字节不得被新输出覆盖');
      final oldAgain = await readRef(parentHandle, parentRef);
      expect(oldAgain['ok'], isTrue);
      expect(oldAgain['text'], parentReadFirst['text']);
      final newBytes = File(parentRef2).readAsBytesSync();
      expect(utf8.decode(newBytes.sublist(0, 11)), 'PARENT-TWO-',
          reason: '新文件必须是这一次的输出');
    } finally {
      try {
        bridge.cancelRequest(childHandle);
      } catch (_) {}
      for (final handle in [childHandle, parentHandle]) {
        try {
          await bridge.disposeContext(handle);
        } catch (_) {}
      }
      for (final dir in [parentWs, childWs]) {
        if (dir.existsSync()) {
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    }
    // 父上下文真正销毁后，父 spill 目录也按契约删除（与前面的"保留"形成对照）。
    expect(parentSpillDir.existsSync(), isFalse,
        reason: 'disposeContext 必须删掉父自己的 spill 目录');
  });
}
