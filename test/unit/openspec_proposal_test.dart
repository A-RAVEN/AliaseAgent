import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 每个还没归档的 OpenSpec change，它的 tasks.md 里必须提到测试层路径。
///
/// 依据：`CLAUDE.md`「不许有"没有测试的新功能"」第 3 条 —— 添加测试是所有 proposal
/// 的硬性要求（用户 2026-10-02 原话：「以后所有新功能的添加都应该有能反映它的测试
/// 用例，可以多个功能共用一个测试，但是不允许没有测试」「添加测试应该是所有 proposal
/// 的硬性要求」）。一条都没提到测试的提案不许进入 apply。
///
/// 判定范围与 `CLAUDE.md` 另一条规则一致：`openspec/changes/<名字>/` 顶层直接子目录
/// 且含 `.openspec.yaml` 才是活跃 change；`archive/` 是历史，永不检查。
///
/// 这条守卫**只**核对"提案里有没有提到测试"，故意写得不容易误伤：整份 tasks.md 里
/// 任何一处出现测试层路径即算命中（写在任务行、判据行、或验收小字里都认）。
///
/// **它的边界要如实说清（2026-10-02 对抗验证审查指出）**：因为按整行子串判定、也不区分
/// "任务行 / 说明行 / 红态实测的输出块 / 代码围栏"，所以一份**只在叙述或证据日志里**
/// 出现过测试路径、而没有任何"真的写测试"任务的提案也能通过 —— 它拦得住"一处都没提"
/// 的提案（这一点由下面的反例自证用例钉住），拦不住"只是提到"。真正判断"测试是不是真能
/// 反映这个功能"属于 apply 阶段的验收（人读用例 + 那条任务自己写的判据）；把判定写严
/// （例如只认任务行）会误伤"判据行里点名测试文件"这类合法写法，所以这里有意从宽。

/// 测试层路径。提到任意一个即算"这个提案要求了测试"。
const _testPathMarkers = <String>[
  'test/unit',
  'test/widget',
  'test/integration',
  'integration_test',
  'sidecar/test',
  'test/smoke',
];

String _short(String line) {
  final t = line.trim();
  return t.length <= 60 ? t : '${t.substring(0, 60)}…';
}

/// 扫 `openspec/changes/` 下所有活跃 change，返回"名字 → 命中到的测试层路径（带出处行）"。
/// [root] 可换，供反例自证在临时目录里造一份假工件跑同一个扫描。
Map<String, List<String>> scanActiveChanges({String root = 'openspec/changes'}) {
  final dir = Directory(root);
  final out = <String, List<String>>{};
  if (!dir.existsSync()) return out;
  for (final e in dir.listSync()) {
    if (e is! Directory) continue;
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == 'archive') continue; // 归档历史，永不检查
    if (!File('${e.path}/.openspec.yaml').existsSync()) continue; // 不是活跃 change
    final tasks = File('${e.path}/tasks.md');
    final found = <String>[];
    if (tasks.existsSync()) {
      for (final line in tasks.readAsStringSync().split('\n')) {
        for (final m in _testPathMarkers) {
          if (line.contains(m)) {
            found.add('$m ← ${_short(line)}');
            break;
          }
        }
      }
    }
    out[name] = found;
  }
  return out;
}

void main() {
  group('OpenSpec 提案必须要求测试', () {
    test('每个活跃 change 的 tasks.md 都提到测试层路径', () {
      expect(Directory('openspec/changes').existsSync(), isTrue,
          reason: '仓库里应当有 openspec/changes 目录');

      final hits = scanActiveChanges();

      // ignore: avoid_print
      print('[活跃 change] ${hits.length} 个：${hits.keys.toList()}');
      for (final entry in hits.entries) {
        // ignore: avoid_print
        print('[测试层路径] ${entry.key}：命中 ${entry.value.length} 处'
            '${entry.value.isEmpty ? "" : "，例如 ${entry.value.first}"}');
      }

      if (hits.isEmpty) {
        // 空集不是"通过"：如实说出来，免得日后有人把它当成检查生效了。
        // ignore: avoid_print
        print('[活跃 change] 一个活跃 change 都没有 —— 这是正常的空集，不是"通过"');
        return;
      }

      final missing = [for (final e in hits.entries) if (e.value.isEmpty) e.key];
      expect(missing, isEmpty,
          reason: '这些还没归档的 change，tasks.md 里没有任何一处提到测试层路径'
              '（${_testPathMarkers.join(" / ")} 之一）：$missing —— '
              '按 CLAUDE.md，添加测试是所有 proposal 的硬性要求，'
              '请先补上点名测试路径的任务（并写清它验什么）再进入 apply');
    });

    test('反例自证：不提测试的活跃 change 会被这条检查抓出来', () {
      // 反例构造（AGENTS.md 第 10 节：主动构造"缺陷仍在、但检查通过"的状态）。
      // 在临时目录里造一份不提任何测试的假工件，用同一个扫描函数跑 —— 它必须被扫到、
      // 且命中数为 0（真实仓库里出现这种提案时，上面那条用例就会红）。
      final tmp = Directory.systemTemp.createTempSync('openspec_probe_');
      try {
        final fake = Directory('${tmp.path}/probe-change')..createSync();
        File('${fake.path}/.openspec.yaml')
            .writeAsStringSync('schema: spec-driven\n');
        File('${fake.path}/tasks.md').writeAsStringSync(
            '## 1. 干活\n\n- [ ] 1.1 把功能写出来\n- [ ] 1.2 跑一遍看看\n');
        final scanned = scanActiveChanges(root: tmp.path);
        // ignore: avoid_print
        print('[反例] 假 change 命中测试层路径 ${scanned['probe-change']?.length} 处'
            '（期望 0）');
        expect(scanned.keys, contains('probe-change'),
            reason: '带 .openspec.yaml 的目录必须被当成活跃 change 扫到');
        expect(scanned['probe-change'], isEmpty,
            reason: '反例本身要成立：这份假 tasks.md 确实没提任何测试层路径');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
