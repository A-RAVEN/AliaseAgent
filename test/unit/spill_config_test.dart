import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/spill_paths.dart';

/// 配置项 `spill.preview_chars`（change `spill-large-tool-output`，tasks 3.3）。
///
/// 覆盖三件事：
///   1. 配置里有这个键时真的读到它（不是永远返回缺省）；
///   2. 缺这个键、或写坏了（0 / 负数 / 文字）时回落到 **1000**
///      —— 这个数是用户 2026-10-25 的决定，不是随手取的；
///   3. 用户文档的配置键表里确实写了这个键（否则用户改不到它）。
void main() {
  Map<String, dynamic> baseJson({Object? spill, Object? tool}) {
    final m = <String, dynamic>{
      'version': 1,
      'providers': {
        'p': {'api_key': 'k'},
      },
      'agent_types': {
        'general': {'provider': 'p', 'model': 'm'},
      },
    };
    if (spill != null) m['spill'] = spill;
    if (tool != null) m['tool'] = tool;
    return m;
  }

  test('读到配置里的 spill.preview_chars', () {
    final cfg = AppConfig.fromJson(baseJson(spill: {'preview_chars': 4000}));
    // ignore: avoid_print
    print('[spill 配置] preview_chars=4000 ⇒ 读到的值 = ${cfg.spillPreviewChars}');
    expect(cfg.spillPreviewChars, 4000);
  });

  test('缺省与坏值一律回落到 1000', () {
    final cases = <String, Object?>{
      '键缺失': null,
      '等于 0': {'preview_chars': 0},
      '负数': {'preview_chars': -5},
      '字符串': {'preview_chars': '很多'},
      '小数': {'preview_chars': 1000.5},
    };
    for (final entry in cases.entries) {
      final cfg = AppConfig.fromJson(baseJson(spill: entry.value));
      // ignore: avoid_print
      print('[spill 配置] ${entry.key} ⇒ ${cfg.spillPreviewChars}');
      expect(cfg.spillPreviewChars, 1000,
          reason: '${entry.key} 必须回落到缺省的 1000');
    }
  });

  test('保存配置时把 spill.preview_chars 写回去（用户能找到它）', () {
    final cfg = AppConfig.fromJson(baseJson(spill: {'preview_chars': 2500}));
    final back = cfg.toJson();
    // ignore: avoid_print
    print('[spill 配置] 写回的 spill 块 = ${back['spill']}');
    expect(back['spill'], {'preview_chars': 2500});
    // 再读一次仍是同一个数（往返不丢）
    expect(AppConfig.fromJson(back).spillPreviewChars, 2500);
  });

  test('两个旧命令输出键被废弃：不再出现在配置模型里，也不再写回', () {
    // 旧键写在 agent_types 段里；读进来只能不报错、并且**不再写回**
    // （写回去等于告诉用户这两个键还有用）。
    final cfg = AppConfig.fromJson({
      'version': 1,
      'providers': {
        'p': {'api_key': 'k'},
      },
      'agent_types': {
        'general': {
          'provider': 'p',
          'model': 'm',
          'command_max_output_chars': 1234,
          'command_output_full_chars': 5678,
        },
      },
    });
    final agentJson = cfg.agentTypes['general']!.toJson();
    // ignore: avoid_print
    print('[spill 配置] 旧键写回情况: '
        'command_max_output_chars=${agentJson.containsKey('command_max_output_chars')} '
        'command_output_full_chars=${agentJson.containsKey('command_output_full_chars')}');
    expect(agentJson.containsKey('command_max_output_chars'), isFalse);
    expect(agentJson.containsKey('command_output_full_chars'), isFalse);
  });

  test('用户文档的配置键表里写了 spill.preview_chars', () {
    final doc = File('Docs/user-guide/configuration.md').readAsStringSync();
    // ignore: avoid_print
    print('[spill 配置] 文档里出现 spill.preview_chars: '
        '${doc.contains('spill.preview_chars')}');
    expect(doc, contains('spill.preview_chars'));
    expect(doc, contains('preview_chars'));
  });

  // change parallelize-readonly-tool-calls 任务 3.4：`tool.parallel_max`
  // 0 = 不设上限（缺省）；正整数生效；坏值一律回落 0 并打印一次提示。

  test('读到配置里的 tool.parallel_max（正整数生效）', () {
    final cfg = AppConfig.fromJson(baseJson(tool: {'parallel_max': 3}));
    // ignore: avoid_print
    print('[工具并行配置] parallel_max=3 ⇒ 读到的值 = ${cfg.toolParallelMax}');
    expect(cfg.toolParallelMax, 3);
  });

  test('tool.parallel_max 的缺省与坏值：缺键 / 0 / 负数 / 字符串', () {
    final cases = <String, Object?>{
      '缺键': null,
      '等于 0': {'parallel_max': 0},
      '负数': {'parallel_max': -2},
      '字符串': {'parallel_max': '两个'},
      '小数': {'parallel_max': 2.5},
    };
    for (final entry in cases.entries) {
      final cfg = AppConfig.fromJson(baseJson(tool: entry.value));
      // ignore: avoid_print
      print('[工具并行配置] ${entry.key} ⇒ ${cfg.toolParallelMax}');
      expect(cfg.toolParallelMax, 0,
          reason: '${entry.key} 必须回落到缺省的 0（不设上限）');
    }
  });

  test('保存配置时把 tool.parallel_max 写回去（用户能找到它）', () {
    final cfg = AppConfig.fromJson(baseJson(tool: {'parallel_max': 4}));
    final back = cfg.toJson();
    // ignore: avoid_print
    print('[工具并行配置] 写回的 tool 块 = ${back['tool']}');
    expect(back['tool'], {'parallel_max': 4});
    expect(AppConfig.fromJson(back).toolParallelMax, 4);
  });

  test('用户文档写明了预览的两处字节改动与无主目录清理（tasks 11.4）', () {
    // 这两件事都是"用户看得见的行为变化"，spec 里写着"必须写进用户文档"：
    // ① 预览把 CRLF 归一成 LF、把坏字节换成 U+FFFD（文件里是原始字节）；
    // ② 启动时清掉 no-session 这种无主目录。
    final doc = File('Docs/user-guide/tools-command.md').readAsStringSync();
    // ignore: avoid_print
    print('[spill 配置] 11.4 文档命中：LF=${doc.contains('LF')} '
        'U+FFFD=${doc.contains('U+FFFD')} no-session=${doc.contains('no-session')}');
    expect(doc, contains('LF'), reason: '换行归一必须写进用户文档');
    expect(doc, contains('U+FFFD'), reason: '坏字节替换必须写进用户文档');
    expect(doc, contains('no-session'), reason: '启动清理无主目录必须写进用户文档');
  });

  // change add-context-handles 任务 3.6：文档里的 spill 目录名样例表必须与实现
  // 逐行一致。改代码不改文档、或改编码不改表格，这里都会红。
  test('用户文档的 spill 目录名样例表与实现逐行一致', () {
    final doc = File('Docs/user-guide/tools-command.md').readAsStringSync();
    // 样例表的三列是 `名字 | 目录名 | 说明`，前两列都在反引号里；文档里其它表格的
    // 第二列是普通文字或数字，不会命中这条正则。
    final rowPattern = RegExp(r'^\| `([^`]*)` \| `([^`]*)` \|', multiLine: true);
    final rows = <List<String>>[];
    for (final m in rowPattern.allMatches(doc)) {
      rows.add([m.group(1)!, m.group(2)!]);
    }
    // ignore: avoid_print
    print('[spill 配置] 文档样例表行数 = ${rows.length}');
    for (final row in rows) {
      // ignore: avoid_print
      print('[spill 配置]   ${row[0]} ⇒ ${row[1]}');
      expect(spillSessionDirName(row[0]), row[1],
          reason: '文档样例「${row[0]}」与实现不一致');
    }
    expect(rows.length, greaterThanOrEqualTo(9),
        reason: '样例表至少 9 行（含中文、大小写、`..`、UUID）');
    // 名字互不相同、目录名也互不相同（只差大小写的两个名字必须分开）。
    expect(rows.map((r) => r[0]).toSet().length, rows.length);
    expect(rows.map((r) => r[1]).toSet().length, rows.length);

    // 旧的"按会话 id 清理"说法必须消失；跨上下文读回限制必须写明。
    expect(doc, isNot(contains('按会话 id 清理')));
    expect(doc, contains('引用不属于该上下文的目录'),
        reason: '跨上下文读回的限制必须写进用户文档');
  });

  // change add-context-handles 任务 2.4 / 1.10：C++ 与 Dart 真的共读同一份样例表。
  // C++ 侧 `sidecar/test/spill_write_test.cpp` 的「编码样例表（C++ 与 Dart 共读同一份）」
  // 读的就是这个文件；这里逐行调用 Dart 实现比对，任一侧编码漂移都会让两侧同时红。
  test('与 C++ 共读 sidecar/test/spill_session_names.tsv，逐行一致', () {
    final file = File('sidecar/test/spill_session_names.tsv');
    expect(file.existsSync(), isTrue, reason: '共享样例表必须存在');
    final lines = const LineSplitter().convert(file.readAsStringSync());
    final rows = <List<String>>[];
    for (final line in lines) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final cols = line.split('\t');
      expect(cols.length, greaterThanOrEqualTo(2),
          reason: '样例表每行至少两列（名字、目录名）：$line');
      rows.add([cols[0], cols[1]]);
    }
    // ignore: avoid_print
    print('[spill 配置] 共享样例表行数 = ${rows.length}');
    expect(rows.length, greaterThanOrEqualTo(9),
        reason: '样例表至少 9 行（含中文、`.`、`..`、空串、大小写、UUID）');
    for (final row in rows) {
      // ignore: avoid_print
      print('[spill 配置]   共读样例「${row[0]}」⇒ Dart=${spillSessionDirName(row[0])} '
          '期望=${row[1]}');
      expect(spillSessionDirName(row[0]), row[1],
          reason: '共享样例「${row[0]}」在 C++ 与 Dart 两侧编码不一致');
    }
    // 空名字必须由同一张表覆盖，且两侧都落到 no-session。
    expect(rows.any((r) => r[0].isEmpty && r[1] == 'no-session'), isTrue);
    // UUID 编码前后不变（生产会话 id 都是这个形状）。
    const uuid = '8f14e45f-ceea-467a-9b3e-1f4c7a9d2e11';
    expect(rows.any((r) => r[0] == uuid && r[1] == uuid), isTrue);
    expect(spillSessionDirName(uuid), uuid);
  });
}
