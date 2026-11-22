// 群聊集成测试的隔离夹具（change `agent-group-chat` 任务 1.1 / design D20）。
//
// 血泪教训（见 CLAUDE.md 与 design 的 Risks）：integration 测试一旦漏掉某一项注入，
// 就会写到用户**真实的** `~/.aliasagent` —— 数据库、配置、单实例锁三者都会被污染。
// 所以这个夹具把四件事一次注入齐：
//   - `configPath`（临时目录里的 config.json）
//   - `attachmentsDir`（临时目录）
//   - `DatabaseService.openAt`（临时目录里的 aliasagent.db）
//   - `lockPath`（临时目录里的 core.lock；`core.lock` 也在 ~/.aliasagent，漏了会写真实目录）
// 外加假 sidecar 与假摘要 provider（不联网、不碰 DLL）。
//
// 它同时提供「本次运行没有写过用户真实目录」的核对入口：记录运行前后真实
// `~/.aliasagent` 下 db / config / core.lock 的 mtime+大小，`assertUserDirUnchanged()`
// 逐项比较。`logs/` 是**已知副作用**（真实日志目录由 sidecar 自己写），只记基线、
// 不要求不变。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/core/core_lock.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

import 'helpers/fake_sidecar.dart';

/// 一个文件的状态指纹：存在性 + 大小 + mtime（毫秒）。
class FileFingerprint {
  const FileFingerprint({
    required this.path,
    required this.exists,
    required this.size,
    required this.modifiedMs,
  });

  final String path;
  final bool exists;
  final int size;
  final int modifiedMs;

  static FileFingerprint of(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return FileFingerprint(path: path, exists: false, size: 0, modifiedMs: -1);
    }
    final stat = file.statSync();
    return FileFingerprint(
      path: path,
      exists: true,
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'exists': exists,
        'size': size,
        'modifiedMs': modifiedMs,
      };

  bool sameAs(FileFingerprint other) =>
      exists == other.exists &&
      size == other.size &&
      modifiedMs == other.modifiedMs;
}

/// 用户真实 `~/.aliasagent` 的基线（只读；用来证明测试没有写它）。
///
/// 只覆盖 **db / config / core.lock** 三项。`logs/` 是已知副作用：这里只记录
/// 目录里文件的个数与最后修改时间，供报告使用，不参与"必须不变"的断言。
class RealUserDirBaseline {
  RealUserDirBaseline._(this.db, this.config, this.lock, this.logsSummary);

  final FileFingerprint db;
  final FileFingerprint config;
  final FileFingerprint lock;
  final String logsSummary;

  static String get dir => ConfigService.configDir;

  factory RealUserDirBaseline.capture() {
    final dir = ConfigService.configDir;
    final logs = Directory(p.join(dir, 'logs'));
    var summary = '（没有 logs 目录）';
    if (logs.existsSync()) {
      final files = logs.listSync().whereType<File>().toList();
      if (files.isEmpty) {
        summary = '（logs 目录为空）';
      } else {
        files.sort((a, b) => a.path.compareTo(b.path));
        final last = files
            .map((f) => f.statSync())
            .reduce((a, b) => a.modified.isAfter(b.modified) ? a : b);
        summary = 'logs 文件数=${files.length} 最后修改=${last.modified.toIso8601String()}';
      }
    }
    return RealUserDirBaseline._(
      FileFingerprint.of(p.join(dir, 'aliasagent.db')),
      FileFingerprint.of(p.join(dir, 'config.json')),
      FileFingerprint.of(p.join(dir, 'core.lock')),
      summary,
    );
  }

  /// 运行前后逐项对比。返回差异列表（空 = 未改动）。这里**不**抛异常，让调用方
  /// 决定是断言失败还是仅打印（`logs/` 之类的判断要用同一份读数）。
  List<String> differences() {
    final now = RealUserDirBaseline.capture();
    final out = <String>[];
    void check(String label, FileFingerprint before, FileFingerprint after) {
      if (!before.sameAs(after)) {
        out.add('$label 变了：before=${before.toJson()} after=${after.toJson()}');
      }
    }

    check('真实 db', db, now.db);
    check('真实 config', config, now.config);
    check('真实 core.lock', lock, now.lock);
    return out;
  }

  String describe() =>
      '真实目录 $dir：db=${db.toJson()} config=${config.toJson()} '
      'core.lock=${lock.toJson()} logs=$logsSummary';
}

/// 群聊 integration 测试的统一夹具。
class GroupTestSupport {
  GroupTestSupport._(this.root, this.sidecar, this.summary, this.baseline);

  /// 临时根目录：config / attachments / db / lock 全在它下面。
  final Directory root;

  /// 假 sidecar：不加载 DLL、不联网。
  final FakeSidecar sidecar;

  /// 假摘要 provider：记录每次 summarize 的输入（隐私红靶的观察通道）。
  final FakeSummaryProvider summary;

  /// 真实用户目录的基线（运行前）。
  final RealUserDirBaseline baseline;

  late final SessionRepository sessionRepo = SessionRepository();
  late final MessageRepository messageRepo = MessageRepository();
  late final SummaryNodeRepository summaryNodeRepo = SummaryNodeRepository();

  /// 临时 config.json 的路径（**绝不**是 `ConfigService.configPath`）。
  String get configPath => p.join(root.path, 'config.json');

  /// 临时附件目录。
  String get attachmentsDir => p.join(root.path, 'attachments');

  /// 临时数据库目录（`DatabaseService.openAt` 把 aliasagent.db 放进来）。
  String get databaseDir => p.join(root.path, 'database');

  /// 临时单实例锁路径（`core.lock` 也住在 ~/.aliasagent，必须一起搬走）。
  String get lockPath => p.join(root.path, 'core.lock');

  /// 临时共享工作区（组的 workspace）。
  String get workspaceDir => p.join(root.path, 'workspace');

  /// 建夹具并打开临时数据库。**必须先调它**（`DatabaseService.openAt`）。
  static Future<GroupTestSupport> create({String prefix = 'group_test_'}) async {
    // 纯 Dart VM 下 openDatabase 必须靠 ffi 工厂（与无头核心组合根同一条路径）。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = Directory.systemTemp.createTempSync(prefix);
    final support = GroupTestSupport._(
      root,
      FakeSidecar(),
      FakeSummaryProvider(),
      RealUserDirBaseline.capture(),
    );
    Directory(support.databaseDir).createSync(recursive: true);
    Directory(support.attachmentsDir).createSync(recursive: true);
    Directory(support.workspaceDir).createSync(recursive: true);
    await DatabaseService.openAt(support.databaseDir);
    // 夹具自己的锁：取一次再释放，证明锁路径可写且指向临时目录（不碰真实 core.lock）。
    final lock = CoreInstanceLock(support.lockPath);
    final error = await lock.acquire();
    if (error != null) {
      throw StateError('临时单实例锁取不到（$error）：夹具的隔离被破坏');
    }
    await lock.release();
    return support;
  }

  /// 把一份配置写进**临时** config.json（测试要真配置时用）。
  void writeConfig(AppConfig config) {
    ConfigService.save(config, configPath: configPath);
  }

  /// 用临时 configPath 建一份最小配置（一个 provider + general 模板）。
  ///
  /// 通过 `AppConfig.fromJson` 构造，确保写进临时文件的键名就是产品真实的解析路径。
  AppConfig minimalConfig({
    String provider = 'test-provider',
    String model = 'test-model',
    int window = 200000,
    List<String> tools = const ['read_file', 'write_file', 'list_dir'],
    String systemPrompt = '你是测试模板。',
    String templateName = 'general',
  }) {
    return AppConfig.fromJson(<String, dynamic>{
      'version': 1,
      'providers': {
        provider: {
          'api_key': 'test-key',
          'base_url': 'http://127.0.0.1:9',
        },
      },
      'agent_types': {
        templateName: {
          'provider': provider,
          'model': model,
          'system_prompt': systemPrompt,
          'tools': tools,
          'max_context_tokens': window,
        },
      },
    });
  }

  /// 「本次运行没有写过用户真实 ~/.aliasagent」的核对入口。
  ///
  /// 返回差异列表；空 = db / config / core.lock 的 mtime+大小都没变。
  List<String> realUserDirDifferences() => baseline.differences();

  /// 运行前基线 + 运行后读数的可读报告（贴进测试输出，失败可归因）。
  String describeIsolation() {
    final diffs = realUserDirDifferences();
    final buffer = StringBuffer()
      ..writeln('[隔离] 临时根目录=${root.path}')
      ..writeln('[隔离] configPath=$configPath')
      ..writeln('[隔离] attachmentsDir=$attachmentsDir')
      ..writeln('[隔离] database=$databaseDir')
      ..writeln('[隔离] lockPath=$lockPath')
      ..writeln('[隔离] ${baseline.describe()}')
      ..writeln(diffs.isEmpty
          ? '[隔离] 真实目录 db/config/core.lock 运行前后未变 ✔'
          : '[隔离] 真实目录被改动：${diffs.join(' ; ')}');
    return buffer.toString();
  }

  /// 关库并删临时目录（Windows 文件锁：删不掉就吞掉，不掩盖断言失败）。
  Future<void> dispose() async {
    await DatabaseService.close();
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
