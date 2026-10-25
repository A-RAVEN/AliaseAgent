import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';

/// 配置项 `spill.preview_chars`（change `spill-large-tool-output`，tasks 3.3）。
///
/// 覆盖三件事：
///   1. 配置里有这个键时真的读到它（不是永远返回缺省）；
///   2. 缺这个键、或写坏了（0 / 负数 / 文字）时回落到 **1000**
///      —— 这个数是用户 2026-10-25 的决定，不是随手取的；
///   3. 用户文档的配置键表里确实写了这个键（否则用户改不到它）。
void main() {
  Map<String, dynamic> baseJson({Object? spill}) {
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
}
