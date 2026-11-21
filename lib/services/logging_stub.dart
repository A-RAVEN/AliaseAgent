/// 纯 Dart VM 环境下的日志门面实现（没有 `package:flutter`）。
///
/// 刻意与 foundation 的 `DebugPrintCallback` 同签名且可重赋值，使调用方
/// （含纯 Dart 测试）可以像在 Flutter 里一样替换捕获日志。
library;

/// 当前实现标识（纯 Dart VM）。诊断用。
const String kLoggingSink = 'dart-vm';

/// 与 `package:flutter/foundation.dart` 的 `DebugPrintCallback` 同签名。
typedef DebugPrintCallback = void Function(String? message, {int? wrapWidth});

/// 可重赋值的全局打印钩子。默认实现写 stdout。
DebugPrintCallback debugPrint = _stdoutDebugPrint;

void _stdoutDebugPrint(String? message, {int? wrapWidth}) {
  // 无头核心的默认日志目标就是进程 stdout。
  // ignore: avoid_print
  print(message);
}
