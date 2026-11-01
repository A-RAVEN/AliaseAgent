/// spill 目录的位置与启动清理（change `spill-large-tool-output`，
/// change `add-context-handles` 改写）。
///
/// 目录名规则与 C++ 侧 `sidecar/src/spill.cpp` 的 `session_dir_name()` **必须一致**：
/// 只保留 `[a-z0-9_-]`，其余字节写成 `%XX`（大写十六进制）；空名字落到
/// `no-session`。两侧共读 `sidecar/test/spill_session_names.tsv` 的样例表，
/// 漂移会被 `test/unit/spill_config_test.dart` 抓到。
///
/// 目录的**创建与删除**现在都在 C++ 侧按上下文句柄完成（`run_command` 建、
/// `dispose_context` 删）；Dart 只保留「应用启动时清无主目录」这一件事。
library;

import 'dart:convert';
import 'dart:io';

/// 主目录（Windows 是 `USERPROFILE`，其它平台是 `HOME`）。
String homeDir() =>
    Platform.environment['USERPROFILE'] ??
    Platform.environment['HOME'] ??
    '.';

/// spill 根目录：`<主目录>/.aliasagent/spill`。
String spillRoot() =>
    '${homeDir()}${Platform.pathSeparator}.aliasagent${Platform.pathSeparator}spill';

/// 上下文句柄 → 目录名：只留 `[a-z0-9_-]`，其余字节写成 `%XX`（大写十六进制）；
/// 空名字落到 `no-session`。
///
/// **按 UTF-8 字节遍历**，不是按字符 —— C++ 侧就是按字节扫的。
String spillSessionDirName(String session) {
  if (session.isEmpty) return 'no-session';
  const hex = '0123456789ABCDEF';
  final out = StringBuffer();
  for (final byte in utf8.encode(session)) {
    final keep = (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        byte == 0x5F || // _
        byte == 0x2D; // -
    if (keep) {
      out.write(String.fromCharCode(byte));
    } else {
      out.write('%${hex[byte >> 4]}${hex[byte & 0x0F]}');
    }
  }
  return out.toString();
}

/// 清掉**无主**的 spill 目录：`no-session`（旧版本没有上下文句柄时落进去的）与
/// `_it_` 前缀（旧测试自己建的）。
///
/// 为什么还需要：`no-session` 不对应任何上下文 —— 它只增不减。应用启动时清一次就够。
/// 有主的目录由 `dispose_context` 随上下文删除，这里不碰。
/// 返回删掉的目录名清单。
List<String> cleanOrphanSpillDirs() {
  final root = Directory(spillRoot());
  if (!root.existsSync()) return const [];
  final removed = <String>[];
  for (final entry in root.listSync()) {
    if (entry is! Directory) continue;
    final name = entry.path.split(Platform.pathSeparator).last;
    if (name == 'no-session' || name.startsWith('_it_')) {
      entry.deleteSync(recursive: true);
      removed.add(name);
    }
  }
  return removed;
}
