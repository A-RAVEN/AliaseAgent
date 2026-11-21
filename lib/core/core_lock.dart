// 无头核心的单实例守卫（change `web-ui-core-shim` design D11）。
//
// 双开的后果不止"双写"：`dispose_context` 会删除另一进程正在使用的 spill 目录，
// sqlite 又没有跨进程锁 —— 会真的破坏数据。所以守卫必须是机器判据，不能只靠文档：
// 取一个排他锁文件，已被占用就**显式失败退出**。
//
// 锁必须在任何 DB / spill 操作**之前**取得（调用方顺序保证）。
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/config_service.dart';

/// 已被占用时的固定提示文案（用户文档与守卫测试都读这个常量，不手抄副本）。
const String kCoreAlreadyRunningMessage = '已有核心在运行：单实例锁已被占用，'
    '本次启动已退出。请先关闭那个无头核心进程，再重新启动。';

/// 默认锁文件位置：与配置同一个目录（`~/.aliasagent/core.lock`）。
String get defaultCoreLockPath =>
    p.join(ConfigService.configDir, 'core.lock');

/// 锁文件单实例守卫。
class CoreInstanceLock {
  CoreInstanceLock(this.path);

  final String path;
  RandomAccessFile? _handle;

  /// 当前进程是否持有锁。
  bool get isHeld => _handle != null;

  /// 尝试取锁。成功返回 null；被占用返回 [kCoreAlreadyRunningMessage]；
  /// 其它 IO 失败返回可归因的错误文本（调用方打印并退出）。
  Future<String?> acquire() async {
    final file = File(path);
    try {
      await file.parent.create(recursive: true);
    } on FileSystemException catch (e) {
      return '无法创建单实例锁目录 ${file.parent.path}：$e';
    }

    final RandomAccessFile handle;
    try {
      // append：文件不存在时创建，且**不截断**已有内容（取到锁之后再写 pid）。
      handle = await file.open(mode: FileMode.append);
    } on FileSystemException catch (e) {
      return '无法打开单实例锁文件 $path：$e';
    }

    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      // Windows errno 33 / POSIX EWOULDBLOCK：已有进程持锁。
      return kCoreAlreadyRunningMessage;
    } catch (e) {
      await handle.close();
      return '无法获取单实例锁 $path：$e';
    }

    try {
      handle.setPositionSync(0);
      handle.truncateSync(0);
      handle.writeStringSync('$pid\n');
      handle.flushSync();
    } catch (_) {
      // pid 只是诊断信息；写不进去不影响锁本身的有效性。
    }
    _handle = handle;
    return null;
  }

  /// 释放锁并关闭文件（进程退出时 OS 也会释放，但正常退出要显式做）。
  Future<void> release() async {
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    try {
      await handle.unlock();
    } catch (_) {
      // 已随进程关闭：忽略。
    }
    try {
      await handle.close();
    } catch (_) {
      // 已关闭：忽略。
    }
  }
}
