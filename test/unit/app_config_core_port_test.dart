// `core` 配置块的单元测试（change `windows-desktop-shell` 任务 0.2）。
//
// 覆盖哪几件事（每条都能在实现坏掉时变红）：
//   1. 缺 `core` 块 / 缺 `port` 键 ⇒ 默认 `kDefaultCorePort`，并留一行回落日志
//      （spec：`core.port` 缺席、非整数或越界时回落默认并**留一行日志**，不静默）；
//   2. `core.port` 是字符串 / 0 / 负数 / 65536 ⇒ 回落默认并留一行日志；
//   3. 合法值（1–65535 的整数）被读入；
//   4. `toJson` **总是写回** `core.port`（保存一次不丢键，与 `spill` / `tool` 同口径）；
//   5. `copyWith(providers: …)` 保留 `corePort`（保存 provider 不会把端口丢了）。
//
// 日志捕获方式：本用例自己重赋可复位的 `debugPrint` shim（既有 `spill_config_test`
// 不捕获日志，不能照抄它的假设），并在每个用例前调 `AppConfig.resetCorePortReportForTests()`
// 清掉「已报过一次」的静态标志 —— 否则第二条非法值用例抓不到日志。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/config_service.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[core.port] $label: $value');
}

/// 抓一段同步代码里的 `debugPrint` 输出（之后一定恢复原函数）。
List<String> _captureLogs(void Function() body) {
  final captured = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) captured.add(message);
  };
  try {
    body();
  } finally {
    debugPrint = original;
  }
  return captured;
}

void main() {
  Map<String, dynamic> baseJson({Object? core}) {
    final map = <String, dynamic>{
      'version': 1,
      'providers': <String, dynamic>{},
      'agent_types': <String, dynamic>{},
    };
    if (core != null) map['core'] = core;
    return map;
  }

  setUp(() {
    // 「已报过一次」的静态标志必须逐用例清零，否则第二条非法值用例抓不到日志。
    AppConfig.resetCorePortReportForTests();
  });

  test('缺 core 块 ⇒ 默认常量，并留一行回落日志', () {
    AppConfig? config;
    final logs = _captureLogs(() {
      config = AppConfig.fromJson(baseJson());
    });
    _obs('缺 core 块 ⇒ corePort', config!.corePort);
    _obs('回落日志', logs);
    expect(config!.corePort, AppConfig.kDefaultCorePort);
    expect(logs.join('\n'), contains('core.port'),
        reason: '回落必须可见：日志里要点名 core.port');
    expect(logs.join('\n'), contains('${AppConfig.kDefaultCorePort}'),
        reason: '日志里要写出回落到哪个默认值');
  });

  test('缺 port 键（core 块是空对象）⇒ 默认常量 + 一行日志', () {
    AppConfig? config;
    final logs = _captureLogs(() {
      config = AppConfig.fromJson(baseJson(core: <String, dynamic>{}));
    });
    _obs('core={} ⇒ corePort', config!.corePort);
    _obs('回落日志', logs);
    expect(config!.corePort, AppConfig.kDefaultCorePort);
    expect(logs.join('\n'), contains('core.port'));
  });

  test('core.port 是字符串 / 0 / 负数 / 65536 ⇒ 回落默认，且每个非法值都留一行日志', () {
    final cases = <String, Object>{
      '字符串': '9100',
      '0': 0,
      '负数': -1,
      '65536': 65536,
      '小数': 9100.5,
    };
    for (final entry in cases.entries) {
      // 每个非法值单独重置标志：否则只有第一条能抓到日志。
      AppConfig.resetCorePortReportForTests();
      AppConfig? config;
      final logs = _captureLogs(() {
        config = AppConfig.fromJson(baseJson(core: {'port': entry.value}));
      });
      _obs('${entry.key} (${entry.value}) ⇒ corePort',
          '${config!.corePort} 日志=${logs.isEmpty ? "（无）" : logs.first}');
      expect(config!.corePort, AppConfig.kDefaultCorePort,
          reason: '${entry.key} 是非法端口，必须回落默认（不许当成合法值，也不许抛异常）');
      expect(logs, isNotEmpty,
          reason: '${entry.key} 回落必须留一行日志（静默降级算缺陷）');
      expect(logs.join('\n'), contains('core.port'));
    }
  });

  test('合法值被读入（1 与 65535 两个边界都收）', () {
    for (final port in const [1, 9000, 65535]) {
      AppConfig.resetCorePortReportForTests();
      AppConfig? config;
      final logs = _captureLogs(() {
        config = AppConfig.fromJson(baseJson(core: {'port': port}));
      });
      _obs('core.port=$port ⇒', '${config!.corePort} 日志=${logs.length} 行');
      expect(config!.corePort, port);
      expect(logs, isEmpty, reason: '合法值不该打回落日志（那是噪声）');
    }
  });

  test('toJson 总是写回 core.port；保存一次不丢键', () {
    final config = AppConfig.fromJson(baseJson(core: {'port': 9100}));
    final json = config.toJson();
    _obs('toJson core 块', json['core']);
    expect(json['core'], {'port': 9100});

    // 保存一次再读回：ConfigService.save 整份覆盖写盘，不写回就会丢键。
    final dir = Directory.systemTemp.createTempSync('app_config_core_port_');
    final configPath = p.join(dir.path, 'config.json');
    try {
      ConfigService.save(config, configPath: configPath);
      final reread = File(configPath).readAsStringSync();
      _obs('盘上的 config.json', reread.replaceAll('\n', ' '));
      expect(reread, contains('"port": 9100'));
      final loaded = ConfigService.load(configPath: configPath).config!;
      _obs('读回 corePort', loaded.corePort);
      expect(loaded.corePort, 9100);
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('copyWith(providers: …) 保留 corePort；显式改 corePort 也生效', () {
    final config = AppConfig.fromJson(baseJson(core: {'port': 9100}));
    final kept = config.copyWith(providers: const {});
    _obs('copyWith(providers) ⇒ corePort', kept.corePort);
    expect(kept.corePort, 9100,
        reason: '保存 provider 不能把端口丢掉（整份覆盖写盘会写回它）');

    final changed = config.copyWith(corePort: 9200);
    _obs('copyWith(corePort: 9200) ⇒', changed.corePort);
    expect(changed.corePort, 9200);
  });
}
