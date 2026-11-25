// 无头核心命令行解析的单元测试（change `windows-desktop-shell` 任务 0.1）。
//
// 覆盖哪几件事（每条都能在实现坏掉时变红）：
//   1. `--port 9100` 解析成功；`--port 0` 被**保留**（交回 OS 分配的调试/测试形态）；
//   2. `--port` 非整数 / 负数 / 超 65535 / 缺值 ⇒ 可归因错误（`CoreCliException`，
//      消息含 `--port` 与收到的原值），**不猜默认值**；未知参数同样报错；
//   3. `resolveCorePort` 的优先级 `--port` > 配置 `core.port` > 具名默认
//      （`AppConfig.kDefaultCorePort`），且 `--port 0` 不会被默认值顶掉；
//   4. 帮助文案含 `--port`，且启动命令与 `kCoreEntryCommand` **同源**（同一个常量，
//      不是手抄副本）。
//
// 本文件不联网、不碰用户真实配置：配置文件一律写在系统临时目录里。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/core/core_cli.dart';
import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/app_config.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[core-cli] $label: $value');
}

void main() {
  late Directory tempDir;
  late String configPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('core_cli_args_test_');
    configPath = p.join(tempDir.path, 'config.json');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeConfigWithPort(Object? rawPort) {
    File(configPath).writeAsStringSync(
      '{"version": 1, "providers": {}, "agent_types": {},'
      ' "core": {"port": $rawPort}}',
    );
  }

  group('parseCoreArgs：--port 解析与校验', () {
    test('--port 9100 解析成功；--port 0 保留「交回 OS 分配」', () {
      final explicit = parseCoreArgs(const ['--port', '9100']);
      _obs('--port 9100 ⇒', explicit.port);
      expect(explicit.port, 9100);

      final zero = parseCoreArgs(const ['--port', '0']);
      _obs('--port 0 ⇒', zero.port);
      expect(zero.port, 0,
          reason: '核心侧的 0 是「交回 OS 分配」的既有调试/测试形态，必须保留');

      final absent = parseCoreArgs(const []);
      _obs('未给 --port ⇒', absent.port);
      expect(absent.port, isNull, reason: '没给 --port 时不能编一个值出来');
    });

    test('--port 非整数 / 负数 / 超 65535 / 缺值 ⇒ 可归因错误，不猜默认', () {
      final cases = <String, List<String>>{
        '非整数': const ['--port', 'abc'],
        '小数': const ['--port', '9100.5'],
        '负数': const ['--port', '-1'],
        '超 65535': const ['--port', '65536'],
        '缺值': const ['--port'],
      };
      for (final entry in cases.entries) {
        CoreCliException? caught;
        CoreCliOptions? parsed;
        try {
          parsed = parseCoreArgs(entry.value);
        } on CoreCliException catch (e) {
          caught = e;
        }
        _obs('${entry.key} (${entry.value}) ⇒',
            caught == null ? '被接受：port=${parsed?.port}' : caught.message);
        expect(caught, isNotNull,
            reason: '${entry.key} 必须报错退出，不许被接受（更不许回落默认值）');
        expect(caught!.message, contains('--port'),
            reason: '错误消息必须点名 --port，否则用户不知道改哪个参数');
        if (entry.key != '缺值') {
          expect(caught.message, contains(entry.value.last),
              reason: '错误消息必须带上收到的原值（可归因）');
        }
      }
    });

    test('未知参数报错（不静默忽略）', () {
      CoreCliException? caught;
      try {
        parseCoreArgs(const ['--nope']);
      } on CoreCliException catch (e) {
        caught = e;
      }
      _obs('--nope ⇒', caught?.message);
      expect(caught, isNotNull);
      expect(caught!.message, contains('--nope'));
    });

    test('既有参数照旧解析（--config / --lock / --web-root / --help）', () {
      final options = parseCoreArgs(const [
        '--config',
        r'C:\tmp\cfg.json',
        '--lock',
        r'C:\tmp\core.lock',
        '--web-root',
        r'C:\tmp\web-dist',
      ]);
      _obs(
        '既有参数',
        '${options.configPath} / ${options.lockPath} / '
        '${options.webRoot} / help=${options.help}',
      );
      expect(options.configPath, equals(r'C:\tmp\cfg.json'));
      expect(options.lockPath, equals(r'C:\tmp\core.lock'));
      expect(options.webRoot, equals(r'C:\tmp\web-dist'));
      expect(options.help, isFalse);

      final help = parseCoreArgs(const ['--help']);
      _obs('--help ⇒ help=${help.help}', null);
      expect(help.help, isTrue);
    });
  });

  group('resolveCorePort：优先级 --port > core.port > 默认', () {
    test('--port 赢过配置', () {
      writeConfigWithPort(9000);
      final detail = resolveCorePortWithSource(
          cliPort: 9100, configPath: configPath);
      _obs('配置 9000 + --port 9100 ⇒', '${detail.port} (${detail.source.name})');
      expect(detail.port, 9100);
      expect(detail.source, CorePortSource.cli);
    });

    test('无 --port 时读配置 core.port', () {
      writeConfigWithPort(9000);
      final detail =
          resolveCorePortWithSource(cliPort: null, configPath: configPath);
      _obs('配置 9000、无 --port ⇒',
          '${detail.port} (${detail.source.name})');
      expect(detail.port, 9000);
      expect(detail.source, CorePortSource.config);
    });

    test('配置文件不存在 ⇒ 具名默认常量', () {
      final missing = p.join(tempDir.path, 'no-such-config.json');
      final detail =
          resolveCorePortWithSource(cliPort: null, configPath: missing);
      _obs('配置不存在 ⇒', '${detail.port} (${detail.source.name}) '
          'AppConfig.kDefaultCorePort=$AppConfig.kDefaultCorePort');
      expect(detail.port, AppConfig.kDefaultCorePort);
      expect(detail.source, CorePortSource.defaultConstant);
    });

    test('配置里没有 core 块 / core.port 非法 ⇒ 默认常量', () {
      File(configPath).writeAsStringSync(
          '{"version": 1, "providers": {}, "agent_types": {}}');
      final noBlock =
          resolveCorePortWithSource(cliPort: null, configPath: configPath);
      _obs('无 core 块 ⇒', '${noBlock.port} (${noBlock.source.name})');
      expect(noBlock.port, AppConfig.kDefaultCorePort);

      writeConfigWithPort('"9100"');
      final bad =
          resolveCorePortWithSource(cliPort: null, configPath: configPath);
      _obs('core.port 是字符串 ⇒', '${bad.port} (${bad.source.name})');
      expect(bad.port, AppConfig.kDefaultCorePort);
    });

    test('--port 0 是显式值，不被配置或默认顶掉', () {
      writeConfigWithPort(9000);
      final detail =
          resolveCorePortWithSource(cliPort: 0, configPath: configPath);
      _obs('配置 9000 + --port 0 ⇒',
          '${detail.port} (${detail.source.name})');
      expect(detail.port, 0);
      expect(detail.source, CorePortSource.cli);
    });

    test('resolveCorePort 便捷函数与带来源版本同值', () {
      writeConfigWithPort(9000);
      final port =
          resolveCorePort(cliPort: null, configPath: configPath);
      _obs('便捷函数 ⇒', port);
      expect(port, 9000);
    });
  });

  group('帮助文案', () {
    test('含 --port 与既有选项，且启动命令与 kCoreEntryCommand 同源', () {
      _obs('kCoreEntryCommand', kCoreEntryCommand);
      _obs('帮助文案长度', kCoreCliUsage.length);
      expect(kCoreCliUsage, contains('--port'));
      expect(kCoreCliUsage, contains(kCoreEntryCommand),
          reason: '帮助里的启动命令必须来自 kCoreEntryCommand 常量（文档守卫读同一份）');
      for (final flag in const [
        '--config',
        '--lock',
        '--web-root',
        '--help',
      ]) {
        _obs('帮助选项', flag);
        expect(kCoreCliUsage, contains(flag));
      }
    });
  });
}
