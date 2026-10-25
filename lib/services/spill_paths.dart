/// spill 目录的位置与清理（change `spill-large-tool-output`）。
///
/// 规则与 C++ 侧 `sidecar/src/spill.cpp` 的 `session_dir_name()` **必须一致** ——
/// 两边都按会话 id 建目录 / 删目录，规则一漂移就会"删了却没删掉"。改这里就要
/// 同步改那边（反之亦然）。
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

/// 会话 id → 目录名：只留 `[A-Za-z0-9._-]`，其余换成 `_`；
/// 空串 / `.` / `..` 一律落到 `no-session`。
///
/// **按 UTF-8 字节遍历**，不是按字符 —— C++ 侧就是按字节扫的，按字符遍历会让
/// 中文 id 在两边得到不同的目录名（实测：按字符 4 个下划线、按字节 12 个）。
String spillSessionDirName(String session) {
  if (session.isEmpty) return 'no-session';
  final out = StringBuffer();
  for (final byte in utf8.encode(session)) {
    final keep = (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        byte == 0x2E || // .
        byte == 0x5F || // _
        byte == 0x2D; // -
    out.write(keep ? String.fromCharCode(byte) : '_');
  }
  final name = out.toString();
  if (name.isEmpty || name == '.' || name == '..') return 'no-session';
  return name;
}

/// 某会话的 spill 目录（绝对路径）。
String spillSessionDir(String sessionId) =>
    '${spillRoot()}${Platform.pathSeparator}${spillSessionDirName(sessionId)}';

/// 删掉某会话的 spill 目录。目录不存在就什么都不做（不报错、不建目录）。
/// 返回是否真的删了一个存在的目录 —— 测试用它区分"删了"与"本来就没有"。
bool deleteSessionSpill(String sessionId) {
  final dir = Directory(spillSessionDir(sessionId));
  if (!dir.existsSync()) return false;
  dir.deleteSync(recursive: true);
  return true;
}

/// 清掉**无主**的 spill 目录：`no-session`（没有会话 id 时落进去的）与 `_it_` 前缀
/// （测试自己建的）。
///
/// 为什么需要：删会话只删 `<会话 id>/`，而 `no-session` 不对应任何会话 —— 它只增不减。
/// 应用启动时清一次就够（无主文件本来就是"下次启动就作废"的东西）。
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

